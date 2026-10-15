# Firecracker microVM backend

`SANDBOX_BACKEND=firecracker` runs each bot's computer as its own Firecracker microVM instead of a Docker
container. Turn it on with:

```bash
./initial_setup.sh --with-firecracker      # from the Mac; later runs keep it, --no-firecracker switches back
```

or, on the host itself, `bash ~/shellhouse/scripts/host-setup.sh --with-firecracker`. Everything it installs is
recorded in `~/.shellhouse-install-state` and removed by `./uninstall.sh`.

## Why

The Docker sandbox shares the host's kernel and runs with `seccomp:unconfined` because Chromium needs syscalls the
default profile blocks: a browser exploit plus a container escape reaches the host. Under Firecracker each bot has
its own kernel, and the VMM is a small process running jailed (chroot, own mount namespace, seccomp, an
unprivileged uid). An escape has to get through the guest kernel, the VMM and the jailer.

Firecracker doesn't make the rest of the host configuration safe by itself; the pieces below are what this repo
sets up around it.

## What `--with-firecracker` does

`scripts/host-firecracker.sh install`, run by `host-setup.sh`:

| Step | Script | Result |
|---|---|---|
| Packages | `setup-host.sh --print-packages` | curl, tar, e2fsprogs, openssh-client, nftables, iproute2, python3 + venv, the kernel build tools. Recorded, so uninstall removes the ones it added. |
| Host | `sandbox/firecracker/scripts/setup-host.sh` | Checks `/dev/kvm`. Installs firecracker + jailer **v1.10.1** from github.com/firecracker-microvm/firecracker, checked against a pinned SHA-256. Creates the `shellhouse-fc` system user the VMs run as, `/var/lib/agent-vm`, the manager's SSH key, and the network policy (below) as `shellhouse-vm-net.service`. |
| Kernel | `build-kernel.sh` | Linux **6.1.189** from cdn.kernel.org, checked against a pinned SHA-256, configured as `defconfig` + `config/guest-kernel.config` (verified after merging), built as the normal user in `~/.cache/shellhouse-kernel`. Output `/var/lib/agent-vm/vmlinux`. |
| Disk image | `build-rootfs.sh` | Builds `sandbox/Dockerfile` (repo root as context, like compose) and `sandbox/firecracker/Dockerfile.vm` (adds systemd, sshd, the guest units), exports it and writes `/var/lib/agent-vm/rootfs.ext4` with `mkfs.ext4 -d`: nothing is loop-mounted. |
| Manager | `install-manager.sh` | `/opt/agent-sandbox-manager` (code + its own venv; packages from PyPI, pinned), `/etc/agent-sandbox-manager.env` (root only, values checked, token from `~/shellhouse/.env`), the `agent-sandbox-manager` systemd unit. |
| Stack | | `.env`: `SANDBOX_BACKEND=firecracker`, `COMPOSE_FILE=docker-compose.yml:docker-compose.firecracker.yml`, which keeps compose from starting the containerized manager or the shared desktop. The Docker backend's bot containers are stopped (not removed). |

## How it fits together

- **The manager is a host service.** The jailer must start as root: it builds each VM's chroot and device nodes,
  then switches to `shellhouse-fc`, and that switch drops every capability only because it starts from uid 0. So the
  unit runs as root, confined by systemd: a capability bounding set, `ProtectSystem=strict` with only
  `/var/lib/agent-vm` writable, `ProtectHome=tmpfs` with only the socket folder bound in, a device allowlist
  (`/dev/kvm`, `/dev/net/tun`), and restricted address families and namespaces.
- **One socket, same place as before.** The manager listens on `~/shellhouse/sandbox-manager-run/manager.sock`,
  the path the Mac app's SSH tunnel uses. The folder belongs to the SSH user with mode 0700, so that user (and
  root) can reach the socket and nobody else can. The app's restricted key (`authorize_app_key`) is unchanged.
- **Files go through the guest.** Firecracker has no virtio-fs, so nothing is shared with the host: `exec`,
  `read_file` and `write_file` all run over SSH as `box` (one persistent SSH connection per VM), with paths
  relative to `/workspace` as in the Docker backend. `/workspace` lives on the VM's own disk.
- **The VM's settings ride on the kernel command line** (IP, hostname, VNC password, sudo on/off), read by
  `shellhouse-guest-init` in the guest. The host never mounts a disk the guest has written to, and each VM makes its
  own SSH host keys at boot.
- **noVNC keeps its address.** The manager forwards `127.0.0.1:6100-6131` to each guest's port 6080, the same
  ports the Docker backend publishes, so the app's tunnel works unchanged.
- **Jail layout.** Each VM's jail is `/var/lib/agent-vm/jail/firecracker/<id>/root`, holding hard links to the
  kernel and the VM's disk (same filesystem) and the API socket at `/run/api.sock`. Firecracker is given those
  chroot-relative paths.
- **Persistent VMs** ("this bot's computer") keep their disk, `instances/fc-<bot>.persistent.ext4`. Stopping
  the manager stops its VMs; afterwards they are listed as stopped under the same id and boot again on first use.
  A bot that ran under the Docker backend gets its old workspace volume copied into `/workspace` the first time its
  VM disk is created. Ephemeral VMs are deleted on `destroy`.

## Network policy

Each VM has its own routed tap (`fctapN`, a /30 out of `172.30.0.0/16`, host `.1`, guest `.2`); there is no shared
bridge, so VM-to-VM traffic has to cross the host's forward chain. `shellhouse-vm-net.service` loads one nftables table,
`inet agentvm` (replaced whole on each load; nothing else in the ruleset is touched, no `flush ruleset`), on every
boot:

- forward: from a VM, drop RFC 1918, link-local/metadata (`169.254.0.0/16`), loopback, CGNAT, multicast and
  reserved ranges, and all IPv6; to a VM, only established/related traffic.
- input: a VM may not open connections to the host on any address.
- NAT: masquerade VM traffic leaving the host.

Docker's own `FORWARD` chain drops unknown traffic, so the same script adds two `DOCKER-USER` rules for `fctap+`,
and a `docker.service` drop-in re-adds them whenever Docker restarts. If `ufw` is active with a DROP forward policy
the VMs have no internet until you allow it (`setup-host.sh` warns).

The guest's DNS server is `FIRECRACKER_DNS` (default `1.1.1.1`); a resolver on a private address is unreachable by
design.

## Verify it

From inside a VM (exec through the app or the manager):

```
curl -m 3 http://169.254.169.254/        # metadata: must fail
curl -m 3 http://172.30.0.6:6080/        # another VM: must fail
curl -m 3 http://172.30.0.1:22/          # the host: must fail
curl -m 3 https://example.com/           # internet: works
```

On the host: `ps -o user,cmd -C firecracker` shows `shellhouse-fc`, never root.

To boot one VM by hand while debugging, [`sandbox/firecracker/config/vm-template.json`](../sandbox/firecracker/config/vm-template.json) is a reference shape (its header comment has the commands); keep it in step with `firecracker_backend.py`.

## Settings (`~/shellhouse/.env`, applied by re-running setup)

`FIRECRACKER_VCPUS` (2), `FIRECRACKER_MEM_MIB` (2048), `FIRECRACKER_BOOT_TIMEOUT` (90), `FIRECRACKER_USE_JAILER`
(true; false only for debugging), `FIRECRACKER_DNS` (1.1.1.1), `FIRECRACKER_IMPORT_DOCKER_WORKSPACES` (1),
`SANDBOX_ALLOW_SUDO`, `SANDBOX_PORT_BASE`/`SANDBOX_PORT_COUNT`. A 2 GB VM per bot means RAM, not CPU, is usually the
limit.

## Host requirements

- `/dev/kvm`: bare metal, or a cloud instance type with nested virtualization. A standard cloud VM usually can't.
- x86_64 or aarch64, Debian/Ubuntu or Fedora, systemd, Docker (to build the guest image).
- Disk: the base image is 8 GB (sparse); each VM's disk starts as a sparse copy of it. btrfs/XFS make the copy
  instant (reflink); ext4 copies the used blocks, a few seconds per new VM.

## Not done

- **Pause** freezes the vCPUs only; there is no snapshot/restore yet, so a VM doesn't survive a manager restart
  with its running processes (its disk does).
- **Egress allowlist** (`docs/EGRESS.md`) is Docker-only; VMs get the denylist above.
- **vsock exec** instead of SSH (no sshd in the guest, networking optional) is the better end state; the kernel
  already has `CONFIG_VIRTIO_VSOCKETS`.
- **Pre-warmed pools** to hide cold boot time.
- **Image signing**: `rootfs.ext4.sha256` and `vmlinux.sha256` record what was built, nothing verifies them yet.
- The unit has no `SystemCallFilter=`; the jailer's and Firecracker's own seccomp filters apply to the VMM.
