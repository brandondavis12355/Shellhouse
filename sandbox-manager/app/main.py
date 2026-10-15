"""
Sandbox Manager
===============
The ONLY component in this system that holds host privilege (the Docker
socket, or KVM/tap for Firecracker). Everything else asks it for things.

Why this exists
---------------
The API container runs the agent loop: it reads untrusted web pages, executes
model-chosen tool calls, and handles model output. Giving *that* process the
Docker socket means a prompt injection or a model mistake is one `docker run
-v /:/host` away from owning the machine. Splitting it out doesn't make the
sandbox escape-proof — it means the component most likely to be tricked has
no host privilege to hand over.

Design constraints this service is built around:

1. **No network listener.** It binds a unix domain socket only. Nothing on the
   LAN, nothing on localhost TCP, can reach it. The socket is shared into the
   API container through a volume.
2. **Narrow, typed API.** A fixed set of operations with strict schemas. The
   caller cannot pass through arbitrary Docker/Firecracker API calls, cannot
   name an image, cannot set a mount, cannot choose a user.
3. **Sandbox identity is server-side.** The caller passes a sandbox_id; this
   service resolves it against its own registry and refuses anything it did
   not create. A caller cannot point operations at another container.
4. **Shared-secret auth.** Defense in depth for the case where the socket's
   file permissions are wrong.
5. **Audit log.** Every operation, allowed or refused, appended to disk. This
   is the audit-log item from the production checklist.
6. **Orphan reaping on startup.** Sandboxes outlive the process that made
   them; startup reconciles the registry against reality.

Note on what is deliberately NOT restricted: `exec` runs arbitrary shell
commands, because that is the product. The containment for that is the
sandbox boundary itself plus the approval policy in the API — not this
service. What this service guarantees is that `exec` can only ever land
*inside a sandbox it created*, as an unprivileged user, with a timeout and
bounded output.
"""
import asyncio
import contextlib
import hashlib
import hmac
from collections import OrderedDict
import json
import logging
import os
import re
import time
from typing import Literal, Optional

import httpx
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field, field_validator

from providers.factory import get_backend
from providers.base import SandboxHandle

LOG_PATH = os.environ.get("MANAGER_AUDIT_LOG", "/var/log/sandbox-manager/audit.log")
AUTH_TOKEN = os.environ.get("MANAGER_TOKEN", "")
# More keys that work alongside MANAGER_TOKEN (comma-separated), one per Mac or person, so each can be rotated or
# revoked on its own. MANAGER_TOKEN stays the one the stack's own services use.
EXTRA_TOKENS = tuple(t for t in (x.strip() for x in os.environ.get("MANAGER_EXTRA_TOKENS", "").split(",")) if t)
MAX_COMMAND_LEN = 16_384
MAX_WRITE_BYTES = 8 * 1024 * 1024
MAX_EXEC_TIMEOUT = 900
# Env var names only: uppercase, digits, underscore. A crafted name must not
# be able to become a shell fragment when exported.
ENV_NAME_PATTERN = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("sandbox-manager")

app = FastAPI(title="Sandbox Manager", docs_url=None, redoc_url=None, openapi_url=None)

# sandbox_id -> handle, for every sandbox THIS service created.
_registry: dict[str, SandboxHandle] = {}


# ---------------------------------------------------------------------------
# Audit
# ---------------------------------------------------------------------------

_SECRET_PATTERNS = [
    (re.compile(r"(?i)(authorization:\s*(?:bearer|basic|token)\s+)\S+"), r"\1[REDACTED]"),
    (re.compile(r"(?i)\b((?:api[_-]?key|token|secret|passwd|password|access[_-]?key)\w*\s*[=:]\s*)['\"]?[^\s'\"&;]+"), r"\1[REDACTED]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"), "[REDACTED]"),
    (re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"), "[REDACTED]"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "[REDACTED]"),
]


def redact(value):
    """Best-effort scrub of secrets that ended up inside a logged command or
    path, so the audit log doesn't become a credential store."""
    if not isinstance(value, str):
        return value
    for pattern, replacement in _SECRET_PATTERNS:
        value = pattern.sub(replacement, value)
    return value


def audit(op: str, outcome: str, **fields) -> None:
    fields = {key: redact(val) for key, val in fields.items()}
    entry = {
        "ts": time.time(),
        "op": op,
        "outcome": outcome,
        **fields,
    }
    line = json.dumps(entry, default=str)
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass  # never let audit failure break the operation path
    logger.info("%s %s %s", op, outcome, fields.get("sandbox_id", ""))


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

def require_auth(token: Optional[str]) -> None:
    """
    Constant-time shared-secret check. If MANAGER_TOKEN is unset the service
    refuses to start (see startup), so this is never a no-op in practice.
    """
    # Compare against every key, without stopping at the first match, so timing doesn't say which one matched.
    ok = False
    if token:
        for known in (AUTH_TOKEN, *EXTRA_TOKENS):
            ok |= hmac.compare_digest(token.encode(), known.encode())
    if not ok:
        audit("auth", "refused", reason="bad_or_missing_token")
        raise HTTPException(status_code=401, detail="Unauthorized")


def resolve(sandbox_id: str) -> SandboxHandle:
    """
    Sandbox identity is server-side: only sandboxes this service created can
    be operated on. This is what stops a compromised API container from
    aiming exec at, say, the database container.
    """
    handle = _registry.get(sandbox_id)
    if handle is None:
        audit("resolve", "refused", sandbox_id=sandbox_id, reason="unknown_sandbox")
        raise HTTPException(status_code=404, detail="Unknown sandbox")
    return handle


# ---------------------------------------------------------------------------
# Schemas — strict, so nothing extra can be smuggled through
# ---------------------------------------------------------------------------

class CreateRequest(BaseModel):
    model_config = {"extra": "forbid"}
    task_id: str = Field(max_length=128, pattern=r"^[A-Za-z0-9_\-]+$")
    persistent: bool = False


REQUEST_ID_PATTERN = re.compile(r"^[A-Za-z0-9-]{8,64}$")
EXEC_RESULT_TTL = 600      # seconds a finished result stays available for a retry
EXEC_RESULT_MAX = 200
# request_id -> (finished_at, fingerprint, result). Never holds env (secret) values.
_exec_results: "OrderedDict[str, tuple[float, str, dict]]" = OrderedDict()
# request_id -> (fingerprint, task) for commands still running.
_exec_running: dict[str, tuple[str, asyncio.Task]] = {}


def _exec_fingerprint(req: "ExecRequest") -> str:
    return hashlib.sha256(f"{req.sandbox_id}\0{req.command}".encode()).hexdigest()


def _prune_exec_results(now: float) -> None:
    while _exec_results and (len(_exec_results) > EXEC_RESULT_MAX
                             or now - next(iter(_exec_results.values()))[0] > EXEC_RESULT_TTL):
        _exec_results.popitem(last=False)


class ExecRequest(BaseModel):
    model_config = {"extra": "forbid"}
    sandbox_id: str = Field(max_length=128)
    command: str = Field(max_length=MAX_COMMAND_LEN)
    timeout: int = Field(default=120, ge=1, le=MAX_EXEC_TIMEOUT)
    # Secret values injected at execution time. Names are validated; VALUES
    # ARE NEVER LOGGED (see the exec handler's audit call).
    env: dict[str, str] = Field(default_factory=dict)
    # Set by the app so a command can be retried after a dropped connection without running twice:
    # a repeat of a finished id returns the stored result, a repeat of a running one waits for it.
    request_id: Optional[str] = Field(default=None, max_length=64)

    @field_validator("request_id")
    @classmethod
    def valid_request_id(cls, v: Optional[str]) -> Optional[str]:
        if v is not None and not REQUEST_ID_PATTERN.match(v):
            raise ValueError("request_id must be 8-64 letters, digits or dashes")
        return v

    @field_validator("env")
    @classmethod
    def valid_env(cls, v: dict) -> dict:
        if len(v) > 32:
            raise ValueError("too many environment variables")
        for key, value in v.items():
            if not ENV_NAME_PATTERN.match(key):
                raise ValueError(f"invalid environment variable name: {key!r}")
            if len(value) > 8192:
                raise ValueError(f"environment value for {key} is too large")
        return v


class PathRequest(BaseModel):
    model_config = {"extra": "forbid"}
    sandbox_id: str = Field(max_length=128)
    path: str = Field(max_length=4096)
    # Read-only; ignored by write_file. Without this, read_file silently fell
    # back to the backend's own 200_000-byte default with no way for a
    # caller to ask for more — which broke reading back anything larger,
    # e.g. a screenshot PNG easily exceeding 200KB.
    max_bytes: int = Field(default=200_000, ge=1, le=50_000_000)

    @field_validator("path")
    @classmethod
    def no_traversal(cls, v: str) -> str:
        # The provider re-checks this, but rejecting here means a traversal
        # attempt is logged and refused before it reaches any privileged code.
        normalized = os.path.normpath("/" + v.lstrip("/"))
        if ".." in normalized.split("/"):
            raise ValueError("path traversal rejected")
        return normalized.lstrip("/")


class WriteRequest(PathRequest):
    content_b64: str = Field(max_length=MAX_WRITE_BYTES * 2)


class SandboxIdRequest(BaseModel):
    model_config = {"extra": "forbid"}
    sandbox_id: str = Field(max_length=128)


class EgressPendingRequest(BaseModel):
    model_config = {"extra": "forbid"}


class EgressDecideRequest(BaseModel):
    model_config = {"extra": "forbid"}
    # `example.com` or `*.example.com`. The proxy re-validates strictly
    # (rejects IP literals, userinfo, `*.com`, ...); this is a first gate.
    host: str = Field(min_length=1, max_length=253, pattern=r"^[^\s/@:\\%\[\]]+$")
    decision: Literal["allow", "deny"]


class DestroyRequest(BaseModel):
    model_config = {"extra": "forbid"}
    sandbox_id: str = Field(max_length=128)
    # Persistent (per-bot) sandboxes normally survive a destroy() call — see
    # DockerBackend.destroy's comment. `force` is the explicit "actually
    # delete this bot's computer" escape hatch (the app's Settings > Delete
    # bot flow), not something a routine cleanup call should ever set.
    force: bool = False


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

@app.on_event("startup")
async def startup() -> None:
    if not AUTH_TOKEN:
        raise RuntimeError(
            "MANAGER_TOKEN is not set. Refusing to start a privileged service "
            "with no authentication. Generate one with: openssl rand -hex 32"
        )
    backend = get_backend()
    logger.info("Sandbox Manager starting with backend=%s", backend.name)

    # Orphan reaping: sandboxes outlive this process, so reconcile on boot
    # rather than leaking containers/VMs forever.
    try:
        adopted = await backend.reconcile()
        for handle in adopted:
            _registry[handle.id] = handle
        audit("reconcile", "ok", adopted=[h.id for h in adopted])
        logger.info("Adopted %d existing sandbox(es)", len(adopted))
    except Exception as exc:
        audit("reconcile", "error", error=str(exc))
        logger.warning("Reconcile failed: %s", exc)


@app.get("/healthz")
async def healthz():
    """Unauthenticated liveness only — reveals nothing and does nothing."""
    return {"ok": True, "backend": get_backend().name}


# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

@contextlib.asynccontextmanager
async def backend_errors(op: str, sandbox_id: str = ""):
    """A backend failure (a VM that wouldn't boot, no disk space, a Docker error) becomes a 500 that SAYS WHY,
    instead of FastAPI's bare "Internal Server Error", which hides the reason from the app and the user. The full
    traceback goes to the service log; the message is redacted like everything else that is logged."""
    try:
        yield
    except HTTPException:
        raise
    except Exception as exc:
        logger.exception("%s failed", op)
        reason = redact(f"{type(exc).__name__}: {exc}")[:500]
        audit(op, "error", sandbox_id=sandbox_id, error=reason)
        raise HTTPException(status_code=500, detail=f"{op} failed: {reason}") from exc


@app.post("/v1/create")
async def create(req: CreateRequest, x_manager_token: str = Header(default="")):
    require_auth(x_manager_token)
    backend = get_backend()
    async with backend_errors("create", req.task_id):
        handle = await backend.create(req.task_id, persistent=req.persistent)
    _registry[handle.id] = handle
    audit("create", "ok", sandbox_id=handle.id, task_id=req.task_id,
          persistent=req.persistent, backend=backend.name)
    return handle.to_dict()


@app.post("/v1/start")
async def start(req: SandboxIdRequest, x_manager_token: str = Header(default="")):
    require_auth(x_manager_token)
    resolve(req.sandbox_id)
    async with backend_errors("start", req.sandbox_id):
        handle = await get_backend().start(req.sandbox_id)
    _registry[handle.id] = handle
    audit("start", "ok", sandbox_id=handle.id)
    return handle.to_dict()


@app.post("/v1/exec")
async def execute(req: ExecRequest, x_manager_token: str = Header(default="")):
    require_auth(x_manager_token)
    resolve(req.sandbox_id)
    if req.request_id:
        return await _execute_once(req)
    async with backend_errors("exec", req.sandbox_id):
        result = await get_backend().exec(
            req.sandbox_id, req.command, timeout=req.timeout, env=req.env or None
        )
    # Log the command: on a single-user box this is the record of what the
    # agent actually did, and it is the thing you want when something breaks.
    #
    # Log the NAMES of injected secrets but never their values — this audit
    # file would otherwise become the easiest place to harvest credentials.
    audit("exec", "ok", sandbox_id=req.sandbox_id,
          command=req.command[:2000], exit_code=result.exit_code,
          injected_env=sorted(req.env.keys()) if req.env else [])
    return result.to_dict()


async def _execute_once(req: ExecRequest) -> dict:
    """Runs a command at most once per request_id. The command runs in its own task, so a dropped
    connection doesn't cancel it; the retry picks up the stored result or waits for the running one."""
    key, fingerprint = req.request_id, _exec_fingerprint(req)
    _prune_exec_results(time.time())
    if key in _exec_results:
        _, stored_fingerprint, result = _exec_results[key]
        if stored_fingerprint != fingerprint:
            raise HTTPException(status_code=409, detail="request_id was already used for a different command")
        audit("exec", "replayed", sandbox_id=req.sandbox_id, request_id=key)
        return result
    running = _exec_running.get(key)
    if running is not None:
        if running[0] != fingerprint:
            raise HTTPException(status_code=409, detail="request_id is in use by a different command")
        audit("exec", "rejoined", sandbox_id=req.sandbox_id, request_id=key)
        return await asyncio.shield(running[1])

    async def run() -> dict:
        try:
            async with backend_errors("exec", req.sandbox_id):
                result = await get_backend().exec(
                    req.sandbox_id, req.command, timeout=req.timeout, env=req.env or None
                )
            audit("exec", "ok", sandbox_id=req.sandbox_id, request_id=key,
                  command=req.command[:2000], exit_code=result.exit_code,
                  injected_env=sorted(req.env.keys()) if req.env else [])
            out = result.to_dict()
            _exec_results[key] = (time.time(), fingerprint, out)
            return out
        finally:
            _exec_running.pop(key, None)

    task = asyncio.create_task(run())
    _exec_running[key] = (fingerprint, task)
    return await asyncio.shield(task)


@app.post("/v1/read_file")
async def read_file(req: PathRequest, x_manager_token: str = Header(default="")):
    require_auth(x_manager_token)
    resolve(req.sandbox_id)
    import base64
    async with backend_errors("read_file", req.sandbox_id):
        data = await get_backend().read_file(req.sandbox_id, req.path, max_bytes=req.max_bytes)
    audit("read_file", "ok", sandbox_id=req.sandbox_id, path=req.path, bytes=len(data))
    return {"content_b64": base64.b64encode(data).decode()}


@app.post("/v1/write_file")
async def write_file(req: WriteRequest, x_manager_token: str = Header(default="")):
    require_auth(x_manager_token)
    resolve(req.sandbox_id)
    import base64
    try:
        content = base64.b64decode(req.content_b64, validate=True)
    except Exception:
        audit("write_file", "refused", sandbox_id=req.sandbox_id, reason="bad_base64")
        raise HTTPException(status_code=400, detail="content_b64 is not valid base64")
    if len(content) > MAX_WRITE_BYTES:
        audit("write_file", "refused", sandbox_id=req.sandbox_id, reason="too_large")
        raise HTTPException(status_code=413, detail="File too large")
    async with backend_errors("write_file", req.sandbox_id):
        await get_backend().write_file(req.sandbox_id, req.path, content)
    audit("write_file", "ok", sandbox_id=req.sandbox_id, path=req.path, bytes=len(content))
    return {"ok": True, "bytes": len(content)}


@app.post("/v1/pause")
async def pause(req: SandboxIdRequest, x_manager_token: str = Header(default="")):
    require_auth(x_manager_token)
    resolve(req.sandbox_id)
    async with backend_errors("pause", req.sandbox_id):
        await get_backend().pause(req.sandbox_id)
    audit("pause", "ok", sandbox_id=req.sandbox_id)
    return {"ok": True}


@app.post("/v1/resume")
async def resume(req: SandboxIdRequest, x_manager_token: str = Header(default="")):
    require_auth(x_manager_token)
    resolve(req.sandbox_id)
    async with backend_errors("resume", req.sandbox_id):
        await get_backend().resume(req.sandbox_id)
    audit("resume", "ok", sandbox_id=req.sandbox_id)
    return {"ok": True}


@app.post("/v1/destroy")
async def destroy(req: DestroyRequest, x_manager_token: str = Header(default="")):
    require_auth(x_manager_token)
    handle = resolve(req.sandbox_id)
    async with backend_errors("destroy", req.sandbox_id):
        await get_backend().destroy(req.sandbox_id, force=req.force)
    # A persistent sandbox survives a routine destroy, so it stays addressable (a later force-delete must find it).
    if req.force or not handle.persistent:
        _registry.pop(req.sandbox_id, None)
    audit("destroy", "ok", sandbox_id=req.sandbox_id, force=req.force)
    return {"ok": True}


# ---------------------------------------------------------------------------
# Egress approvals (opt-in; proxies to the egress-proxy admin interface)
# ---------------------------------------------------------------------------

EGRESS_ADMIN_URL = os.environ.get("EGRESS_ADMIN_URL", "http://egress-proxy:3129")
EGRESS_ADMIN_TOKEN = os.environ.get("EGRESS_ADMIN_TOKEN", "")
# Tests inject an httpx transport here; None = real network.
_egress_transport: Optional[httpx.AsyncBaseTransport] = None


async def _egress_call(method: str, path: str, payload: Optional[dict] = None) -> dict:
    if not EGRESS_ADMIN_TOKEN:
        raise HTTPException(status_code=503, detail="Egress control is not configured")
    try:
        async with httpx.AsyncClient(transport=_egress_transport, timeout=5.0) as client:
            resp = await client.request(
                method, EGRESS_ADMIN_URL.rstrip("/") + path, json=payload,
                headers={"Authorization": f"Bearer {EGRESS_ADMIN_TOKEN}"},
            )
    except httpx.HTTPError:
        raise HTTPException(status_code=502, detail="Egress proxy unreachable")
    if resp.status_code == 400:
        # The proxy rejected the host as invalid: that is the caller's error.
        raise HTTPException(status_code=400, detail="Egress proxy rejected the host as invalid")
    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail=f"Egress proxy refused ({resp.status_code})")
    try:
        data = resp.json()
    except ValueError:
        raise HTTPException(status_code=502, detail="Egress proxy returned invalid data")
    return data if isinstance(data, dict) else {}


@app.post("/v1/egress/pending")
async def egress_pending(req: EgressPendingRequest, x_manager_token: str = Header(default="")):
    """Hosts the proxy denied for not being allowlisted, awaiting a decision."""
    require_auth(x_manager_token)
    try:
        data = await _egress_call("GET", "/v1/pending")
    except HTTPException as exc:
        audit("egress_pending", "error", status=exc.status_code)
        raise
    audit("egress_pending", "ok", count=len(data.get("pending", {})))
    return data


@app.post("/v1/egress/decide")
async def egress_decide(req: EgressDecideRequest, x_manager_token: str = Header(default="")):
    """Approve (adds to the allowlist) or deny (mutes) a pending host."""
    require_auth(x_manager_token)
    try:
        data = await _egress_call("POST", f"/v1/{req.decision}", {"host": req.host})
    except HTTPException as exc:
        audit("egress_decide", "error", host=req.host, decision=req.decision, status=exc.status_code)
        raise
    audit("egress_decide", "ok", host=req.host, decision=req.decision)
    return data


@app.post("/v1/list")
async def list_sandboxes(x_manager_token: str = Header(default="")):
    """Sandboxes currently running, for the UI's computer picker."""
    require_auth(x_manager_token)
    async with backend_errors("list"):
        handles = await get_backend().list_sandboxes()
    # Merge in anything this process created, so a sandbox is listed even if
    # the backend's discovery misses it.
    known = {h.id: h for h in handles}
    for sid, handle in _registry.items():
        known.setdefault(sid, handle)
    return {"sandboxes": [h.to_dict() for h in known.values()]}


@app.post("/v1/health")
async def health(req: SandboxIdRequest, x_manager_token: str = Header(default="")):
    require_auth(x_manager_token)
    resolve(req.sandbox_id)
    async with backend_errors("health", req.sandbox_id):
        ok = await get_backend().health(req.sandbox_id)
    return {"ok": ok}
