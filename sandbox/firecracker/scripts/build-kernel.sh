#!/usr/bin/env bash
# Build a minimal guest kernel (uncompressed vmlinux) for Firecracker.
# Firecracker boots vmlinux directly — not bzImage, not an initrd by default.
#
#   ./build-kernel.sh [version]
#
# Output: /var/lib/agent-vm/vmlinux
set -euo pipefail

KVER="${1:-6.1.102}"
OUT_DIR="${OUT_DIR:-/var/lib/agent-vm}"
WORK="${WORK:-/tmp/agent-kernel}"
CONFIG_SRC="$(cd "$(dirname "$0")/.." && pwd)/config/guest-kernel.config"

mkdir -p "$OUT_DIR" "$WORK"
cd "$WORK"

MAJOR="${KVER%%.*}"
TARBALL="linux-${KVER}.tar.xz"

if [[ ! -d "linux-${KVER}" ]]; then
  echo "==> Fetching kernel ${KVER}"
  curl -fsSLO "https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${TARBALL}"
  tar xf "$TARBALL"
fi

cd "linux-${KVER}"

if [[ -f "$CONFIG_SRC" ]]; then
  echo "==> Using pinned guest config"
  cp "$CONFIG_SRC" .config
  make olddefconfig
else
  echo "==> No pinned config found, starting from the in-tree microvm defaults"
  make defconfig
  # Essentials for a Firecracker guest with virtio disk, net, and fs.
  ./scripts/config --enable VIRTIO --enable VIRTIO_PCI --enable VIRTIO_MMIO \
                   --enable VIRTIO_BLK --enable VIRTIO_NET --enable VIRTIO_FS \
                   --enable VIRTIO_CONSOLE --enable VIRTIO_BALLOON \
                   --enable FUSE_FS --enable EXT4_FS --enable SERIAL_8250_CONSOLE \
                   --enable KEYBOARD_ATKBD --enable VSOCKETS --enable VIRTIO_VSOCKETS \
                   --disable MODULES
  make olddefconfig
fi

echo "==> Compiling (this takes a while)"
make vmlinux -j"$(nproc)"

cp vmlinux "$OUT_DIR/vmlinux"
sha256sum "$OUT_DIR/vmlinux" > "$OUT_DIR/vmlinux.sha256"

# Save the working config so future builds are reproducible.
mkdir -p "$(dirname "$CONFIG_SRC")"
cp .config "$CONFIG_SRC"

echo
echo "Done: $OUT_DIR/vmlinux"
