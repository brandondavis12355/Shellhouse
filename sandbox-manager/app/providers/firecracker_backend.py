"""
FirecrackerBackend
==================
Each agent computer is its own microVM with its own kernel, so a browser
exploit or a malicious download is contained by a hypervisor boundary rather
than by shared-kernel namespaces. Runs inside the host-level manager service
(sandbox-manager/systemd/agent-sandbox-manager.service), never in a container.

Lifecycle per VM:

    1. Allocate a slot: VM id, tap device, /30 subnet, MAC, noVNC port.
    2. Copy the immutable base rootfs to the VM's own disk (persistent VMs
       keep theirs across restarts).
    3. Hard-link the kernel and disk into the VM's jail and start Firecracker
       under the jailer: chrooted, unprivileged uid, seccomp.
    4. Configure boot source / drive / network / machine over the API socket.
       Per-VM identity (IP, hostname, VNC password) goes on the kernel command
       line, so the host never mounts a guest-writable disk image.
    5. InstanceStart, then wait for the guest's sshd.
    6. exec(), read_file() and write_file() all go over SSH as `box`, so they
       see exactly what the guest sees. There is no host-shared directory:
       Firecracker has no virtio-fs.
    7. The guest's noVNC (port 6080) is forwarded from 127.0.0.1:<port> on the
       host, the same address shape the Docker backend publishes, so the app's
       SSH tunnel works unchanged.
    8. destroy() kills the VM and frees its tap, port, jail and (ephemeral) disk.

Host setup: sandbox/firecracker/scripts/ and docs/FIRECRACKER.md.
"""
import asyncio
import base64
import contextlib
import hashlib
import json
import os
import secrets
import shlex
import shutil
import string
from dataclasses import dataclass, field
from typing import Optional

import httpx

from providers.base import SandboxProvider, SandboxHandle, ExecResult

# --- host configuration -----------------------------------------------------

FC_BIN = os.environ.get("FIRECRACKER_BIN", "/usr/local/bin/firecracker")
FC_JAILER_BIN = os.environ.get("FIRECRACKER_JAILER_BIN", "/usr/local/bin/jailer")
FC_HOME = os.environ.get("FIRECRACKER_HOME", "/var/lib/agent-vm")
FC_KERNEL = os.environ.get("FIRECRACKER_KERNEL", f"{FC_HOME}/vmlinux")
FC_ROOTFS = os.environ.get("FIRECRACKER_ROOTFS", f"{FC_HOME}/rootfs.ext4")
FC_STATE_DIR = os.environ.get("FIRECRACKER_STATE_DIR", f"{FC_HOME}/instances")
# The jail must be on the same filesystem as the disks: they are hard-linked in.
FC_JAIL_BASE = os.environ.get("FIRECRACKER_JAIL_DIR", f"{FC_HOME}/jail")
FC_RUN_DIR = os.environ.get("FIRECRACKER_RUN_DIR", f"{FC_HOME}/run")
FC_LOG_DIR = os.environ.get("FIRECRACKER_LOG_DIR", "/var/log/agent-vm")
FC_SSH_KEY = os.environ.get("FIRECRACKER_SSH_KEY", f"{FC_HOME}/id_ed25519")
FC_USE_JAILER = os.environ.get("FIRECRACKER_USE_JAILER", "true").lower() in ("1", "true", "yes")
FC_UID = int(os.environ.get("FIRECRACKER_UID", "0") or 0)
FC_GID = int(os.environ.get("FIRECRACKER_GID", "0") or 0)
FC_DNS = os.environ.get("FIRECRACKER_DNS", "1.1.1.1")

# Per-VM resource limits. These are the hard ceiling the agent cannot exceed.
FC_VCPUS = int(os.environ.get("FIRECRACKER_VCPUS", "2"))
FC_MEM_MIB = int(os.environ.get("FIRECRACKER_MEM_MIB", "2048"))
FC_BOOT_TIMEOUT = int(os.environ.get("FIRECRACKER_BOOT_TIMEOUT", "90"))

SANDBOX_USER = os.environ.get("SANDBOX_USER", "box")
ALLOW_SUDO = os.environ.get("SANDBOX_ALLOW_SUDO", "0").lower() in ("1", "true", "yes")
SCREEN_GEOM = os.environ.get("SCREEN_GEOM", "1280x800x24")
NOVNC_HOST = os.environ.get("NOVNC_HOST", "localhost")
PORT_BASE = int(os.environ.get("SANDBOX_PORT_BASE", "6100"))
PORT_COUNT = int(os.environ.get("SANDBOX_PORT_COUNT", "32"))
# A bot that ran under the Docker backend keeps its files: its workspace volume
# is copied into its VM's disk the first time that disk is created.
IMPORT_DOCKER_WORKSPACES = os.environ.get("FIRECRACKER_IMPORT_DOCKER_WORKSPACES", "1").lower() in ("1", "true", "yes")
DOCKER_VOLUMES_DIR = os.environ.get("DOCKER_VOLUMES_DIR", "/var/lib/docker/volumes")

# `panic=1 reboot=k`: a guest kernel panic ends the VM instead of wedging it.
KERNEL_ARGS = "console=ttyS0 reboot=k panic=1 pci=off random.trust_cpu=on net.ifnames=0 quiet"
GUEST_VNC_PORT = 6080
OUTPUT_LIMIT = 20_000


def _q(value: str) -> str:
    return shlex.quote(value)


def _safe_task(task_id: str) -> str:
    """Same shape as DockerBackend's, so a bot's VM and its old Docker
    workspace volume share a name."""
    cleaned = "".join(c for c in task_id if c.isalnum() or c in "-_")
    if len(cleaned) <= 32:
        return cleaned
    digest = hashlib.sha256(task_id.encode()).hexdigest()[:8]
    return f"{cleaned[:23]}-{digest}"


def _new_vnc_password() -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(8))


@dataclass
class _Slot:
    """One VM's allocated host resources."""
    vm_id: str
    task_id: str
    persistent: bool
    index: int
    disk: str
    vnc_password: str = field(default_factory=_new_vnc_password)
    port: Optional[int] = None
    process: Optional[asyncio.subprocess.Process] = None
    forwarder: Optional[object] = None          # asyncio Server for the noVNC forward

    @property
    def tap(self) -> str:
        return f"fctap{self.index}"

    @property
    def host_ip(self) -> str:
        base = self.index * 4      # /30 blocks: .0 network, .1 host, .2 guest
        return f"172.30.{base // 256}.{base % 256 + 1}"

    @property
    def guest_ip(self) -> str:
        base = self.index * 4
        return f"172.30.{base // 256}.{base % 256 + 2}"

    @property
    def mac(self) -> str:
        return f"02:FC:00:00:{self.index >> 8:02X}:{self.index & 0xFF:02X}"

    @property
    def jail_id(self) -> str:
        # The jailer accepts only letters, digits and dashes, at most 64.
        return "fc" + hashlib.sha256(self.vm_id.encode()).hexdigest()[:20]

    @property
    def jail_dir(self) -> str:
        return os.path.join(FC_JAIL_BASE, os.path.basename(FC_BIN), self.jail_id)

    @property
    def jail_root(self) -> str:
        return os.path.join(self.jail_dir, "root")

    @property
    def api_socket(self) -> str:
        if FC_USE_JAILER:
            return os.path.join(self.jail_root, "run", "api.sock")
        return os.path.join(FC_RUN_DIR, f"{self.vm_id}.sock")

    @property
    def ssh_control(self) -> str:
        return os.path.join(FC_RUN_DIR, f"{self.jail_id}.ssh")

    def vm_path(self, host_path: str, name: str) -> str:
        """The path Firecracker is given: inside the chroot with the jailer."""
        return f"/{name}" if FC_USE_JAILER else host_path

    def alive(self) -> bool:
        return self.process is not None and self.process.returncode is None


class FirecrackerBackend:
    name = "firecracker"

    def __init__(self):
        self._slots: dict[str, _Slot] = {}          # vm_id -> running VM
        self._stopped: dict[str, str] = {}          # vm_id -> task_id, persistent VMs not booted yet
        self._by_task: dict[str, str] = {}          # task_id -> vm_id
        self._used_indexes: set[int] = set()
        self._used_ports: set[int] = set()
        self._lock = asyncio.Lock()
        self._vm_locks: dict[str, asyncio.Lock] = {}
        self._booting: dict[str, asyncio.Future] = {}   # task_id -> boot in progress

    def _vm_lock(self, key: str) -> asyncio.Lock:
        return self._vm_locks.setdefault(key, asyncio.Lock())

    @staticmethod
    def _persistent_disk(vm_id: str) -> str:
        return os.path.join(FC_STATE_DIR, f"{vm_id}.persistent.ext4")

    # -- lifecycle ----------------------------------------------------------

    async def create(self, task_id: str, persistent: bool = False) -> SandboxHandle:
        """Idempotent per task_id: a running VM for the task is returned as is."""
        async with self._vm_lock("task:" + task_id):
            vm_id = self._by_task.get(task_id)
            if vm_id and vm_id in self._slots and self._slots[vm_id].alive():
                return self._handle(self._slots[vm_id])
            safe = _safe_task(task_id)
            if persistent:
                vm_id = f"fc-{safe}"
            else:
                vm_id = f"fc-{safe}-{secrets.token_hex(3)}"
            slot = await self._boot_once(vm_id, task_id, persistent)
            return self._handle(slot)

    async def _boot_once(self, vm_id: str, task_id: str, persistent: bool) -> _Slot:
        """Boots, or joins the boot already under way for this task. The boot
        runs on its own, so a caller that goes away (the app timing out while
        several bots start at once) doesn't cancel it halfway; its retry gets
        the same VM."""
        fut = self._booting.get(task_id)
        if fut is None:
            fut = asyncio.ensure_future(self._boot(vm_id, task_id, persistent))
            self._booting[task_id] = fut

            def done(f: asyncio.Future) -> None:
                self._booting.pop(task_id, None)
                if not f.cancelled():
                    f.exception()       # retrieved here, so it is never "unretrieved"
            fut.add_done_callback(done)
        return await asyncio.shield(fut)

    async def _running(self, sandbox_id: str) -> _Slot:
        """The running VM, booting a persistent one that isn't running yet
        (after a manager restart or a host reboot)."""
        slot = self._slots.get(sandbox_id)
        if slot is not None and slot.alive():
            return slot
        async with self._vm_lock("task:" + (slot.task_id if slot else self._stopped.get(sandbox_id, sandbox_id))):
            slot = self._slots.get(sandbox_id)
            if slot is not None and slot.alive():
                return slot
            if slot is not None:
                # The VMM exited underneath us (guest shutdown, crash).
                await self._teardown(slot, delete_disk=not slot.persistent)
                if not slot.persistent:
                    raise RuntimeError(f"Sandbox {sandbox_id} has stopped")
                return await self._boot_once(sandbox_id, slot.task_id, True)
            task_id = self._stopped.get(sandbox_id)
            if task_id is None:
                raise RuntimeError(f"Unknown sandbox '{sandbox_id}'")
            return await self._boot_once(sandbox_id, task_id, True)

    async def _boot(self, vm_id: str, task_id: str, persistent: bool) -> _Slot:
        if not os.path.exists(FC_ROOTFS) or not os.path.exists(FC_KERNEL):
            raise RuntimeError(
                f"Firecracker guest image missing ({FC_KERNEL}, {FC_ROOTFS}). "
                "Run sandbox/firecracker/scripts/build-kernel.sh and build-rootfs.sh."
            )
        async with self._lock:
            index = next((i for i in range(1, 4000) if i not in self._used_indexes), None)
            if index is None:
                raise RuntimeError("No free VM slots")
            self._used_indexes.add(index)
        disk = self._persistent_disk(vm_id) if persistent else os.path.join(FC_STATE_DIR, f"{vm_id}.ext4")
        slot = _Slot(vm_id=vm_id, task_id=task_id, persistent=persistent, index=index, disk=disk)
        new_disk = not os.path.exists(disk)
        try:
            for d in (FC_STATE_DIR, FC_RUN_DIR, FC_LOG_DIR):
                os.makedirs(d, mode=0o700, exist_ok=True)
            await self._setup_tap(slot)
            await self._prepare_disk(slot, new_disk)
            await self._spawn_firecracker(slot)
            await self._configure_vm(slot)
            await self._api(slot, "PUT", "/actions", {"action_type": "InstanceStart"})
            await self._wait_for_ssh(slot)
            await self._start_ssh_master(slot)
            await self._start_forwarder(slot)
            if persistent and new_disk:
                await self._import_docker_workspace(slot)
        except BaseException:
            await self._teardown(slot, delete_disk=new_disk or not persistent)
            raise
        if persistent:
            # Written once the VM has booted: reconcile() only lists disks that have one.
            with open(os.path.join(FC_STATE_DIR, f"{vm_id}.json"), "w") as f:
                json.dump({"task_id": task_id}, f)
        self._slots[vm_id] = slot
        self._stopped.pop(vm_id, None)
        self._by_task[task_id] = vm_id
        return slot

    async def _setup_tap(self, slot: _Slot) -> None:
        """A routed point-to-point tap per VM (no shared bridge), so VM-to-VM
        traffic has to cross the host's forward chain, where it is dropped."""
        await self._run("ip", "link", "del", slot.tap, check=False)
        owner = ["user", str(FC_UID), "group", str(FC_GID)] if FC_USE_JAILER else []
        await self._run("ip", "tuntap", "add", "dev", slot.tap, "mode", "tap", *owner)
        await self._run("ip", "addr", "add", f"{slot.host_ip}/30", "dev", slot.tap)
        await self._run("ip", "link", "set", "dev", slot.tap, "up")

    async def _prepare_disk(self, slot: _Slot, new_disk: bool) -> None:
        if new_disk:
            # --reflink=auto: instant copy-on-write on btrfs/xfs, sparse copy elsewhere.
            await self._run("cp", "--reflink=auto", "--sparse=always", FC_ROOTFS, slot.disk + ".tmp")
            os.replace(slot.disk + ".tmp", slot.disk)
        if not FC_USE_JAILER:
            return
        os.chown(slot.disk, FC_UID, FC_GID)
        shutil.rmtree(slot.jail_dir, ignore_errors=True)
        os.makedirs(os.path.join(slot.jail_root, "run"), mode=0o755)
        os.chown(os.path.join(slot.jail_root, "run"), FC_UID, FC_GID)
        # Hard links (same filesystem): the VMM only sees these two files.
        os.link(FC_KERNEL, os.path.join(slot.jail_root, "vmlinux"))
        os.link(slot.disk, os.path.join(slot.jail_root, "rootfs.ext4"))

    async def _spawn_firecracker(self, slot: _Slot) -> None:
        """With the jailer (default) Firecracker runs chrooted in its own mount
        namespace as an unprivileged uid with seccomp filters, which is the
        configuration Firecracker's production guidance calls for. The manager
        runs as root so that the jailer's switch to that uid drops every
        capability."""
        with contextlib.suppress(FileNotFoundError):
            os.unlink(slot.api_socket)
        if FC_USE_JAILER:
            cmd = [
                FC_JAILER_BIN,
                "--id", slot.jail_id,
                "--exec-file", FC_BIN,
                "--uid", str(FC_UID),
                "--gid", str(FC_GID),
                "--chroot-base-dir", FC_JAIL_BASE,
                "--cgroup-version", "2",
                "--",
                "--api-sock", "/run/api.sock",
            ]
        else:
            cmd = [FC_BIN, "--api-sock", slot.api_socket]
        log = open(os.path.join(FC_LOG_DIR, f"{slot.vm_id}.log"), "wb")
        try:
            slot.process = await asyncio.create_subprocess_exec(
                *cmd, stdin=asyncio.subprocess.DEVNULL, stdout=log, stderr=asyncio.subprocess.STDOUT,
            )
        finally:
            log.close()
        for _ in range(200):
            if os.path.exists(slot.api_socket):
                return
            if not slot.alive():
                break
            await asyncio.sleep(0.05)
        raise RuntimeError(f"Firecracker didn't start for {slot.vm_id}: {self._log_tail(slot)}")

    @staticmethod
    def _log_tail(slot: _Slot) -> str:
        try:
            with open(os.path.join(FC_LOG_DIR, f"{slot.vm_id}.log"), "rb") as f:
                return f.read()[-1500:].decode(errors="replace").strip() or "(no output)"
        except OSError:
            return "(no log)"

    async def _api(self, slot: _Slot, method: str, path: str, body: dict) -> None:
        transport = httpx.AsyncHTTPTransport(uds=slot.api_socket)
        async with httpx.AsyncClient(transport=transport, base_url="http://localhost") as client:
            resp = await client.request(method, path, json=body, timeout=10.0)
            if resp.status_code >= 400:
                raise RuntimeError(f"Firecracker {method} {path} failed ({resp.status_code}): {resp.text}")

    def _boot_args(self, slot: _Slot) -> str:
        # Identity rides on the kernel command line: the kernel configures eth0
        # (CONFIG_IP_PNP), systemd sets the hostname, and the guest's
        # shellhouse-guest-init reads the shellhouse.* values.
        return " ".join([
            KERNEL_ARGS,
            f"ip={slot.guest_ip}::{slot.host_ip}:255.255.255.252::eth0:off",
            "systemd.hostname=shellhouse-" + slot.vm_id.replace("_", "-").lower(),
            f"shellhouse.vnc_password={slot.vnc_password}",
            f"shellhouse.sudo={1 if ALLOW_SUDO else 0}",
            f"shellhouse.screen={SCREEN_GEOM}",
            f"shellhouse.dns={FC_DNS}",
        ])

    async def _configure_vm(self, slot: _Slot) -> None:
        await self._api(slot, "PUT", "/machine-config", {
            "vcpu_count": FC_VCPUS,
            "mem_size_mib": FC_MEM_MIB,
            "smt": False,
        })
        await self._api(slot, "PUT", "/boot-source", {
            "kernel_image_path": slot.vm_path(FC_KERNEL, "vmlinux"),
            "boot_args": self._boot_args(slot),
        })
        await self._api(slot, "PUT", "/drives/rootfs", {
            "drive_id": "rootfs",
            "path_on_host": slot.vm_path(slot.disk, "rootfs.ext4"),
            "is_root_device": True,
            "is_read_only": False,
        })
        # Rate-limited so one runaway task can't starve its neighbours.
        await self._api(slot, "PUT", "/network-interfaces/eth0", {
            "iface_id": "eth0",
            "guest_mac": slot.mac,
            "host_dev_name": slot.tap,
            "rx_rate_limiter": {"bandwidth": {"size": 25_000_000, "refill_time": 1000}},
            "tx_rate_limiter": {"bandwidth": {"size": 25_000_000, "refill_time": 1000}},
        })
        await self._api(slot, "PUT", "/entropy", {})

    def _ssh_base(self, slot: _Slot) -> list[str]:
        return [
            "ssh", "-i", FC_SSH_KEY,
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=5",
            "-o", f"ControlPath={slot.ssh_control}",
            f"{SANDBOX_USER}@{slot.guest_ip}",
        ]

    async def _wait_for_ssh(self, slot: _Slot) -> None:
        loop = asyncio.get_running_loop()
        deadline = loop.time() + FC_BOOT_TIMEOUT
        while loop.time() < deadline:
            if not slot.alive():
                raise RuntimeError(f"VM {slot.vm_id} exited during boot: {self._log_tail(slot)}")
            rc, _, _ = await self._ssh_raw(slot, "true", timeout=8)
            if rc == 0:
                return
            await asyncio.sleep(1)
        raise RuntimeError(f"VM {slot.vm_id} did not become reachable in {FC_BOOT_TIMEOUT}s")

    async def _start_ssh_master(self, slot: _Slot) -> None:
        """One long-lived connection per VM; every exec rides on it, so a tool
        call doesn't pay for a new SSH handshake. Calls fall back to a direct
        connection if it ever goes away."""
        cmd = self._ssh_base(slot)
        cmd[1:1] = ["-M", "-N", "-f", "-o", "ControlPersist=yes", "-o", "ServerAliveInterval=15"]
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        with contextlib.suppress(asyncio.TimeoutError):
            await asyncio.wait_for(proc.wait(), timeout=15)

    async def _stop_ssh_master(self, slot: _Slot) -> None:
        if os.path.exists(slot.ssh_control):
            cmd = self._ssh_base(slot)
            cmd[1:1] = ["-O", "exit"]
            await self._run(*cmd, check=False, timeout=5)
            with contextlib.suppress(FileNotFoundError):
                os.unlink(slot.ssh_control)

    async def _start_forwarder(self, slot: _Slot) -> None:
        """127.0.0.1:<port> -> guest:6080, the Docker backend's address shape."""
        async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
            try:
                up_r, up_w = await asyncio.wait_for(
                    asyncio.open_connection(slot.guest_ip, GUEST_VNC_PORT), timeout=5)
            except (OSError, asyncio.TimeoutError):
                writer.close()
                return

            async def pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter) -> None:
                try:
                    while data := await src.read(65536):
                        dst.write(data)
                        await dst.drain()
                except (OSError, asyncio.CancelledError):
                    pass
                finally:
                    with contextlib.suppress(Exception):
                        dst.close()

            await asyncio.gather(pipe(reader, up_w), pipe(up_r, writer))

        async with self._lock:
            for port in range(PORT_BASE, PORT_BASE + PORT_COUNT):
                if port in self._used_ports:
                    continue
                try:
                    slot.forwarder = await asyncio.start_server(handle, "127.0.0.1", port)
                except OSError:
                    continue          # held by something else (an old Docker sandbox, say)
                slot.port = port
                self._used_ports.add(port)
                return
        raise RuntimeError(f"No free noVNC ports in {PORT_BASE}-{PORT_BASE + PORT_COUNT - 1}")

    async def _import_docker_workspace(self, slot: _Slot) -> None:
        if not IMPORT_DOCKER_WORKSPACES:
            return
        data = os.path.join(DOCKER_VOLUMES_DIR, f"agent-workspace-{_safe_task(slot.task_id)}", "_data")
        if not os.path.isdir(data):
            return
        ssh = " ".join(_q(a) for a in self._ssh_base(slot))
        await self._run(
            "sh", "-c",
            f"tar -C {_q(data)} -cf - . | {ssh} 'tar -xf - -C /workspace --no-same-owner'",
            check=False, timeout=900,
        )

    # -- execution ----------------------------------------------------------

    async def _ssh_raw(self, slot: _Slot, remote: str, stdin: bytes = b"",
                       timeout: int = 120) -> tuple[int, bytes, bytes]:
        proc = await asyncio.create_subprocess_exec(
            *self._ssh_base(slot), remote,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            out, err = await asyncio.wait_for(proc.communicate(stdin), timeout=timeout + 10)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            return 124, b"", f"Timed out after {timeout}s".encode()
        return proc.returncode, out, err

    async def exec(
        self,
        sandbox_id: str,
        command: str,
        timeout: int = 120,
        env: Optional[dict] = None,
    ) -> ExecResult:
        slot = await self._running(sandbox_id)
        # Secrets go on stdin as `export` lines, never in argv, so they don't
        # show up in either side's process list. `timeout` also ends the
        # command in the guest, not just the SSH client here.
        lines = [f"export {key}={_q(str(value))}" for key, value in (env or {}).items()]
        lines.append(command)
        rc, out, err = await self._ssh_raw(
            slot, f"cd /workspace 2>/dev/null; exec timeout -k 5 {int(timeout)} bash -l -s",
            stdin="\n".join(lines).encode(), timeout=timeout,
        )
        if rc == 124 and not out and not err:
            err = f"Timed out after {timeout}s".encode()
        return ExecResult(
            exit_code=rc,
            stdout=out.decode(errors="replace")[:OUTPUT_LIMIT],
            stderr=err.decode(errors="replace")[:OUTPUT_LIMIT],
        )

    # Files go through the guest (paths relative to /workspace, as with the
    # Docker backend), and are not truncated the way exec output is.

    async def read_file(self, sandbox_id: str, path: str, max_bytes: int = 200_000) -> bytes:
        slot = await self._running(sandbox_id)
        p = _q(path)
        rc, out, _ = await self._ssh_raw(
            slot, f"cd /workspace 2>/dev/null; [ -f {p} ] || exit 3; head -c {int(max_bytes)} -- {p} | base64 -w0",
            timeout=120,
        )
        if rc != 0:
            raise FileNotFoundError(path)
        return base64.b64decode(out.strip())

    async def write_file(self, sandbox_id: str, path: str, content: bytes) -> None:
        slot = await self._running(sandbox_id)
        p = _q(path)
        rc, _, err = await self._ssh_raw(
            slot, f'cd /workspace 2>/dev/null; mkdir -p -- "$(dirname -- {p})" && cat > {p}',
            stdin=content, timeout=120,
        )
        if rc != 0:
            raise RuntimeError(f"write_file failed: {err.decode(errors='replace')[:2000]}")

    async def start(self, sandbox_id: str) -> SandboxHandle:
        return self._handle(await self._running(sandbox_id))

    def _handle(self, slot: _Slot) -> SandboxHandle:
        return SandboxHandle(
            id=slot.vm_id,
            provider=self.name,
            workspace_host_path="/workspace",     # a guest path: files go through read_file/write_file
            ip_address=slot.guest_ip,
            vnc_url=(f"http://{NOVNC_HOST}:{slot.port}/vnc.html?autoconnect=1&resize=scale"
                     f"&password={slot.vnc_password}"),
            persistent=slot.persistent,
            metadata={"tap": slot.tap, "vcpus": FC_VCPUS, "mem_mib": FC_MEM_MIB,
                      "novnc_port": slot.port, "egress": "open"},
        )

    def _stopped_handle(self, vm_id: str) -> SandboxHandle:
        return SandboxHandle(id=vm_id, provider=self.name, workspace_host_path="/workspace",
                             persistent=True, metadata={"state": "stopped"})

    # -- pause / resume -----------------------------------------------------

    async def pause(self, sandbox_id: str) -> None:
        """Freezes the vCPUs; memory, browser tabs and processes stay as they are."""
        slot = await self._running(sandbox_id)
        await self._api(slot, "PATCH", "/vm", {"state": "Paused"})

    async def resume(self, sandbox_id: str) -> None:
        slot = self._slots.get(sandbox_id)
        if slot is None or not slot.alive():
            await self._running(sandbox_id)     # not running: boot it instead
            return
        await self._api(slot, "PATCH", "/vm", {"state": "Resumed"})

    async def destroy(self, sandbox_id: str, force: bool = False) -> None:
        """Persistent VMs ("this bot's own computer") survive a routine destroy,
        as with the Docker backend; `force` deletes the VM and its disk."""
        slot = self._slots.get(sandbox_id)
        persistent = slot.persistent if slot else sandbox_id in self._stopped
        if persistent and not force:
            return
        if slot is not None:
            await self._teardown(slot, delete_disk=True)
            self._slots.pop(sandbox_id, None)
            if self._by_task.get(slot.task_id) == sandbox_id:
                self._by_task.pop(slot.task_id, None)
        if persistent:
            self._stopped.pop(sandbox_id, None)
            for path in (self._persistent_disk(sandbox_id), os.path.join(FC_STATE_DIR, f"{sandbox_id}.json")):
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(path)

    async def _teardown(self, slot: _Slot, delete_disk: bool) -> None:
        if slot.forwarder is not None:
            slot.forwarder.close()
            slot.forwarder = None
        await self._stop_ssh_master(slot)
        if slot.alive():
            slot.process.kill()
        if slot.process is not None:
            with contextlib.suppress(Exception):
                await asyncio.wait_for(slot.process.wait(), timeout=10)
        await self._run("ip", "link", "del", slot.tap, check=False)
        shutil.rmtree(slot.jail_dir, ignore_errors=True)
        with contextlib.suppress(FileNotFoundError):
            os.unlink(slot.api_socket)
        if delete_disk:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(slot.disk)
        async with self._lock:
            self._used_indexes.discard(slot.index)
            if slot.port is not None:
                self._used_ports.discard(slot.port)

    async def health(self, sandbox_id: str) -> bool:
        slot = self._slots.get(sandbox_id)
        if slot is None or not slot.alive():
            return False
        return (await self._ssh_raw(slot, "true", timeout=5))[0] == 0

    async def reconcile(self) -> list[SandboxHandle]:
        """
        A VM can't be adopted by a new manager process: its VMM is gone with
        the old one (systemd stops them together) or, if one survived, its API
        socket owner is. So everything left over is cleaned up: VMMs, taps,
        jails, ephemeral disks. Persistent disks stay, and their VMs are
        registered as stopped under the same id; the first call that needs one
        boots it.
        """
        if FC_USE_JAILER and FC_UID:
            await self._run("pkill", "-KILL", "-u", str(FC_UID), "-x", "firecracker", check=False)
        else:
            await self._run("pkill", "-KILL", "-f", f"^{FC_BIN} ", check=False)
        rc, out = await self._run_out("ip", "-o", "link", "show")
        for line in out.splitlines():
            parts = line.split(":")
            if len(parts) > 1 and parts[1].strip().split("@")[0].startswith("fctap"):
                await self._run("ip", "link", "del", parts[1].strip().split("@")[0], check=False)
        shutil.rmtree(os.path.join(FC_JAIL_BASE, os.path.basename(FC_BIN)), ignore_errors=True)
        if os.path.isdir(FC_RUN_DIR):
            for name in os.listdir(FC_RUN_DIR):
                with contextlib.suppress(OSError):
                    os.unlink(os.path.join(FC_RUN_DIR, name))

        adopted: list[SandboxHandle] = []
        if not os.path.isdir(FC_STATE_DIR):
            return adopted
        for name in sorted(os.listdir(FC_STATE_DIR)):
            path = os.path.join(FC_STATE_DIR, name)
            if name.endswith(".persistent.ext4"):
                vm_id = name[: -len(".persistent.ext4")]
                try:
                    with open(os.path.join(FC_STATE_DIR, f"{vm_id}.json")) as f:
                        task_id = json.load(f)["task_id"]
                except (OSError, ValueError, KeyError):
                    continue
                self._stopped[vm_id] = task_id
                self._by_task[task_id] = vm_id
                adopted.append(self._stopped_handle(vm_id))
            elif name.endswith(".json") and not os.path.exists(self._persistent_disk(name[:-5])):
                with contextlib.suppress(OSError):
                    os.unlink(path)      # a record whose disk never got made
            elif name.endswith(".ext4") or name.endswith(".tmp"):
                with contextlib.suppress(OSError):
                    os.unlink(path)
        return adopted

    async def list_sandboxes(self) -> list[SandboxHandle]:
        out = [self._handle(s) for s in self._slots.values() if s.alive()]
        out += [self._stopped_handle(vm_id) for vm_id in self._stopped if vm_id not in self._slots]
        return out

    # -- helpers ------------------------------------------------------------

    @staticmethod
    async def _run(*argv: str, check: bool = True, timeout: int = 300) -> int:
        proc = await asyncio.create_subprocess_exec(
            *argv, stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
        )
        try:
            _, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            err = b"timed out"
        if check and proc.returncode != 0:
            raise RuntimeError(f"Host command failed: {argv[0]} {argv[1] if len(argv) > 1 else ''}: "
                               f"{err.decode(errors='replace').strip()}")
        return proc.returncode

    @staticmethod
    async def _run_out(*argv: str) -> tuple[int, str]:
        proc = await asyncio.create_subprocess_exec(
            *argv, stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await proc.communicate()
        return proc.returncode, out.decode(errors="replace")


assert isinstance(FirecrackerBackend(), SandboxProvider)
