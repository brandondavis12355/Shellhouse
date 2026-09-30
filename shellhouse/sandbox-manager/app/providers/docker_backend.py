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
import os
from typing import Optional

import docker

from providers.base import SandboxProvider, SandboxHandle, ExecResult

SHARED_CONTAINER = os.environ.get("SANDBOX_CONTAINER_NAME", "agent-sandbox")
SANDBOX_IMAGE = os.environ.get("SANDBOX_IMAGE", "agent-desktop:local")
SANDBOX_USER = os.environ.get("SANDBOX_USER", "box")
WORKSPACE = "/workspace"
WORKSPACE_VOLUME = os.environ.get("WORKSPACE_VOLUME", "shellhouse_workspace")
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

LABEL_MANAGED = "agent.sandbox"
LABEL_TASK = "agent.task_id"
LABEL_EPHEMERAL = "agent.ephemeral"


def _q(value: str) -> str:
    """Single-quote a value for safe use inside a shell command."""
    return "'" + value.replace("'", "'\"'\"'") + "'"


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
        safe_task = "".join(c for c in task_id if c.isalnum() or c in "-_")[:32]
        name = f"agent-sandbox-{safe_task}"
        port = await self._alloc_port(name)
        self._persistent[name] = persistent

        # Idempotent: reuse an existing container for this task if present.
        try:
            existing = self._get(name)
            if existing.status != "running":
                existing.start()
            return self._handle(name, port=port, persistent=persistent)
        except docker.errors.NotFound:
            pass

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

        def _run():
            return self._docker().containers.run(
                SANDBOX_IMAGE,
                name=name,
                detach=True,
                hostname=f"shellhouse-vm-{safe_task}",
                environment={"SCREEN_GEOM": os.environ.get("SCREEN_GEOM", "1280x800x24")},
                ports={"6080/tcp": ("127.0.0.1", port)},    # loopback only
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
                mem_limit=EPHEMERAL_MEM,
                nano_cpus=int(EPHEMERAL_CPUS * 1_000_000_000),
                pids_limit=EPHEMERAL_PIDS,
                labels={
                    LABEL_MANAGED: "true",
                    LABEL_TASK: task_id,
                    LABEL_EPHEMERAL: "false" if persistent else "true",
                },
                tty=True,
            )

        await asyncio.to_thread(_run)

        # Give this task its own workspace subdirectory. Done after start
        # because the symlink target must exist in the running container.
        if not PER_BOT_VOLUMES:
            await self.exec(
                name,
                f"mkdir -p /workspaces/{safe_task} && "
                f"rm -rf {WORKSPACE} && ln -sfn /workspaces/{safe_task} {WORKSPACE}",
                timeout=30,
            )
        return self._handle(name, port=port, persistent=persistent)

    def _handle(self, name: str, port: Optional[int], persistent: bool) -> SandboxHandle:
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
        return SandboxHandle(
            id=name,
            provider=self.name,
            workspace_host_path=WORKSPACE,
            vnc_url=vnc,
            persistent=persistent,
            metadata={"container": name, "novnc_port": port},
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
            return None
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
        await asyncio.to_thread(lambda: container.remove(force=True))
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
