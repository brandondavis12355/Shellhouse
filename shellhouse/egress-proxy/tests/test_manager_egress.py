"""Manager-side tests: docker_backend egress/limits (fake Docker client) and
the /v1/egress/* endpoints (fake proxy via httpx.MockTransport).
Nothing here touches a real Docker daemon: behaviour against real Docker is UNVERIFIED."""
import asyncio
import json
import os
import sys
import types

import docker
import httpx
import pytest

APP = os.path.join(os.path.dirname(__file__), "..", "..", "sandbox-manager", "app")
sys.path.insert(0, os.path.abspath(APP))
os.environ.setdefault("MANAGER_TOKEN", "test-token")
import tempfile  # noqa: E402
os.environ["MANAGER_AUDIT_LOG"] = os.path.join(tempfile.mkdtemp(), "audit.log")

import main  # noqa: E402
from providers import docker_backend as db  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402


# ---------------------------------------------------------------- fake docker
class FakeNet:
    def __init__(self, name, kw, client):
        self.name, self.kw, self.client = name, kw, client
        self.attrs = {"Internal": bool(kw.get("internal")), "Labels": kw.get("labels") or {}}
        self.connected = []   # (container, aliases)
        self.removed = False

    def connect(self, c, aliases=None, **_):
        self.connected.append((c, aliases))

    def disconnect(self, c, force=False):
        self.connected = [x for x in self.connected if x[0] != c]

    def remove(self):
        self.removed = True
        self.client.networks.items.pop(self.name, None)


class FakeNetworks:
    def __init__(self, client):
        self.client, self.items, self.fail_create, self.gets = client, {}, False, 0

    def get(self, name):
        self.gets += 1
        if name not in self.items:
            raise docker.errors.NotFound("nope")
        return self.items[name]

    def create(self, name, **kw):
        if self.fail_create:
            raise docker.errors.APIError("boom")
        self.items[name] = FakeNet(name, kw, self.client)
        return self.items[name]


class FakeContainer:
    def __init__(self, name, kw):
        self.name, self.kw, self.status = name, kw, "running"
        self.attrs = {"Config": {"Env": [f"{k}={v}" for k, v in kw["environment"].items()],
                                 "Labels": kw["labels"]},
                      "NetworkSettings": {"Ports": {}, "Networks": {kw["network"]: {}}}}
        self.removed = False
        self.execs = []

    def exec_run(self, cmd, **kw):
        self.execs.append(cmd)
        return types.SimpleNamespace(output=(b"", b""), exit_code=0)

    def remove(self, force=False):
        self.removed = True


class FakeContainers:
    def __init__(self):
        self.items, self.runs = {}, []

    def get(self, name):
        if name not in self.items:
            raise docker.errors.NotFound("nope")
        return self.items[name]

    def run(self, image, **kw):
        self.runs.append((image, kw))
        c = FakeContainer(kw["name"], kw)
        self.items[kw["name"]] = c
        return c


class FakeClient:
    def __init__(self):
        self.containers = FakeContainers()
        self.networks = FakeNetworks(self)


@pytest.fixture
def backend(monkeypatch):
    monkeypatch.setattr(db, "PER_BOT_VOLUMES", False)
    monkeypatch.delenv("SANDBOX_EGRESS_MODE", raising=False)
    monkeypatch.delenv("SANDBOX_SEED_CANARIES", raising=False)
    monkeypatch.setenv("SANDBOX_PORT_BASE", "6100")
    b = db.DockerBackend()
    b._client = FakeClient()
    return b


def create(b, task="t1", persistent=False):
    return asyncio.run(b.create(task, persistent=persistent))


def last_run(b):
    return b._client.containers.runs[-1][1]


# ------------------------------------------------------------ default (open)
def test_open_mode_unchanged(backend):
    create(backend)
    kw = last_run(backend)
    assert kw["network"] == "agent-sandboxes"
    assert "ports" in kw and kw["ports"]["6080/tcp"][0] == "127.0.0.1"
    assert not any(k.lower().endswith("_proxy") for k in kw["environment"])
    assert "CHROMIUM_FLAGS" not in kw["environment"]
    net = backend._client.networks.items["agent-sandboxes"]
    assert net.kw["options"]["com.docker.network.bridge.enable_icc"] == "false"
    assert "internal" not in net.kw
    # hardening intact
    assert kw["cap_drop"] == ["ALL"]
    assert "no-new-privileges:true" in kw["security_opt"]
    assert kw["shm_size"] == "1g"
    assert set(kw["cap_add"]) == {"SYS_CHROOT", "SETUID", "SETGID"}
    assert backend._client.containers.runs[-1][0] == db.SANDBOX_IMAGE


def test_invalid_mode_rejected(backend, monkeypatch):
    monkeypatch.setenv("SANDBOX_EGRESS_MODE", "alowlist")
    with pytest.raises(ValueError):
        create(backend)
    assert backend._client.containers.runs == []


# ---------------------------------------------------------------- allowlist
def test_allowlist_mode(backend, monkeypatch):
    monkeypatch.setenv("SANDBOX_EGRESS_MODE", "allowlist")
    h = create(backend, "bot1", persistent=True)
    kw = last_run(backend)
    net = backend._client.networks.items["agent-egress-bot1"]
    assert net.kw["internal"] is True
    assert kw["network"] == "agent-egress-bot1"
    assert "ports" not in kw
    env = kw["environment"]
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"):
        assert env[k] == "http://egress-proxy:3128"
    assert "localhost" in env["NO_PROXY"] and "127.0.0.1" in env["no_proxy"]
    assert "--proxy-server=http://egress-proxy:3128" in env["CHROMIUM_FLAGS"]
    assert env["SANDBOX_EGRESS_MODE"] == "allowlist"
    # proxy attached to the sandbox net, sandbox given its VNC alias
    assert (db.EGRESS_PROXY_CONTAINER, ["egress-proxy"]) in net.connected
    assert (kw["name"], ["sbx-6100"]) in net.connected
    assert kw["labels"][db.LABEL_EGRESS_NET] == "agent-egress-bot1"
    assert kw["cap_drop"] == ["ALL"] and "no-new-privileges:true" in kw["security_opt"]
    assert "6100" in h.vnc_url


def test_allowlist_fails_closed(backend, monkeypatch):
    monkeypatch.setenv("SANDBOX_EGRESS_MODE", "allowlist")
    backend._client.networks.fail_create = True
    with pytest.raises(docker.errors.APIError):
        create(backend)
    assert backend._client.containers.runs == []      # never fell back to open


def test_bound_port_from_label(backend):
    c = types.SimpleNamespace(attrs={"NetworkSettings": {"Ports": {}},
                                     "Config": {"Labels": {db.LABEL_NOVNC_PORT: "6107"}}})
    assert backend._bound_port(c) == 6107
    c2 = types.SimpleNamespace(attrs={"NetworkSettings": {"Ports": {}}, "Config": {}})
    assert backend._bound_port(c2) is None


def test_destroy_removes_egress_network(backend, monkeypatch):
    monkeypatch.setenv("SANDBOX_EGRESS_MODE", "allowlist")
    h = create(backend, "bot2", persistent=False)
    asyncio.run(backend.destroy(h.id))
    assert backend._client.containers.items[h.id].removed
    assert "agent-egress-bot2" not in backend._client.networks.items


def test_egress_env_pure():
    env = db.egress_env("http://p:1")
    assert env["HTTPS_PROXY"] == "http://p:1" and env["NO_PROXY"].startswith("localhost")
    assert "egress-proxy" in env["NO_PROXY"].split(",")      # model relay is reached directly


# ------------------------------------------------------------------- limits
def test_limits_ephemeral_vs_persistent(backend, monkeypatch):
    monkeypatch.setattr(db, "PERSISTENT_LIMITS", True)
    create(backend, "e1", persistent=False)
    e = last_run(backend)
    create(backend, "p1", persistent=True)
    p = last_run(backend)
    assert e["mem_limit"] == db.EPHEMERAL_MEM and e["pids_limit"] == db.EPHEMERAL_PIDS
    assert p["mem_limit"] == db.PERSISTENT_MEM and p["pids_limit"] == db.PERSISTENT_PIDS
    assert p["nano_cpus"] == int(db.PERSISTENT_CPUS * 1e9)
    assert "storage_opt" not in p and "storage_opt" not in e
    assert p["shm_size"] == "1g"       # Chromium needs shm


def test_persistent_limits_off_by_default(backend):
    create(backend, "p9", persistent=True)
    p = last_run(backend)
    assert p["mem_limit"] == db.EPHEMERAL_MEM and p["pids_limit"] == db.EPHEMERAL_PIDS
    assert "storage_opt" not in p


def test_storage_limit_opt_in(monkeypatch):
    monkeypatch.setattr(db, "PERSISTENT_LIMITS", True)
    monkeypatch.setattr(db, "PERSISTENT_STORAGE", "20G")
    assert db.resource_limits(True)["storage_opt"] == {"size": "20G"}
    assert "storage_opt" not in db.resource_limits(False)


# ------------------------------------------------------------------ canaries
def test_canary_seeding_opt_in(backend, monkeypatch):
    h = create(backend, "c0")
    assert not any("seed-canaries" in " ".join(c) for c in backend._client.containers.items[h.id].execs)
    monkeypatch.setenv("SANDBOX_SEED_CANARIES", "1")
    h = create(backend, "c1")
    assert any("seed-canaries.sh" in " ".join(c) for c in backend._client.containers.items[h.id].execs)


# ------------------------------------------------------- manager endpoints
H = {"X-Manager-Token": "test-token"}


@pytest.fixture
def api(monkeypatch):
    calls = []

    def handler(request: httpx.Request):
        calls.append((request.method, request.url.path, request.headers.get("authorization"),
                      json.loads(request.content) if request.content else None))
        if request.url.path == "/v1/pending":
            return httpx.Response(200, json={"pending": {"new.com": {"count": 2}}, "denied": [], "dropped": 0, "cap": 500})
        if request.url.path in ("/v1/allow", "/v1/deny"):
            return httpx.Response(200, json={"ok": True})
        return httpx.Response(404)

    monkeypatch.setattr(main, "_egress_transport", httpx.MockTransport(handler))
    monkeypatch.setattr(main, "EGRESS_ADMIN_TOKEN", "admintok")
    monkeypatch.setattr(main, "EGRESS_ADMIN_URL", "http://egress-proxy:3129")
    client = TestClient(main.app)
    client.calls = calls
    return client


def test_endpoints_require_auth(api):
    assert api.post("/v1/egress/pending", json={}).status_code == 401
    assert api.post("/v1/egress/pending", json={}, headers={"X-Manager-Token": "x"}).status_code == 401
    assert api.post("/v1/egress/decide", json={"host": "a.com", "decision": "allow"}).status_code == 401
    assert api.calls == []


def test_pending_ok(api):
    r = api.post("/v1/egress/pending", json={}, headers=H)
    assert r.status_code == 200 and "new.com" in r.json()["pending"]
    assert api.calls[0][:3] == ("GET", "/v1/pending", "Bearer admintok")


def test_decide_ok_and_audited(api, tmp_path, monkeypatch):
    monkeypatch.setattr(main, "LOG_PATH", str(tmp_path / "audit.log"))
    r = api.post("/v1/egress/decide", json={"host": "*.new.com", "decision": "allow"}, headers=H)
    assert r.status_code == 200
    assert api.calls[0][1] == "/v1/allow" and api.calls[0][3] == {"host": "*.new.com"}
    r = api.post("/v1/egress/decide", json={"host": "bad.com", "decision": "deny"}, headers=H)
    assert api.calls[1][1] == "/v1/deny"
    ops = [json.loads(l) for l in open(tmp_path / "audit.log")]
    assert [(o["op"], o["outcome"], o["decision"]) for o in ops if o["op"] == "egress_decide"] == \
        [("egress_decide", "ok", "allow"), ("egress_decide", "ok", "deny")]


@pytest.mark.parametrize("body", [
    {"host": "a.com"}, {"decision": "allow"}, {"host": "a.com", "decision": "maybe"},
    {"host": "a.com", "decision": "allow", "extra": 1}, {"host": "", "decision": "allow"},
    {"host": "a.com@evil.com", "decision": "allow"}, {"host": "a.com/x", "decision": "allow"},
    {"host": "a b.com", "decision": "allow"}, {"host": "x" * 254, "decision": "allow"},
    {"host": "[::1]", "decision": "allow"}, {"host": "a.com:80", "decision": "allow"},
])
def test_decide_schema_rejects(api, body):
    assert api.post("/v1/egress/decide", json=body, headers=H).status_code == 422
    assert api.calls == []


def test_pending_forbids_extra(api):
    assert api.post("/v1/egress/pending", json={"x": 1}, headers=H).status_code == 422


def test_not_configured_and_proxy_down(api, monkeypatch):
    monkeypatch.setattr(main, "EGRESS_ADMIN_TOKEN", "")
    assert api.post("/v1/egress/pending", json={}, headers=H).status_code == 503
    monkeypatch.setattr(main, "EGRESS_ADMIN_TOKEN", "t")

    def boom(request):
        raise httpx.ConnectError("down")
    monkeypatch.setattr(main, "_egress_transport", httpx.MockTransport(boom))
    assert api.post("/v1/egress/pending", json={}, headers=H).status_code == 502
    monkeypatch.setattr(main, "_egress_transport", httpx.MockTransport(lambda r: httpx.Response(401)))
    assert api.post("/v1/egress/decide", json={"host": "a.com", "decision": "allow"}, headers=H).status_code == 502


# ------------------------------------------------- review fixes (backend)
def test_open_mode_metadata_and_no_extra_calls_on_destroy(backend):
    h = create(backend, "o1")
    assert h.metadata["egress"] == "open"
    before = backend._client.networks.gets
    asyncio.run(backend.destroy(h.id))
    assert backend._client.networks.gets == before     # no Docker network calls


def test_allowlist_handle_reports_containment(backend, monkeypatch):
    monkeypatch.setenv("SANDBOX_EGRESS_MODE", "allowlist")
    assert create(backend, "a1").metadata["egress"] == "allowlist"


def test_reuse_uncontained_container_refused_in_allowlist(backend, monkeypatch):
    h = create(backend, "r1")                       # created in open mode
    monkeypatch.setenv("SANDBOX_EGRESS_MODE", "allowlist")
    with pytest.raises(RuntimeError, match="not contained"):
        create(backend, "r1")
    # still allowed (and unchanged) when mode is open
    monkeypatch.delenv("SANDBOX_EGRESS_MODE")
    assert create(backend, "r1").id == h.id


def test_reuse_contained_container_ok_and_tampered_refused(backend, monkeypatch):
    monkeypatch.setenv("SANDBOX_EGRESS_MODE", "allowlist")
    h = create(backend, "r2")
    assert create(backend, "r2").metadata["egress"] == "allowlist"
    # network silently replaced by a non-internal one with the same name
    backend._client.networks.items["agent-egress-r2"].attrs["Internal"] = False
    with pytest.raises(RuntimeError):
        create(backend, "r2")
    # container additionally attached to another network
    backend._client.networks.items["agent-egress-r2"].attrs["Internal"] = True
    backend._client.containers.items[h.id].attrs["NetworkSettings"]["Networks"]["bridge"] = {}
    with pytest.raises(RuntimeError, match="non-egress"):
        create(backend, "r2")


def test_existing_network_must_be_internal_and_managed(backend, monkeypatch):
    monkeypatch.setenv("SANDBOX_EGRESS_MODE", "allowlist")
    backend._client.networks.create("agent-egress-n1")          # no internal, no label
    with pytest.raises(RuntimeError, match="not a managed internal"):
        create(backend, "n1")
    assert backend._client.containers.runs == []


def test_cleanup_on_partial_failure(backend, monkeypatch):
    monkeypatch.setenv("SANDBOX_EGRESS_MODE", "allowlist")

    def boom(*a, **k):
        raise RuntimeError("alias failed")
    monkeypatch.setattr(backend, "_alias_vnc", boom)
    with pytest.raises(RuntimeError, match="alias failed"):
        create(backend, "f1")
    assert backend._client.containers.items["agent-sandbox-f1"].removed
    assert "agent-egress-f1" not in backend._client.networks.items
    assert "agent-sandbox-f1" not in backend._ports


def test_cleanup_when_run_fails(backend, monkeypatch):
    monkeypatch.setenv("SANDBOX_EGRESS_MODE", "allowlist")
    def bad_run(image, **kw):
        raise docker.errors.APIError("run failed")
    monkeypatch.setattr(backend._client.containers, "run", bad_run)
    with pytest.raises(docker.errors.APIError):
        create(backend, "f2")
    assert "agent-egress-f2" not in backend._client.networks.items


def test_canaries_seeded_after_workspace_symlink(backend, monkeypatch):
    monkeypatch.setattr(db, "PER_BOT_VOLUMES", False)
    monkeypatch.setenv("SANDBOX_SEED_CANARIES", "1")
    h = create(backend, "s1")
    cmds = [" ".join(c) for c in backend._client.containers.items[h.id].execs]
    link = next(i for i, c in enumerate(cmds) if "ln -sfn" in c)
    seed = next(i for i, c in enumerate(cmds) if "seed-canaries" in c)
    assert link < seed


# ------------------------------------------------ review fixes (manager)
def test_decide_passes_proxy_400_through(api, monkeypatch):
    monkeypatch.setattr(main, "_egress_transport", httpx.MockTransport(lambda r: httpx.Response(400, json={"error": "invalid_host"})))
    r = api.post("/v1/egress/decide", json={"host": "*.com", "decision": "allow"}, headers=H)
    assert r.status_code == 400


# ------------------------------------------------------------- compose
def test_compose_has_no_required_vars_in_profile_service_and_defaults_off():
    import yaml
    path = os.path.join(os.path.dirname(__file__), "..", "..", "docker-compose.yml")
    text = open(path).read()
    doc = yaml.safe_load(text)
    svc = doc["services"]["egress-proxy"]
    assert svc["profiles"] == ["egress"]
    blob = json.dumps(svc)
    assert ":?" not in blob and "EGRESS_ADMIN_TOKEN=${EGRESS_ADMIN_TOKEN:-}" in blob
    env = doc["services"]["sandbox-manager"]["environment"]
    assert "SANDBOX_EGRESS_MODE=${SANDBOX_EGRESS_MODE:-open}" in env
    assert "SANDBOX_PERSISTENT_LIMITS=${SANDBOX_PERSISTENT_LIMITS:-0}" in " ".join(env).split("   #")[0] or \
        any(e.startswith("SANDBOX_PERSISTENT_LIMITS=${SANDBOX_PERSISTENT_LIMITS:-0}") for e in env)
    assert any(e.startswith("SANDBOX_SEED_CANARIES=${SANDBOX_SEED_CANARIES:-0}") for e in env)
