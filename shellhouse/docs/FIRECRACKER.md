# Firecracker integration plan

This is Phase 7 of the roadmap (ADR-002). The code to support it is already in
the repo — `SANDBOX_BACKEND=firecracker` switches the whole execution
substrate — but turning it on is an infrastructure project, not just a config flag.
This document is the plan for doing it properly.

## Why bother, concretely

The Docker sandbox shares a kernel with the host and currently runs with
`seccomp:unconfined` because Chromium needs syscalls the default profile
blocks. That means the security story for the Docker provider is roughly: *a
browser exploit plus a container escape reaches the host.* For a single-user
laptop deployment that's an acceptable risk you're taking knowingly. The
moment a second person can submit a task, it isn't.

Firecracker changes the shape of that risk: each agent gets its own kernel,
the VMM is a small Rust process running jailed under seccomp as an
unprivileged uid, and the device model is deliberately tiny. An escape has to
get through the guest kernel *and* the VMM *and* the jailer.

What Firecracker does **not** do is make a bad architecture safe. Its own
production guidance is explicit that security depends on host configuration,
image handling, networking, and lifecycle management. The scripts in
`sandbox/firecracker/scripts/` exist so those aren't left as an exercise.

## What's already implemented

| Piece | Location | State |
|---|---|---|
| Provider interface | `api/agent/sandbox/base.py` (API) / `sandbox-manager/app/providers/base.py` (manager) | Done — `create/start/exec/read_file/write_file/pause/resume/destroy/health` |
| Docker backend | `sandbox-manager/app/providers/docker_backend.py` | Done, default |
| Firecracker backend | `sandbox-manager/app/providers/firecracker_backend.py` | Implemented: slot allocation, tap + /30 per VM, CoW rootfs, identity injection, jailer launch, API-socket config, boot wait, SSH exec, snapshot pause/resume, full teardown |
| Backend selection | `sandbox-manager/app/providers/factory.py` | `SANDBOX_BACKEND=docker\|firecracker`, set on the manager |
| Tools on the abstraction | `api/agent/tools.py` | Done — no tool references Docker, and the API cannot reach it |
| Guest kernel build | `sandbox/firecracker/scripts/build-kernel.sh` | Done |
| Guest rootfs build | `sandbox/firecracker/scripts/build-rootfs.sh` | Done — reuses the same desktop image, adds init + sshd + systemd units |
| Host prep + network policy | `sandbox/firecracker/scripts/setup-host.sh` | Done — KVM check, jailer user, bridge, NAT, nftables drops |

Per-VM resources come from env: `FIRECRACKER_VCPUS`, `FIRECRACKER_MEM_MIB`,
plus disk and network rate limiters set through the API.

## Host requirements

- Bare metal, or a cloud instance type with nested virtualization. `/dev/kvm`
  must exist — this is the single most common blocker, and a standard cloud VM
  usually can't do it.
- Linux 5.10+, `nftables`, `iproute2`.
- Filesystem with reflink support (btrfs/XFS) if you want instant CoW rootfs
  clones; ext4 falls back to a full sparse copy, which is slower per VM start.
- Enough RAM for `vcpus × mem_mib × concurrent_tasks`. A 2GB VM per task means
  a 64GB host tops out around 24–28 concurrent agents with headroom.

## Rollout, in order

**Stage 1 — Prove one VM boots.** Run the three scripts, boot a VM by hand
with `config/vm-template.json`, SSH in, confirm the desktop and noVNC are up
inside the guest. Don't involve the agent yet.

**Stage 2 — Run the backend in shadow mode.** Set
`SANDBOX_BACKEND=firecracker` on a second manager instance and run the existing
task suite against both providers. Every tool must behave identically; the
provider interface is the contract being tested. Watch for the things that
differ in practice: VM boot latency added to first tool call, virtio-fs
permissions on `/workspace`, and SSH connection churn.

**Stage 3 — Verify the isolation claims.** Do not skip this. From inside a VM:

```
curl -m 3 http://169.254.169.254/        # metadata: must fail
curl -m 3 http://172.30.0.6:6080/        # another VM: must fail
curl -m 3 http://172.30.255.254:8000/    # the host's API: must fail
```

On the host: `ps aux | grep firecracker` must show uid 1234, not root.

**Stage 4 — Ephemeral by default, persistent opt-in.** Wire `create(persistent=)`
to the task type: research and one-off work gets a fresh VM destroyed at the
end; "My AI Computer" keeps its overlay. This is where the `pause()` snapshot
path earns its keep — a paused VM preserves browser tabs and running
processes, which is what actually makes a multi-hour task resumable.

**Stage 5 — Pool and pre-warm.** Cold VM boot is the user-visible cost. Keep N
VMs booted and idle, hand one to an incoming task, and backfill. Firecracker's
snapshot-restore makes a "restore from a post-boot snapshot" pool viable and
is much faster than a cold boot.

## Operational runbook

**Reaping leaked VMs — implemented.** `FirecrackerBackend.reconcile()` runs at
manager startup: it kills untracked `firecracker` processes, unmounts stale
loop mounts, deletes ephemeral overlays (preserving `*persistent.ext4`), and
frees orphaned tap devices and API sockets.

It deliberately does *not* try to adopt a running VM whose VMM process is
gone. Without the API socket owner there is no way to configure, pause, or
cleanly stop that instance, so claiming to adopt it would be a lie — it gets
reaped instead, and `resume()` raises a clear error for anything untracked.

**Image versioning.** `build-rootfs.sh` writes `rootfs.ext4.sha256`. Record
which image hash each task booted in `task_events`, so "the agent behaved
differently last week" is answerable. Sign the images before you have more
than one host pulling them.

**Host patching.** The host kernel is part of the security boundary now.
Patching it means draining and rebooting a Firecracker host, so plan for VM
migration or task drain windows before you need them.

## Open decisions worth making deliberately

**SSH vs vsock for exec.** The provider currently runs commands over SSH on
the VM's private /30. It's simple, debuggable by hand, and uses a standard
guest image — but it means running sshd in every guest and injecting a key at
create time. The alternative is a small guest agent on vsock (`CONFIG_VSOCKETS`
is already enabled in the kernel config, and the template reserves a CID):
no sshd, no keys, no guest networking needed for exec at all, and the guest
can then run with networking fully disabled for tasks that don't need it.
That's the better end state; SSH is the faster path to Stage 1.

**Egress: denylist vs allowlist.** `setup-host.sh` ships a denylist — metadata
endpoints, VM-to-VM, RFC1918 and loopback are dropped, the public internet is
allowed. That's usable for research tasks. For anything handling real data,
flip the forward chain to `policy drop` and add explicit accepts; the comment
in the config marks the spot.

**Where the API runs — resolved.** The Sandbox Manager split is done: the API
holds no host privilege and reaches sandboxes only through
`sandbox-manager`'s unix socket (`docs/SECURITY.md`). The Firecracker backend
lives inside that service, so enabling it does not widen the API's privileges
at all.

One thing to get right when you turn it on: the Firecracker backend needs
`/dev/kvm`, loop mounts, and tap creation. Granting those to the *manager
container* would make it roughly host-root and undo much of the benefit. Run
it as a host systemd unit instead —
`sandbox-manager/systemd/agent-sandbox-manager.service` ships with the
capability set narrowed to `CAP_NET_ADMIN` + `CAP_SYS_ADMIN`,
`ProtectSystem=strict`, an explicit `ReadWritePaths` allowlist, and
`DeviceAllow` limited to `/dev/kvm` and `/dev/net/tun`.
