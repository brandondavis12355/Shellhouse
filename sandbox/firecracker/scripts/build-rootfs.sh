#!/usr/bin/env bash
# Builds the Firecracker guest's disk image (ext4) from the SAME desktop image the Docker backend runs, so a bot's
# computer looks and behaves the same whichever backend is in use.
#
#   sudo ./build-rootfs.sh [size_mb]
#
# Output: /var/lib/agent-vm/rootfs.ext4 (the immutable base; each VM boots from its own copy). The image is built
# with `mkfs.ext4 -d` from the exported container filesystem, so nothing is loop-mounted.
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail

SIZE_MB="${1:-${ROOTFS_SIZE_MB:-8192}}"
OUT_DIR="${OUT_DIR:-/var/lib/agent-vm}"
ROOTFS="$OUT_DIR/rootfs.ext4"
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
KEY="$OUT_DIR/id_ed25519"

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo): it reads the exported image as root to keep file ownership." >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is required to build the image" >&2; exit 1; }
command -v mkfs.ext4 >/dev/null || { echo "mkfs.ext4 (e2fsprogs) is required" >&2; exit 1; }
[[ -d "$REPO/box" && -d "$REPO/workspace" ]] || { echo "Run scripts/host-setup.sh first (it creates the box/ and workspace/ seeds in $REPO)." >&2; exit 1; }

install -d -m 0700 "$OUT_DIR"
if [[ ! -f "$KEY" ]]; then
  ssh-keygen -q -t ed25519 -N "" -f "$KEY" -C "shellhouse-sandbox-manager"
fi

# The repo root is the build context, as in docker-compose.yml: sandbox/Dockerfile copies box/, workspace/ and sandbox/.
echo "==> Building the desktop image"
docker build -f "$REPO/sandbox/Dockerfile" -t agent-desktop:vm-base "$REPO"
echo "==> Adding init and sshd for the VM"
docker build -f "$REPO/sandbox/firecracker/Dockerfile.vm" --build-arg BASE=agent-desktop:vm-base -t agent-desktop:vm "$REPO"

WORK="$(mktemp -d /var/tmp/agent-rootfs.XXXXXX)"
CID=""
cleanup() { [[ -n "$CID" ]] && docker rm -f "$CID" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

echo "==> Exporting the image's filesystem"
mkdir "$WORK/root"
CID="$(docker create agent-desktop:vm)"
docker export "$CID" | tar -x -C "$WORK/root" --numeric-owner
docker rm -f "$CID" >/dev/null; CID=""

# What a container gets from Docker at run time and a VM has to have on its disk.
R="$WORK/root"
rm -f "$R/.dockerenv"
printf '127.0.0.1\tlocalhost\n::1\tlocalhost\n' > "$R/etc/hosts"
: > "$R/etc/hostname"
# The manager's key may sign in as `box`; the private half never leaves the host.
owner="$(awk -F: '$1=="box"{print $3":"$4}' "$R/etc/passwd")"
[[ -n "$owner" ]] || { echo "The image has no box user" >&2; exit 1; }
install -d -m 0700 -o "${owner%%:*}" -g "${owner##*:}" "$R/home/box/.ssh"
install -m 0600 -o "${owner%%:*}" -g "${owner##*:}" "$KEY.pub" "$R/home/box/.ssh/authorized_keys"

echo "==> Writing a ${SIZE_MB} MB ext4 image"
rm -f "$ROOTFS.new"
truncate -s "${SIZE_MB}M" "$ROOTFS.new"
mkfs.ext4 -q -F -L agent-root -d "$R" "$ROOTFS.new"
chmod 0600 "$ROOTFS.new"
mv -f "$ROOTFS.new" "$ROOTFS"
sha256sum "$ROOTFS" > "$ROOTFS.sha256"

echo
echo "Done: $ROOTFS ($(cut -c1-12 "$ROOTFS.sha256"))"
