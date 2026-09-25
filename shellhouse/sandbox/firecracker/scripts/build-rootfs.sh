#!/usr/bin/env bash
# Build the Firecracker guest rootfs (ext4) from the SAME desktop image used
# by the Docker provider, so the agent's computer looks and behaves identically
# whichever sandbox backend is active.
#
#   sudo ./build-rootfs.sh [size_mb]
#
# Output: /var/lib/agent-vm/rootfs.ext4  (immutable base; VMs get CoW copies)
set -euo pipefail

SIZE_MB="${1:-6144}"
OUT_DIR="${OUT_DIR:-/var/lib/agent-vm}"
ROOTFS="$OUT_DIR/rootfs.ext4"
MNT="$(mktemp -d)"
IMAGE_TAG="agent-desktop:vm"
SANDBOX_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

command -v docker >/dev/null || { echo "docker is required to export the rootfs"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "must run as root (mount/losetup)"; exit 1; }

mkdir -p "$OUT_DIR"

echo "==> Building the desktop image"
docker build -t "$IMAGE_TAG" "$SANDBOX_DIR"

echo "==> Creating ${SIZE_MB}MB ext4 image"
rm -f "$ROOTFS"
truncate -s "${SIZE_MB}M" "$ROOTFS"
mkfs.ext4 -q -F "$ROOTFS"
mount -o loop "$ROOTFS" "$MNT"

cleanup() { umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> Exporting the container filesystem into the image"
CID="$(docker create "$IMAGE_TAG")"
docker export "$CID" | tar -x -C "$MNT"
docker rm -f "$CID" >/dev/null

echo "==> Installing guest-only pieces (init, sshd, agent network unit)"
# A container image has no init or sshd; a VM needs both.
chroot "$MNT" /bin/bash -eux <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    systemd systemd-sysv udev dbus \
    openssh-server iproute2 iputils-ping
# sshd is how the host runs commands in the guest. Key-only, no passwords,
# no root login — the ephemeral key is injected per-VM at create() time.
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
systemctl enable ssh systemd-networkd
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT

echo "==> Installing the desktop as a systemd service"
cat > "$MNT/etc/systemd/system/agent-desktop.service" <<'UNIT'
[Unit]
Description=Agent desktop (Xvfb + openbox + noVNC)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/supervisord -n -c /etc/agent-desktop/supervisord.conf
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
chroot "$MNT" systemctl enable agent-desktop

# /workspace is a virtio-fs share from the host, mounted at boot.
mkdir -p "$MNT/workspace"
cat > "$MNT/etc/systemd/system/workspace.mount" <<'UNIT'
[Unit]
Description=Agent workspace (virtio-fs share from host)
Before=agent-desktop.service

[Mount]
What=workspace
Where=/workspace
Type=virtiofs
Options=rw,nofail

[Install]
WantedBy=multi-user.target
UNIT
chroot "$MNT" systemctl enable workspace.mount

echo "==> Generating the host SSH keypair (if missing)"
if [[ ! -f "$OUT_DIR/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$OUT_DIR/id_ed25519" -C "agent-sandbox-host"
  chmod 600 "$OUT_DIR/id_ed25519"
fi

# Record a checksum so you can verify which image a VM booted (image
# signing/versioning is on the production readiness checklist).
sync
sha256sum "$ROOTFS" > "$ROOTFS.sha256"

echo
echo "Done."
echo "  rootfs:   $ROOTFS"
echo "  checksum: $ROOTFS.sha256"
echo "  ssh key:  $OUT_DIR/id_ed25519"
echo
echo "Next: ./build-kernel.sh  then  ./setup-host.sh"
