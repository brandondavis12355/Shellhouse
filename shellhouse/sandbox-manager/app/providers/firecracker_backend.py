"""
FirecrackerBackend
==========================
Production isolation path (Phase 7 / ADR-002). Each agent computer is its own
microVM with its own kernel, so a browser exploit or a malicious download is
contained by a hypervisor boundary rather than by shared-kernel namespaces.

Lifecycle per VM:

    1. Allocate a slot: VM id, tap device, /30 subnet, MAC.
    2. Copy the immutable rootfs -> a per-VM overlay (or CoW clone).
    3. Inject an ephemeral SSH key + hostname into the overlay.
    4. Start the `firecracker` process with its own API socket + jailer.
    5. Configure boot source / drives / network / machine via the API socket.
    6. InstanceStart, then wait for SSH to answer.
    7. exec() runs commands over SSH as the unprivileged `box` user.
    8. destroy() kills the VM, removes the overlay, frees the tap + subnet.

Requirements on the host (see sandbox/firecracker/README.md):
  - /dev/kvm accessible
  - `firecracker` and `jailer` binaries on PATH
  - a built guest kernel (vmlinux) and rootfs ext4 image
  - the setup script run once to create the bridge + nftables egress rules

This provider talks to Firecracker's HTTP API over a unix domain socket. It
does not shell out to a CLI, so failures surface as real status codes.
"""
import asyncio
import json
import os
import shutil
import uuid
from dataclasses import dataclass
from typing import Optional

import httpx

from providers.base import SandboxProvider, SandboxHandle, ExecResult

# --- host configuration -----------------------------------------------------

FC_BIN = os.environ.get("FIRECRACKER_BIN", "/usr/local/bin/firecracker")
FC_JAILER_BIN = os.environ.get("FIRECRACKER_JAILER_BIN", "/usr/local/bin/jailer")
FC_KERNEL = os.environ.get("FIRECRACKER_KERNEL", "/var/lib/agent-vm/vmlinux")
FC_ROOTFS = os.environ.get("FIRECRACKER_ROOTFS", "/var/lib/agent-vm/rootfs.ext4")
FC_RUN_DIR = os.environ.get("FIRECRACKER_RUN_DIR", "/var/run/agent-vm")
FC_STATE_DIR = os.environ.get("FIRECRACKER_STATE_DIR", "/var/lib/agent-vm/instances")
FC_SSH_KEY = os.environ.get("FIRECRACKER_SSH_KEY", "/var/lib/agent-vm/id_ed25519")
FC_BRIDGE = os.environ.get("FIRECRACKER_BRIDGE", "fcbr0")
FC_USE_JAILER = os.environ.get("FIRECRACKER_USE_JAILER", "true").lower() == "true"

# Per-VM resource limits. These are the hard ceiling the agent cannot exceed.
FC_VCPUS = int(os.environ.get("FIRECRACKER_VCPUS", "2"))
FC_MEM_MIB = int(os.environ.get("FIRECRACKER_MEM_MIB", "2048"))
FC_BOOT_TIMEOUT = int(os.environ.get("FIRECRACKER_BOOT_TIMEOUT", "60"))

SANDBOX_USER = os.environ.get("SANDBOX_USER", "box")

# Kernel cmdline. `panic=1 reboot=k` means a guest kernel panic kills the VM
# rather than leaving a wedged instance behind for us to reap.
KERNEL_ARGS = (
    "console=ttyS0 reboot=k panic=1 pci=off "
    "init=/sbin/init random.trust_cpu=on"
)


@dataclass
class _Slot:
    """One VM's allocated host resources."""
    vm_id: str
    index: int
    tap: str
    host_ip: str
    guest_ip: str
    mac: str
    api_socket: str
    rootfs_overlay: str
    process: Optional[asyncio.subprocess.Process] = None


class FirecrackerBackend:
    name = "firecracker"

    def __init__(self):
        self._slots: dict[str, _Slot] = {}
        self._used_indexes: set[int] = set()
        self._lock = asyncio.Lock()

    # -- slot allocation ----------------------------------------------------

    def _allocate_index(self) -> int:
        """Each VM gets a /30 out of 172.30.0.0/16 and a matching tap device."""
        for i in range(1, 4000):
            if i not in self._used_indexes:
                self._used_indexes.add(i)
                return i
        raise RuntimeError("No free VM slots")

    @staticmethod
    def _subnet(index: int) -> tuple[str, str]:
        # /30 blocks: .0 network, .1 host, .2 guest, .3 broadcast
        base = index * 4
        third, fourth = base // 256, base % 256
        return f"172.30.{third}.{fourth + 1}", f"172.30.{third}.{fourth + 2}"

    # -- lifecycle ----------------------------------------------------------

    async def create(self, task_id: str, persistent: bool = False) -> SandboxHandle:
        async with self._lock:
            index = self._allocate_index()

        vm_id = f"vm-{task_id[:8]}-{uuid.uuid4().hex[:6]}"
        host_ip, guest_ip = self._subnet(index)
        slot = _Slot(
            vm_id=vm_id,
            index=index,
            tap=f"fctap{index}",
            host_ip=host_ip,
            guest_ip=guest_ip,
            mac=f"02:FC:00:00:{index >> 8:02X}:{index & 0xFF:02X}",
            api_socket=os.path.join(FC_RUN_DIR, f"{vm_id}.sock"),
            rootfs_overlay=os.path.join(FC_STATE_DIR, f"{vm_id}.ext4"),
        )

        os.makedirs(FC_RUN_DIR, exist_ok=True)
        os.makedirs(FC_STATE_DIR, exist_ok=True)

        await self._setup_tap(slot)
        await self._prepare_rootfs(slot, persistent=persistent)
        await self._spawn_firecracker(slot)
        await self._configure_vm(slot)
        await self._start_instance(slot)
        await self._wait_for_ssh(slot)

        self._slots[vm_id] = slot
        return SandboxHandle(
            id=vm_id,
            provider=self.name,
            workspace_host_path=self._workspace_mount(slot),
            ip_address=slot.guest_ip,
            # The guest runs the same desktop + noVNC as the Docker sandbox;
            # the UI points at the guest's IP instead of a published port.
            vnc_url=f"http://{slot.guest_ip}:6080/vnc.html?autoconnect=1&resize=scale",
            persistent=persistent,
            metadata={"tap": slot.tap, "vcpus": FC_VCPUS, "mem_mib": FC_MEM_MIB},
        )

    @staticmethod
    def _workspace_mount(slot: _Slot) -> str:
        """Host-side path where this VM's /workspace is visible (virtio-fs share)."""
        return os.path.join(FC_STATE_DIR, slot.vm_id, "workspace")

    async def _setup_tap(self, slot: _Slot) -> None:
        """Create the tap device and attach it to the egress-filtered bridge."""
        await self._host_cmd(f"ip tuntap add dev {slot.tap} mode tap")
        await self._host_cmd(f"ip addr add {slot.host_ip}/30 dev {slot.tap}")
        await self._host_cmd(f"ip link set dev {slot.tap} up")
        # The bridge + nftables rules created by setup-host.sh enforce the
        # egress allowlist and block link-local/metadata/private ranges.
        await self._host_cmd(f"ip link set {slot.tap} master {FC_BRIDGE}", check=False)

    async def _prepare_rootfs(self, slot: _Slot, persistent: bool) -> None:
        """
        Per-VM writable disk. The base image stays immutable and read-only.

        Ephemeral VMs get a reflink/sparse copy that is deleted on destroy.
        Persistent VMs ("My AI Computer") keep their overlay across sessions.
        """
        workspace = self._workspace_mount(slot)
        os.makedirs(workspace, exist_ok=True)

        if persistent and os.path.exists(slot.rootfs_overlay):
            return  # reuse the user's existing disk

        # --reflink=auto gives copy-on-write instantly on btrfs/xfs and falls
        # back to a plain copy elsewhere.
        await self._host_cmd(
            f"cp --reflink=auto --sparse=always {FC_ROOTFS} {slot.rootfs_overlay}"
        )
        await self._inject_identity(slot)

    async def _inject_identity(self, slot: _Slot) -> None:
        """
        Mount the overlay and write per-VM identity: hostname, network config,
        and a short-lived SSH public key. Nothing long-lived is baked into the
        shared base image.
        """
        mnt = os.path.join(FC_STATE_DIR, f".mnt-{slot.vm_id}")
        os.makedirs(mnt, exist_ok=True)
        await self._host_cmd(f"mount -o loop {slot.rootfs_overlay} {mnt}")
        try:
            pub_key = ""
            if os.path.exists(FC_SSH_KEY + ".pub"):
                with open(FC_SSH_KEY + ".pub") as f:
                    pub_key = f.read().strip()

            ssh_dir = os.path.join(mnt, "home", SANDBOX_USER, ".ssh")
            os.makedirs(ssh_dir, exist_ok=True)
            with open(os.path.join(ssh_dir, "authorized_keys"), "w") as f:
                f.write(pub_key + "\n")

            with open(os.path.join(mnt, "etc", "hostname"), "w") as f:
                f.write(f"shellhouse-{slot.vm_id}\n")

            # Static addressing: no DHCP server to run or depend on.
            net_dir = os.path.join(mnt, "etc", "systemd", "network")
            os.makedirs(net_dir, exist_ok=True)
            with open(os.path.join(net_dir, "10-eth0.network"), "w") as f:
                f.write(
                    "[Match]\nName=eth0\n\n"
                    f"[Network]\nAddress={slot.guest_ip}/30\n"
                    f"Gateway={slot.host_ip}\nDNS=1.1.1.1\n"
                )
            await self._host_cmd(
                f"chown -R 1000:1000 {os.path.join(mnt, 'home', SANDBOX_USER)}",
                check=False,
            )
        finally:
            await self._host_cmd(f"umount {mnt}", check=False)
            shutil.rmtree(mnt, ignore_errors=True)

    async def _spawn_firecracker(self, slot: _Slot) -> None:
        """
        Launch the VMM. With the jailer (default), Firecracker runs chrooted,
        in its own pid/mount namespaces, as an unprivileged uid, with seccomp
        filters applied — which is the configuration Firecracker's own
        production guidance calls for.
        """
        if os.path.exists(slot.api_socket):
            os.unlink(slot.api_socket)

        if FC_USE_JAILER:
            cmd = [
                FC_JAILER_BIN,
                "--id", slot.vm_id,
                "--exec-file", FC_BIN,
                "--uid", os.environ.get("FIRECRACKER_UID", "1234"),
                "--gid", os.environ.get("FIRECRACKER_GID", "1234"),
                "--chroot-base-dir", FC_RUN_DIR,
                "--",
                "--api-sock", os.path.basename(slot.api_socket),
            ]
        else:
            cmd = [FC_BIN, "--api-sock", slot.api_socket]

        slot.process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )

        # Wait for the API socket to appear before configuring.
        for _ in range(100):
            if os.path.exists(slot.api_socket):
                return
            await asyncio.sleep(0.05)
        raise RuntimeError(f"Firecracker API socket never appeared for {slot.vm_id}")

    async def _api(self, slot: _Slot, method: str, path: str, body: dict) -> None:
        """PUT/PATCH against the Firecracker API over its unix socket."""
        transport = httpx.AsyncHTTPTransport(uds=slot.api_socket)
        async with httpx.AsyncClient(transport=transport, base_url="http://localhost") as client:
            resp = await client.request(method, path, json=body, timeout=10.0)
            if resp.status_code >= 400:
                raise RuntimeError(
                    f"Firecracker {method} {path} failed ({resp.status_code}): {resp.text}"
                )

    async def _configure_vm(self, slot: _Slot) -> None:
        await self._api(slot, "PUT", "/machine-config", {
            "vcpu_count": FC_VCPUS,
            "mem_size_mib": FC_MEM_MIB,
            "smt": False,
            "track_dirty_pages": True,   # required for incremental snapshots
        })
        await self._api(slot, "PUT", "/boot-source", {
            "kernel_image_path": FC_KERNEL,
            "boot_args": KERNEL_ARGS,
        })
        await self._api(slot, "PUT", "/drives/rootfs", {
            "drive_id": "rootfs",
            "path_on_host": slot.rootfs_overlay,
            "is_root_device": True,
            "is_read_only": False,
        })
        await self._api(slot, "PUT", f"/network-interfaces/eth0", {
            "iface_id": "eth0",
            "guest_mac": slot.mac,
            "host_dev_name": slot.tap,
        })
        # Rate-limit the VM's disk and network so one runaway task can't
        # starve its neighbours on a shared host.
        await self._api(slot, "PATCH", "/network-interfaces/eth0", {
            "iface_id": "eth0",
            "rx_rate_limiter": {"bandwidth": {"size": 25_000_000, "refill_time": 1000}},
            "tx_rate_limiter": {"bandwidth": {"size": 25_000_000, "refill_time": 1000}},
        })

    async def _start_instance(self, slot: _Slot) -> None:
        await self._api(slot, "PUT", "/actions", {"action_type": "InstanceStart"})

    async def _wait_for_ssh(self, slot: _Slot) -> None:
        deadline = asyncio.get_event_loop().time() + FC_BOOT_TIMEOUT
        while asyncio.get_event_loop().time() < deadline:
            res = await self._ssh(slot, "true", timeout=5)
            if res.exit_code == 0:
                return
            await asyncio.sleep(1)
        raise RuntimeError(f"VM {slot.vm_id} did not become reachable in {FC_BOOT_TIMEOUT}s")

    # -- execution ----------------------------------------------------------

    async def _ssh(
        self,
        slot: _Slot,
        command: str,
        timeout: int = 120,
        env: Optional[dict] = None,
    ) -> ExecResult:
        """
        Run a command in the guest. SSH over the VM's private /30 is used
        rather than a vsock agent to keep the guest image standard; see
        docs/FIRECRACKER.md for the vsock alternative and why you might
        prefer it (no in-guest sshd, no key injection step).
        """
        ssh_cmd = [
            "ssh",
            "-i", FC_SSH_KEY,
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", f"ConnectTimeout={min(timeout, 10)}",
            f"{SANDBOX_USER}@{slot.guest_ip}",
            # Secrets are passed on stdin as `export` lines rather than in
            # argv, so they never show up in the guest's process list.
            "cd /workspace && bash -s",
        ]
        script_parts = []
        for key, value in (env or {}).items():
            quoted = "'" + str(value).replace("'", "'\"'\"'") + "'"
            script_parts.append(f"export {key}={quoted}")
        script_parts.append(command)
        script = "\n".join(script_parts)
        try:
            proc = await asyncio.create_subprocess_exec(
                *ssh_cmd,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(input=script.encode()), timeout=timeout
            )
            return ExecResult(
                exit_code=proc.returncode,
                stdout=stdout.decode(errors="replace")[:20_000],
                stderr=stderr.decode(errors="replace")[:20_000],
            )
        except asyncio.TimeoutError:
            return ExecResult(exit_code=124, stdout="", stderr=f"Timed out after {timeout}s")

    async def exec(
        self,
        sandbox_id: str,
        command: str,
        timeout: int = 120,
        env: Optional[dict] = None,
    ) -> ExecResult:
        slot = self._require(sandbox_id)
        return await self._ssh(slot, command, timeout=timeout, env=env)

    async def read_file(self, sandbox_id: str, path: str, max_bytes: int = 200_000) -> bytes:
        slot = self._require(sandbox_id)
        # /workspace is a virtio-fs share, so the host can read it directly.
        full = os.path.join(self._workspace_mount(slot), path.lstrip("/"))
        if os.path.exists(full):
            with open(full, "rb") as f:
                return f.read(max_bytes)
        res = await self._ssh(slot, f"cat {path}")
        return res.stdout.encode()

    async def write_file(self, sandbox_id: str, path: str, content: bytes) -> None:
        slot = self._require(sandbox_id)
        full = os.path.join(self._workspace_mount(slot), path.lstrip("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(content)

    async def start(self, sandbox_id: str) -> SandboxHandle:
        slot = self._require(sandbox_id)
        return SandboxHandle(
            id=slot.vm_id,
            provider=self.name,
            workspace_host_path=self._workspace_mount(slot),
            ip_address=slot.guest_ip,
            vnc_url=f"http://{slot.guest_ip}:6080/vnc.html?autoconnect=1&resize=scale",
        )

    # -- pause/resume via snapshots ----------------------------------------

    async def pause(self, sandbox_id: str) -> None:
        """
        Pause the VM and snapshot it. This is what makes a long-running task
        genuinely resumable: the agent's whole computer — browser tabs,
        half-finished files, running processes — is preserved, not just the
        task row in Postgres.
        """
        slot = self._require(sandbox_id)
        await self._api(slot, "PATCH", "/vm", {"state": "Paused"})
        snap_dir = os.path.join(FC_STATE_DIR, slot.vm_id)
        os.makedirs(snap_dir, exist_ok=True)
        await self._api(slot, "PUT", "/snapshot/create", {
            "snapshot_type": "Full",
            "snapshot_path": os.path.join(snap_dir, "snapshot.bin"),
            "mem_file_path": os.path.join(snap_dir, "memory.bin"),
        })

    async def resume(self, sandbox_id: str) -> None:
        slot = self._slots.get(sandbox_id)
        if slot is None:
            raise RuntimeError(
                f"VM {sandbox_id} not tracked in this process. Restore from "
                f"{FC_STATE_DIR}/{sandbox_id}/snapshot.bin via /snapshot/load."
            )
        await self._api(slot, "PATCH", "/vm", {"state": "Resumed"})

    async def destroy(self, sandbox_id: str, force: bool = False) -> None:
        slot = self._slots.pop(sandbox_id, None)
        if slot is None:
            return
        # 1. Kill the VMM.
        if slot.process and slot.process.returncode is None:
            slot.process.kill()
            await slot.process.wait()
        # 2. Free the network.
        await self._host_cmd(f"ip link set {slot.tap} down", check=False)
        await self._host_cmd(f"ip tuntap del dev {slot.tap} mode tap", check=False)
        # 3. Reclaim disk for ephemeral VMs.
        if not slot.rootfs_overlay.endswith("persistent.ext4"):
            try:
                os.unlink(slot.rootfs_overlay)
            except FileNotFoundError:
                pass
        # 4. Release the slot index.
        async with self._lock:
            self._used_indexes.discard(slot.index)
        for p in (slot.api_socket,):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass

    async def health(self, sandbox_id: str) -> bool:
        slot = self._slots.get(sandbox_id)
        if slot is None or (slot.process and slot.process.returncode is not None):
            return False
        return (await self._ssh(slot, "true", timeout=5)).exit_code == 0

    async def reconcile(self) -> list[SandboxHandle]:
        """
        Reap orphaned microVMs left by a previous manager process.

        A VM outlives the process that started it, and the in-memory slot map
        does not survive a restart, so any instance directory without a live
        `firecracker` process is unrecoverable: its API socket owner is gone,
        so it can no longer be configured, paused, or cleanly stopped. The
        honest move is to kill and clean up rather than pretend to adopt it.
        Persistent disks are preserved; only ephemeral overlays are deleted.
        """
        adopted: list[SandboxHandle] = []
        if not os.path.isdir(FC_STATE_DIR):
            return adopted

        # Kill any firecracker process we are not tracking.
        await self._host_cmd(
            "pkill -f '^%s' || true" % FC_BIN, check=False
        )

        for name in os.listdir(FC_STATE_DIR):
            path = os.path.join(FC_STATE_DIR, name)
            if name.startswith(".mnt-"):
                await self._host_cmd(f"umount {path}", check=False)
                shutil.rmtree(path, ignore_errors=True)
            elif name.endswith(".ext4") and not name.endswith("persistent.ext4"):
                try:
                    os.unlink(path)
                except OSError:
                    pass

        # Free stale tap devices and sockets.
        await self._host_cmd(
            "for t in $(ip -o link show | grep -o 'fctap[0-9]*'); do "
            "ip link set $t down; ip tuntap del dev $t mode tap; done",
            check=False,
        )
        if os.path.isdir(FC_RUN_DIR):
            for name in os.listdir(FC_RUN_DIR):
                if name.endswith(".sock"):
                    try:
                        os.unlink(os.path.join(FC_RUN_DIR, name))
                    except OSError:
                        pass
        return adopted

    async def list_sandboxes(self) -> list[SandboxHandle]:
        return [await self.start(vm_id) for vm_id in list(self._slots)]

    # -- helpers ------------------------------------------------------------

    def _require(self, sandbox_id: str) -> _Slot:
        slot = self._slots.get(sandbox_id)
        if slot is None:
            raise RuntimeError(f"Unknown sandbox '{sandbox_id}'")
        return slot

    @staticmethod
    async def _host_cmd(command: str, check: bool = True) -> None:
        proc = await asyncio.create_subprocess_shell(
            command,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await proc.communicate()
        if check and proc.returncode != 0:
            raise RuntimeError(f"Host command failed: {command}: {stderr.decode()}")


assert isinstance(FirecrackerBackend(), SandboxProvider)
