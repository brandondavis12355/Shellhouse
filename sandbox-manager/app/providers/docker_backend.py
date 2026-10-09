"""
DockerBackend
=============
Development/local default. Every `task_id` gets its own container, named
`agent-sandbox-<task_id>` (one exception below); `persistent` controls what
happens to it afterward, not which container it is:

  persistent=True   -> kept around indefinitely, reused across restarts —
                       "this bot's own computer." Never destroyed by
                       destroy(), and re-adopted by reconcile() on a manager
                       restart.
  persistent=False  -> destroyed when the task finishes — a disposable
                       one-off machine.

Exception for backward compatibility: task_id "spike" with persistent=True
maps to the original compose-managed container (`SHARED_CONTAINER`, "My AI
Computer") rather than getting a new `agent-sandbox-spike` — that's the one
sandbox that predates per-task containers and already has real state (a
seeded /home/box and /workspace) worth not orphaning.

A fresh container starts fast (a couple of seconds, vs ~15s for a microVM) but
still shares the host kernel. For genuinely disposable machines, use
FirecrackerBackend.

Workspace isolation: by default each task/bot gets its OWN named volume
(`agent-workspace-<task>`) mounted at /workspace, so a compromised sandbox
cannot read or modify another bot's files. Existing data is copied one time
from the legacy shared volume's `<task>/` subdirectory. Set
SANDBOX_PER_BOT_VOLUMES=0 to fall back to the old layout (every container
mounts the shared volume and uses a per-task subdirectory — separated by path
convention only), which the web/API stack needs to serve screenshots.
"""
import asyncio
import base64
import hashlib
import os
import secrets
import string
from typing import Optional

import docker

from providers.base import SandboxProvider, SandboxHandle, ExecResult

SHARED_CONTAINER = os.environ.get("SANDBOX_CONTAINER_NAME", "agent-sandbox")
SANDBOX_IMAGE = os.environ.get("SANDBOX_IMAGE", "agent-desktop:local")
SANDBOX_USER = os.environ.get("SANDBOX_USER", "box")
WORKSPACE = "/workspace"
WORKSPACE_VOLUME = os.environ.get("WORKSPACE_VOLUME", "shellhouse_workspace")
ISOLATE_NETWORK = os.environ.get("SANDBOX_ISOLATE_NETWORK", "1").lower() in ("1", "true", "yes")
SANDBOX_NETWORK = "agent-sandboxes"
PER_BOT_VOLUMES = os.environ.get("SANDBOX_PER_BOT_VOLUMES", "1").lower() in ("1", "true", "yes")
NOVNC_URL = os.environ.get(
    "NOVNC_URL", "http://localhost:6080/vnc.html?autoconnect=1&resize=scale"
)
NOVNC_HOST = os.environ.get("NOVNC_HOST", "localhost")

# Per-task containers each need their own noVNC port on the host.
EPHEMERAL_PORT_BASE = int(os.environ.get("SANDBOX_PORT_BASE", "6100"))
EPHEMERAL_PORT_COUNT = int(os.environ.get("SANDBOX_PORT_COUNT", "32"))

# Resource ceilings for ephemeral sandboxes, so a runaway agent cannot take
# the host down with a fork bomb or by exhausting RAM.
EPHEMERAL_MEM = os.environ.get("SANDBOX_MEM_LIMIT", "2g")
EPHEMERAL_CPUS = float(os.environ.get("SANDBOX_CPU_LIMIT", "2"))
EPHEMERAL_PIDS = int(os.environ.get("SANDBOX_PIDS_LIMIT", "512"))

# Persistent (per-bot) sandboxes live indefinitely. OPT-IN
# (SANDBOX_PERSISTENT_LIMITS=1): they then get their own ceilings below;
# otherwise they keep using the ephemeral ones, exactly as before.
# Applied to NEW containers only.
PERSISTENT_LIMITS = os.environ.get("SANDBOX_PERSISTENT_LIMITS", "0").lower() in ("1", "true", "yes")
PERSISTENT_MEM = os.environ.get("SANDBOX_PERSISTENT_MEM_LIMIT", "4g")
PERSISTENT_CPUS = float(os.environ.get("SANDBOX_PERSISTENT_CPU_LIMIT", "4"))
PERSISTENT_PIDS = int(os.environ.get("SANDBOX_PERSISTENT_PIDS_LIMIT", "1024"))
# Optional rootfs size cap, e.g. "20G". Only works on storage drivers that
# support it (overlay2 on xfs with pquota); unset = no cap (the default).
PERSISTENT_STORAGE = os.environ.get("SANDBOX_PERSISTENT_STORAGE_LIMIT", "")

# Egress control (opt-in; see docs/EGRESS.md). "open" = unchanged behaviour.
EGRESS_PROXY_CONTAINER = os.environ.get("SANDBOX_EGRESS_PROXY_CONTAINER", "agent-egress-proxy")
EGRESS_PROXY_ALIAS = "egress-proxy"
EGRESS_PROXY_PORT = int(os.environ.get("SANDBOX_EGRESS_PROXY_PORT", "3128"))
EGRESS_NET_PREFIX = "agent-egress-"

LABEL_MANAGED = "agent.sandbox"
LABEL_TASK = "agent.task_id"
LABEL_EPHEMERAL = "agent.ephemeral"
LABEL_EGRESS_NET = "agent.egress_net"
LABEL_NOVNC_PORT = "agent.novnc_port"


def _q(value: str) -> str:
    """Single-quote a value for safe use inside a shell command."""
    return "'" + value.replace("'", "'\"'\"'") + "'"


def _safe_task(task_id: str) -> str:
    """Container/volume-safe form of a task id. Ids up to 32 characters are
    unchanged (so existing bots keep their containers/volumes); longer ones
    are shortened WITH a hash suffix so two ids sharing a 32-char prefix can
    never collapse onto the same container and workspace."""
    cleaned = "".join(c for c in task_id if c.isalnum() or c in "-_")
    if len(cleaned) <= 32:
        return cleaned
    digest = hashlib.sha256(task_id.encode()).hexdigest()[:8]
    return f"{cleaned[:23]}-{digest}"


def egress_mode() -> str:
    """"open" (default) or "allowlist". Read at call time. Anything else is an
    error: a typo must not silently leave a sandbox with open internet."""
    mode = os.environ.get("SANDBOX_EGRESS_MODE", "open").strip().lower() or "open"
    if mode not in ("open", "allowlist"):
        raise ValueError(f"SANDBOX_EGRESS_MODE must be 'open' or 'allowlist', got {mode!r}")
    return mode


def egress_env(proxy_url: str) -> dict:
    """Proxy environment for a sandbox container in allowlist mode."""
    # The proxy's own alias is exempt so the optional model relay (a raw TCP
    # listener on that host, see docs/EGRESS.md) is reached directly rather
    # than through the allowlist. No other privilege is granted.
    no_proxy = f"localhost,127.0.0.1,::1,{EGRESS_PROXY_ALIAS}"
    return {
        "SANDBOX_EGRESS_MODE": "allowlist",
        "HTTP_PROXY": proxy_url, "HTTPS_PROXY": proxy_url,
        "http_proxy": proxy_url, "https_proxy": proxy_url,
        "NO_PROXY": no_proxy, "no_proxy": no_proxy,
        # Debian's /usr/bin/chromium wrapper appends $CHROMIUM_FLAGS to its
        # command line. (UNVERIFIED on a real image; Chromium also honours
        # the *_proxy variables above when no other proxy config exists.)
        "CHROMIUM_FLAGS": f"--proxy-server={proxy_url} --proxy-bypass-list=<-loopback>",
    }


def resource_limits(persistent: bool) -> dict:
    """mem/cpu/pids (and optional storage) kwargs for containers.run()."""
    if persistent and PERSISTENT_LIMITS:
        limits = {
            "mem_limit": PERSISTENT_MEM,
            "nano_cpus": int(PERSISTENT_CPUS * 1_000_000_000),
            "pids_limit": PERSISTENT_PIDS,
        }
        if PERSISTENT_STORAGE:
            limits["storage_opt"] = {"size": PERSISTENT_STORAGE}
        return limits
    return {
        "mem_limit": EPHEMERAL_MEM,
        "nano_cpus": int(EPHEMERAL_CPUS * 1_000_000_000),
        "pids_limit": EPHEMERAL_PIDS,
    }


def _new_vnc_password() -> str:
    """8 characters: classic VNC auth ignores anything past 8."""
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(8))


class DockerBackend:
    name = "docker"

    def __init__(self):
        self._client: Optional[docker.DockerClient] = None
        self._ports: dict[str, int] = {}          # sandbox_id -> host noVNC port
        self._persistent: dict[str, bool] = {}    # sandbox_id -> keep across restarts?
        self._lock = asyncio.Lock()

    def _docker(self) -> docker.DockerClient:
        if self._client is None:
            self._client = docker.from_env()
        return self._client

    def _get(self, name: str):
        return self._docker().containers.get(name)

    # -- port allocation ----------------------------------------------------

    async def _alloc_port(self, sandbox_id: str) -> int:
        async with self._lock:
            if sandbox_id in self._ports:
                return self._ports[sandbox_id]
            used = set(self._ports.values())
            for offset in range(EPHEMERAL_PORT_COUNT):
                port = EPHEMERAL_PORT_BASE + offset
                if port not in used:
                    self._ports[sandbox_id] = port
                    return port
        raise RuntimeError(
            f"No free sandbox ports in "
            f"{EPHEMERAL_PORT_BASE}-{EPHEMERAL_PORT_BASE + EPHEMERAL_PORT_COUNT - 1}"
        )

    # -- lifecycle ----------------------------------------------------------

    async def create(self, task_id: str, persistent: bool = False) -> SandboxHandle:
        if persistent and task_id == "spike":
            return await self.start(SHARED_CONTAINER)
        return await self._create_or_attach(task_id, persistent=persistent)

    def _ensure_sandbox_network(self) -> Optional[str]:
        """A dedicated bridge with inter-container communication disabled, so
        one compromised sandbox can't reach another bot's desktop/VNC port
        over the bridge. (It can still reach the host gateway and the LAN;
        blocking that needs firewall rules on the host.) Blocking call."""
        if not ISOLATE_NETWORK:
            return None
        client = self._docker()
        try:
            client.networks.get(SANDBOX_NETWORK)
        except docker.errors.NotFound:
            try:
                client.networks.create(
                    SANDBOX_NETWORK, driver="bridge",
                    options={"com.docker.network.bridge.enable_icc": "false"},
                    labels={LABEL_MANAGED: "true"},
                )
            except Exception:
                return None   # fall back to the default bridge rather than fail creation
        return SANDBOX_NETWORK

    def _ensure_egress_network(self, safe_task: str) -> str:
        """Per-sandbox INTERNAL network (no route to the internet) with the
        egress proxy attached. Per-sandbox because enable_icc=false would also
        block sandbox->proxy traffic on a shared bridge. Fails closed: any
        error raises instead of falling back to an open network. Blocking."""
        client = self._docker()
        net_name = f"{EGRESS_NET_PREFIX}{safe_task}"
        try:
            existing = client.networks.get(net_name)
        except docker.errors.NotFound:
            existing = None
            client.networks.create(
                net_name, driver="bridge", internal=True,
                labels={LABEL_MANAGED: "true", LABEL_TASK: safe_task},
            )
        if existing is not None:
            self._assert_internal_network(existing, net_name)
        self._attach_proxy(net_name)
        return net_name

    @staticmethod
    def _assert_internal_network(net, net_name: str) -> None:
        attrs = getattr(net, "attrs", None) or {}
        labels = attrs.get("Labels") or {}
        if not attrs.get("Internal") or labels.get(LABEL_MANAGED) != "true":
            raise RuntimeError(
                f"Network {net_name} exists but is not a managed internal egress "
                "network; refusing to use it. Remove it and retry."
            )

    def _verify_contained(self, container) -> None:
        """An existing sandbox may only be reused in allowlist mode if it is
        attached solely to managed internal egress networks. Blocking."""
        cfg_labels = container.attrs.get("Config", {}).get("Labels") or {}
        nets = (container.attrs.get("NetworkSettings", {}) or {}).get("Networks") or {}
        problem = None
        if not cfg_labels.get(LABEL_EGRESS_NET):
            problem = "no egress label"
        elif not nets:
            problem = "no networks"
        else:
            for n in nets:
                if not n.startswith(EGRESS_NET_PREFIX):
                    problem = f"attached to non-egress network {n}"
                    break
                try:
                    self._assert_internal_network(self._docker().networks.get(n), n)
                except Exception as exc:
                    problem = str(exc)
                    break
        if problem:
            raise RuntimeError(
                f"Sandbox {container.name} is not contained ({problem}) but "
                "SANDBOX_EGRESS_MODE=allowlist. Recreate it (Delete bot / remove the "
                "container; the workspace volume survives) or set SANDBOX_EGRESS_MODE=open."
            )

    def _egress_state(self, name: str) -> str:
        try:
            labels = self._get(name).attrs.get("Config", {}).get("Labels") or {}
        except Exception:
            return "unknown"
        return "allowlist" if labels.get(LABEL_EGRESS_NET) else "open"

    def _attach_proxy(self, net_name: str) -> None:
        """Idempotently connect the proxy container to `net_name`. Blocking."""
        net = self._docker().networks.get(net_name)
        try:
            net.connect(EGRESS_PROXY_CONTAINER, aliases=[EGRESS_PROXY_ALIAS])
        except docker.errors.APIError as exc:
            if "already exists" not in str(exc).lower():
                raise

    def _remove_egress_network(self, name: str) -> None:
        """Best-effort cleanup after a sandbox container is removed."""
        net_name = name.replace("agent-sandbox-", EGRESS_NET_PREFIX, 1)
        if net_name == name:
            return
        client = self._docker()
        try:
            net = client.networks.get(net_name)
        except docker.errors.NotFound:
            return
        except Exception:
            return
        try:
            try:
                net.disconnect(EGRESS_PROXY_CONTAINER, force=True)
            except Exception:
                pass
            net.remove()
        except Exception:
            pass

    def _vnc_password_of(self, name: str) -> Optional[str]:
        """The per-container noVNC password, from the container's own env."""
        try:
            env = self._get(name).attrs.get("Config", {}).get("Env") or []
        except Exception:
            return None
        for item in env:
            if item.startswith("VNC_PASSWORD="):
                return item.split("=", 1)[1]
        return None

    def _ensure_bot_volume(self, safe_task: str) -> str:
        """Create this task's own workspace volume if it doesn't exist yet,
        seeding it once from the legacy shared volume's `<task>/` directory.
        Blocking (Docker SDK) — call from a worker thread."""
        client = self._docker()
        vol_name = f"agent-workspace-{safe_task}"
        try:
            client.volumes.get(vol_name)
            return vol_name
        except docker.errors.NotFound:
            pass
        client.volumes.create(name=vol_name, labels={LABEL_MANAGED: "true", LABEL_TASK: safe_task})
        # safe_task is [A-Za-z0-9_-] only, so it is safe to interpolate.
        script = (
            f'if [ -d "/old/{safe_task}" ]; then cp -a "/old/{safe_task}/." /new/; fi; '
            "chown -R box:box /new"
        )
        try:
            client.containers.run(
                SANDBOX_IMAGE,
                entrypoint=["/bin/bash", "-c"],
                command=[script],
                user="root",
                volumes={
                    WORKSPACE_VOLUME: {"bind": "/old", "mode": "ro"},
                    vol_name: {"bind": "/new", "mode": "rw"},
                },
                network_mode="none",
                cap_drop=["ALL"],
                cap_add=["CHOWN", "DAC_OVERRIDE", "FOWNER"],
                remove=True,
                detach=False,
            )
        except Exception:
            # Migration is best-effort: an empty per-bot volume is still a
            # correct, isolated workspace. Never block sandbox creation.
            pass
        return vol_name

    async def _create_or_attach(self, task_id: str, persistent: bool) -> SandboxHandle:
        safe_task = _safe_task(task_id)
        name = f"agent-sandbox-{safe_task}"
        port = await self._alloc_port(name)
        self._persistent[name] = persistent

        allowlist = egress_mode() == "allowlist"

        # Idempotent: reuse an existing container for this task if present.
        try:
            existing = self._get(name)
        except docker.errors.NotFound:
            existing = None
        if existing is not None:
            if allowlist:
                # Never hand back an uncontained sandbox in allowlist mode.
                try:
                    await asyncio.to_thread(self._verify_contained, existing)
                except Exception:
                    async with self._lock:
                        self._ports.pop(name, None)
                        self._persistent.pop(name, None)
                    raise
            if existing.status != "running":
                existing.start()
            return self._handle(name, port=port, persistent=persistent,
                                egress="allowlist" if allowlist else None)

        # Opt-in: lets `box` use passwordless sudo inside its own container.
        # Requires dropping no-new-privileges (setuid-root sudo can't elevate
        # under it) and restoring the caps root needs for package installs.
        # Default off — the sandbox is treated as compromised-by-default.
        allow_sudo = os.environ.get("SANDBOX_ALLOW_SUDO", "0").lower() in ("1", "true", "yes")
        security_opt = ["seccomp=unconfined"] + ([] if allow_sudo else ["no-new-privileges:true"])
        cap_add = ["SYS_CHROOT", "SETUID", "SETGID"]
        if allow_sudo:
            cap_add += ["CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "SETFCAP", "AUDIT_WRITE"]

        if PER_BOT_VOLUMES:
            vol_name = await asyncio.to_thread(self._ensure_bot_volume, safe_task)
            workspace_volumes = {vol_name: {"bind": WORKSPACE, "mode": "rw"}}
        else:
            workspace_volumes = {WORKSPACE_VOLUME: {"bind": "/workspaces", "mode": "rw"}}

        created = False
        try:
            if allowlist:
                # Fails closed (raises) rather than starting an open sandbox.
                network_name = await asyncio.to_thread(self._ensure_egress_network, safe_task)
            else:
                network_name = await asyncio.to_thread(self._ensure_sandbox_network)
            vnc_password = _new_vnc_password()

            environment = {
                "SCREEN_GEOM": os.environ.get("SCREEN_GEOM", "1280x800x24"),
                "VNC_PASSWORD": vnc_password,
            }
            labels = {
                LABEL_MANAGED: "true",
                LABEL_TASK: task_id,
                LABEL_EPHEMERAL: "false" if persistent else "true",
            }
            if allowlist:
                environment.update(egress_env(f"http://{EGRESS_PROXY_ALIAS}:{EGRESS_PROXY_PORT}"))
                labels[LABEL_EGRESS_NET] = network_name
                labels[LABEL_NOVNC_PORT] = str(port)

            kwargs = dict(
                name=name,
                detach=True,
                hostname=f"shellhouse-vm-{safe_task}",
                network=network_name,
                environment=environment,
                volumes=workspace_volumes,
                shm_size="1g",
                security_opt=security_opt,
                cap_drop=["ALL"],
                # SETUID/SETGID: supervisord (root) needs these to drop
                # privilege to `box` when starting the desktop session —
                # without them openbox/tint2 silently never start (see
                # sandbox/Dockerfile's matching cap_add for the compose-
                # managed SHARED_CONTAINER; per-task containers need the
                # same caps since they run the identical image/entrypoint).
                cap_add=cap_add,
                labels=labels,
                tty=True,
                **resource_limits(persistent),
            )
            if not allowlist:
                # (Allowlist mode publishes nothing: Docker cannot publish ports
                # from an internal network. The egress-proxy container forwards
                # loopback:<port> -> this sandbox's alias `sbx-<port>` instead.)
                kwargs["ports"] = {"6080/tcp": ("127.0.0.1", port)}    # loopback only

            def _run():
                return self._docker().containers.run(SANDBOX_IMAGE, **kwargs)

            await asyncio.to_thread(_run)
            created = True
            if allowlist:
                # Give the sandbox its VNC alias on its internal network.
                await asyncio.to_thread(self._alias_vnc, network_name, name, port)

            # Give this task its own workspace subdirectory. Done after start
            # because the symlink target must exist in the running container.
            if not PER_BOT_VOLUMES:
                await self.exec(
                    name,
                    f"mkdir -p /workspaces/{safe_task} && "
                    f"rm -rf {WORKSPACE} && ln -sfn /workspaces/{safe_task} {WORKSPACE}",
                    timeout=30,
                )

            # Canaries go in AFTER the /workspace symlink exists, so
            # /workspace/.env.production lands in the right place.
            if os.environ.get("SANDBOX_SEED_CANARIES", "0").lower() in ("1", "true", "yes"):
                # Idempotent, best-effort; no-op if the image lacks the script.
                await self.exec(name, "command -v seed-canaries.sh >/dev/null && seed-canaries.sh || true", timeout=30)
        except BaseException:
            await asyncio.to_thread(self._cleanup_failed, name, created, allowlist)
            async with self._lock:
                self._ports.pop(name, None)
                self._persistent.pop(name, None)
            raise
        return self._handle(name, port=port, persistent=persistent,
                            egress="allowlist" if allowlist else "open")

    def _cleanup_failed(self, name: str, container_created: bool, allowlist: bool) -> None:
        """Undo a half-finished create so nothing is left running or leaked.
        Best-effort and blocking."""
        try:
            self._get(name).remove(force=True)
        except Exception:
            pass
        if allowlist:
            self._remove_egress_network(name)

    def _alias_vnc(self, net_name: str, container_name: str, port: int) -> None:
        """Re-attach the sandbox to its internal network with the alias the
        proxy's VNC forwarder dials. Blocking."""
        net = self._docker().networks.get(net_name)
        try:
            net.disconnect(container_name, force=True)
        except Exception:
            pass
        net.connect(container_name, aliases=[f"sbx-{port}"])

    def _handle(self, name: str, port: Optional[int], persistent: bool,
                egress: Optional[str] = None) -> SandboxHandle:
        # NOVNC_URL is a fixed, compose-published address (port 6080) that
        # only ever means the ONE legacy SHARED_CONTAINER. Every other
        # container — persistent or not — has its own dynamically allocated
        # port and needs the per-port URL; keying this off `persistent`
        # alone (as before per-bot persistent containers existed) pointed
        # every persistent per-task container at the wrong, shared URL.
        vnc = (
            NOVNC_URL if name == SHARED_CONTAINER
            else f"http://{NOVNC_HOST}:{port}/vnc.html?autoconnect=1&resize=scale"
        )
        if name != SHARED_CONTAINER:
            password = self._vnc_password_of(name)
            if password:
                vnc += f"&password={password}"
        return SandboxHandle(
            id=name,
            provider=self.name,
            workspace_host_path=WORKSPACE,
            vnc_url=vnc,
            persistent=persistent,
            metadata={"container": name, "novnc_port": port,
                      "egress": egress or (self._egress_state(name) if name != SHARED_CONTAINER else "open")},
        )

    async def start(self, sandbox_id: str) -> SandboxHandle:
        container = self._get(sandbox_id)
        if container.status != "running":
            container.start()
        persistent = sandbox_id == SHARED_CONTAINER or self._persistent.get(sandbox_id, False)
        port = self._ports.get(sandbox_id) or self._bound_port(container)
        return self._handle(sandbox_id, port=port, persistent=persistent)

    def _bound_port(self, container) -> Optional[int]:
        """The host port actually published for 6080/tcp, read from Docker
        itself rather than our in-memory `_ports` dict — needed after a
        manager restart, when that dict is empty but the container (and its
        real port binding) is still there."""
        bindings = (container.attrs.get("NetworkSettings", {}).get("Ports") or {}).get("6080/tcp")
        if not bindings:
            # Allowlist-mode sandboxes publish nothing; their port is a label.
            label = (container.attrs.get("Config", {}).get("Labels") or {}).get(LABEL_NOVNC_PORT)
            return int(label) if label and label.isdigit() else None
        return int(bindings[0]["HostPort"])

    async def exec(
        self,
        sandbox_id: str,
        command: str,
        timeout: int = 120,
        env: Optional[dict] = None,
    ) -> ExecResult:
        def _run():
            container = self._get(sandbox_id)
            res = container.exec_run(
                cmd=["bash", "-lc", command],
                workdir=WORKSPACE,
                demux=True,
                user=SANDBOX_USER,
                # Injected as real environment variables, so the value never
                # appears in the command string (and so never in ps output,
                # shell history, or this service's audit log).
                environment=env or None,
            )
            stdout, stderr = res.output
            return ExecResult(
                exit_code=res.exit_code,
                stdout=(stdout or b"").decode(errors="replace")[:20_000],
                stderr=(stderr or b"").decode(errors="replace")[:20_000],
            )

        try:
            return await asyncio.wait_for(asyncio.to_thread(_run), timeout=timeout)
        except asyncio.TimeoutError:
            return ExecResult(exit_code=124, stdout="", stderr=f"Timed out after {timeout}s")
        except docker.errors.NotFound:
            return ExecResult(exit_code=127, stdout="", stderr=f"Sandbox {sandbox_id} is gone")

    # -- file IO ------------------------------------------------------------
    # Routed through the container rather than the host filesystem, so it
    # behaves identically for the shared and per-task workspaces.

    async def read_file(self, sandbox_id: str, path: str, max_bytes: int = 200_000) -> bytes:
        # Deliberately not routed through self.exec(): that method truncates
        # stdout to 20,000 chars, which is right for capping shell-command
        # output shown to the model but silently corrupts anything bigger
        # here — the base64 text for e.g. a screenshot easily runs past that,
        # and decoding a truncated base64 string produces truncated/invalid
        # binary data (seen in practice as Ollama's image decoder rejecting a
        # cut-off PNG with "not enough pixel data").
        def _run():
            container = self._get(sandbox_id)
            res = container.exec_run(
                cmd=["bash", "-lc", f"base64 -w0 {_q(path)}"],
                workdir=WORKSPACE,
                demux=True,
                user=SANDBOX_USER,
            )
            stdout, _ = res.output
            return res.exit_code, stdout or b""

        exit_code, stdout_bytes = await asyncio.to_thread(_run)
        if exit_code != 0 or not stdout_bytes.strip():
            raise FileNotFoundError(path)
        return base64.b64decode(stdout_bytes.strip())[:max_bytes]

    async def write_file(self, sandbox_id: str, path: str, content: bytes) -> None:
        encoded = base64.b64encode(content).decode()
        res = await self.exec(
            sandbox_id,
            f'mkdir -p "$(dirname {_q(path)})" && echo {_q(encoded)} | base64 -d > {_q(path)}',
            timeout=120,
        )
        if res.exit_code != 0:
            raise RuntimeError(f"write_file failed: {res.stderr}")

    async def pause(self, sandbox_id: str) -> None:
        self._get(sandbox_id).pause()

    async def resume(self, sandbox_id: str) -> None:
        self._get(sandbox_id).unpause()

    async def destroy(self, sandbox_id: str, force: bool = False) -> None:
        # Never tear down the compose-managed shared computer, or any
        # container created with persistent=True — "this bot's own
        # computer" is supposed to survive a destroy() the same way the
        # legacy shared one does. `force=True` is the one deliberate
        # exception (the app's "Delete bot" action, not routine cleanup) —
        # the shared legacy container still isn't destroyable even then,
        # since it isn't owned by any one bot.
        if sandbox_id == SHARED_CONTAINER:
            return
        if self._persistent.get(sandbox_id, False) and not force:
            return
        try:
            container = self._get(sandbox_id)
        except docker.errors.NotFound:
            async with self._lock:
                self._ports.pop(sandbox_id, None)
                self._persistent.pop(sandbox_id, None)
            return
        had_egress = bool((container.attrs.get("Config", {}).get("Labels") or {}).get(LABEL_EGRESS_NET))
        await asyncio.to_thread(lambda: container.remove(force=True))
        if had_egress:      # no extra Docker API calls for ordinary sandboxes
            await asyncio.to_thread(self._remove_egress_network, sandbox_id)
        async with self._lock:
            self._ports.pop(sandbox_id, None)
            self._persistent.pop(sandbox_id, None)

    async def health(self, sandbox_id: str) -> bool:
        try:
            return self._get(sandbox_id).status == "running"
        except docker.errors.NotFound:
            return False

    async def reconcile(self) -> list[SandboxHandle]:
        """
        Adopt the shared desktop container and every persistent per-task
        container (each bot's own computer), and reap ephemeral sandboxes
        left by a previous manager process. An orphaned ephemeral container
        belongs to a task that is no longer running, so it is removed, not
        adopted — but a persistent one is exactly the state a restart should
        not lose, so it's re-adopted with its real port re-read from Docker
        (the in-memory `_ports`/`_persistent` dicts don't survive a restart).
        """
        adopted: list[SandboxHandle] = []
        client = self._docker()

        try:
            shared = self._get(SHARED_CONTAINER)
            if shared.status != "running":
                shared.start()
            adopted.append(await self.start(SHARED_CONTAINER))
        except docker.errors.NotFound:
            pass

        for container in client.containers.list(
            all=True, filters={"label": f"{LABEL_EPHEMERAL}=false"}
        ):
            if container.name == SHARED_CONTAINER:
                continue
            if container.status != "running":
                container.start()
                container.reload()
            self._persistent[container.name] = True
            egress_net = (container.attrs.get("Config", {}).get("Labels") or {}).get(LABEL_EGRESS_NET)
            if egress_net:
                try:    # proxy container may have been recreated since
                    self._attach_proxy(egress_net)
                except Exception:
                    pass
            if port := self._bound_port(container):
                self._ports[container.name] = port
            adopted.append(self._handle(container.name, port=self._ports.get(container.name), persistent=True))

        for container in client.containers.list(
            all=True, filters={"label": f"{LABEL_EPHEMERAL}=true"}
        ):
            try:
                container.remove(force=True)
            except docker.errors.APIError:
                pass
        return adopted

    async def list_sandboxes(self) -> list[SandboxHandle]:
        # Was previously filtered to `agent.ephemeral=true` only, which
        # silently omitted every persistent per-task container (each bot's
        # own computer) from the list — fixed to cover both.
        out: list[SandboxHandle] = []
        try:
            self._get(SHARED_CONTAINER)
            out.append(await self.start(SHARED_CONTAINER))
        except docker.errors.NotFound:
            pass
        for container in self._docker().containers.list(filters={"label": f"{LABEL_MANAGED}=true"}):
            if container.name == SHARED_CONTAINER:
                continue
            persistent = self._persistent.get(container.name, False)
            port = self._ports.get(container.name) or self._bound_port(container)
            out.append(self._handle(container.name, port=port, persistent=persistent))
        return out


assert isinstance(DockerBackend(), SandboxProvider)
