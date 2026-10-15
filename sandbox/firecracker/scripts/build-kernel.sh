#!/usr/bin/env bash
# Builds the guest kernel (an uncompressed vmlinux: Firecracker boots that directly, no bzImage, no initrd).
#
#   ./build-kernel.sh            # as your normal user; sudo only to install the result
#
# The source tarball is checked against a pinned SHA-256 before it's unpacked. The build happens in
# $WORK (default ~/.cache/shellhouse-kernel), never in the repo; the result goes to $OUT_DIR/vmlinux.
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail

KVER="${KVER:-6.1.189}"
# From https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc
case "$KVER" in
  6.1.189) KSHA="3ec834a2fefc9a08aac62f993525d7acd10163db6f01d63b4549cbff3f5c9439" ;;
  *) KSHA="${KERNEL_SHA256:?No pinned checksum for $KVER: set KERNEL_SHA256 (from kernel.org sha256sums.asc)}" ;;
esac
OUT_DIR="${OUT_DIR:-/var/lib/agent-vm}"
WORK="${WORK:-$HOME/.cache/shellhouse-kernel}"
FRAGMENT="$(cd "$(dirname "$0")/.." && pwd)/config/guest-kernel.config"
MAJOR="${KVER%%.*}"
TARBALL="linux-${KVER}.tar.xz"
SRC="$WORK/linux-${KVER}"

case "$(uname -m)" in
  x86_64) KARCH=x86_64 ;;
  aarch64) KARCH=arm64 ;;
  *) echo "Unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
for tool in curl make gcc flex bison bc sha256sum; do
  command -v "$tool" >/dev/null || { echo "$tool is missing (setup-host.sh installs the build tools)" >&2; exit 1; }
done

mkdir -p "$WORK"
if [ ! -f "$WORK/$TARBALL.ok" ]; then
  echo "==> Downloading Linux $KVER from cdn.kernel.org"
  curl -fsSL -o "$WORK/$TARBALL" "https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${TARBALL}"
  echo "$KSHA  $WORK/$TARBALL" | sha256sum -c --quiet - \
    || { rm -f "$WORK/$TARBALL"; echo "Checksum mismatch for $TARBALL; nothing was built." >&2; exit 1; }
  rm -rf "$SRC"
  tar -xf "$WORK/$TARBALL" -C "$WORK"
  rm -f "$WORK/$TARBALL"
  touch "$WORK/$TARBALL.ok"
fi

cd "$SRC"
echo "==> Configuring (defconfig + $(basename "$FRAGMENT"))"
make -s ARCH="$KARCH" defconfig
ARCH="$KARCH" ./scripts/kconfig/merge_config.sh -m -O . .config "$FRAGMENT" >/dev/null
make -s ARCH="$KARCH" olddefconfig
missing=0
while IFS= read -r line; do
  case "$line" in
    CONFIG_*=*) grep -qxF "$line" .config || { echo "    not set as asked: $line" >&2; missing=1; } ;;
    "# CONFIG_"*" is not set") sym="${line#\# }"; sym="${sym%% *}"; ! grep -q "^$sym=" .config || { echo "    still set: $sym" >&2; missing=1; } ;;
  esac
done < "$FRAGMENT"
[ "$missing" = 0 ] || { echo "The kernel config doesn't have what the guest needs (above)." >&2; exit 1; }

echo "==> Compiling (a few minutes)"
make -s ARCH="$KARCH" vmlinux -j"$(nproc)"

run_root() { if [ -w "$OUT_DIR" ] || [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
run_root install -d -m 0700 "$OUT_DIR"
run_root install -m 0644 vmlinux "$OUT_DIR/vmlinux"
sha256sum vmlinux | sed "s#  vmlinux#  $OUT_DIR/vmlinux#" | run_root tee "$OUT_DIR/vmlinux.sha256" >/dev/null
echo "$KVER" | run_root tee "$OUT_DIR/vmlinux.version" >/dev/null
echo
echo "Done: $OUT_DIR/vmlinux (Linux $KVER)"
