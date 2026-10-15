#!/usr/bin/env bash
# Runs ON the Linux host, as the SSH user, from host-setup.sh and host-uninstall.sh. Switches the bots' computers
# between Docker containers and Firecracker microVMs (docs/FIRECRACKER.md), and records what it installs in
# ~/.shellhouse-install-state like host-setup.sh does.
#
#   bash ~/shellhouse/scripts/host-firecracker.sh install   # set up (or update) the Firecracker backend and use it
#   bash ~/shellhouse/scripts/host-firecracker.sh disable   # go back to Docker; VM disks and the setup stay
#   bash ~/shellhouse/scripts/host-firecracker.sh remove    # remove everything install added (VM disks too)
#
# Needs sudo (host-setup.sh's askpass wrapper, when it runs this).
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail

REPO="$HOME/shellhouse"
STATE="$HOME/.shellhouse-install-state"
ME="$(id -un)"
FC_SCRIPTS="$REPO/sandbox/firecracker/scripts"
# Copies kept outside ~/shellhouse so uninstall can still remove everything after the repo is gone.
LIB_DIR=/usr/local/lib/shellhouse-firecracker
VM_HOME=/var/lib/agent-vm
COMPOSE_FILES="docker-compose.yml:docker-compose.firecracker.yml"

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nError: %s\n' "$*" >&2; exit 1; }
record() { touch "$STATE"; chmod 600 "$STATE"; grep -qxF "$1" "$STATE" || echo "$1" >> "$STATE"; }
set_env() {
  if grep -q "^$1=" "$REPO/.env"; then sed -i "s|^$1=.*|$1=$2|" "$REPO/.env"; else echo "$1=$2" >> "$REPO/.env"; fi
}
unset_env() { sed -i "/^$1=/d" "$REPO/.env"; }

if docker info >/dev/null 2>&1; then dkr() { docker "$@"; }
elif sg docker -c "docker info" >/dev/null 2>&1; then dkr() { sg docker -c "$(printf '%q ' docker "$@")"; }
else dkr() { sudo docker "$@"; }
fi

# The Docker backend's manager and desktop containers, and every bot container it made. Stopped, not removed: their
# workspace volumes stay, a bot's files are copied into its VM the first time it starts, and `disable` brings
# the containers back.
stop_docker_backend() {
  ( cd "$REPO" && COMPOSE_FILE=docker-compose.yml dkr compose stop sandbox-manager sandbox >/dev/null 2>&1 ) || true
  local ids; ids="$(dkr ps -q --filter label=agent.sandbox=true || true)"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    dkr stop $ids >/dev/null
    ok "Stopped the Docker backend's bot containers (their workspaces are kept)"
  fi
}

case "${1:-}" in
install)
  [ -c /dev/kvm ] || die "This box has no /dev/kvm, so it can't run Firecracker microVMs (docs/FIRECRACKER.md › Host requirements)."
  cd "$REPO"
  mkdir -p "$HOME/.cache"

  step "Firecracker: packages"
  mapfile -t need < <(sudo bash "$FC_SCRIPTS/setup-host.sh" --print-packages)
  if [ "${#need[@]}" -gt 0 ]; then
    if command -v apt-get >/dev/null; then
      sudo apt-get update -qq >/dev/null
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" >/dev/null
    else
      sudo dnf install -y -q "${need[@]}" >/dev/null
    fi
    for p in "${need[@]}"; do record "PACKAGE=$p"; done
    ok "Installed ${need[*]}"
  else
    ok "Everything needed is installed"
  fi

  step "Firecracker: host setup (binaries, VM user, network policy)"
  record "FIRECRACKER=1"
  sudo bash "$FC_SCRIPTS/setup-host.sh" | sed 's/^/    /'
  sudo install -m 0755 "$FC_SCRIPTS/setup-host.sh" "$FC_SCRIPTS/install-manager.sh" "$REPO/scripts/host-firecracker.sh" "$LIB_DIR/"
  ok "Host prepared"

  step "Firecracker: guest kernel"
  want="$(sed -n 's/^KVER="${KVER:-\(.*\)}"$/\1/p' "$FC_SCRIPTS/build-kernel.sh")"
  if [ "$(sudo cat "$VM_HOME/vmlinux.version" 2>/dev/null)" = "$want" ]; then
    ok "Linux $want is already built"
  else
    note "Building Linux $want (a few minutes)…"
    bash "$FC_SCRIPTS/build-kernel.sh" > "$HOME/.cache/shellhouse-kernel-build.log" 2>&1 \
      || die "The kernel build failed; see ~/.cache/shellhouse-kernel-build.log"
    ok "Built Linux $want"
  fi

  step "Firecracker: guest disk image (the same desktop as the Docker backend)"
  sudo bash "$FC_SCRIPTS/build-rootfs.sh" > "$HOME/.cache/shellhouse-rootfs-build.log" 2>&1 \
    || die "Building the guest disk image failed; see ~/.cache/shellhouse-rootfs-build.log"
  ok "Built $VM_HOME/rootfs.ext4"

  step "Firecracker: switching the bots to microVMs"
  set_env SANDBOX_BACKEND firecracker
  set_env COMPOSE_FILE "$COMPOSE_FILES"
  stop_docker_backend
  sudo bash "$FC_SCRIPTS/install-manager.sh" --user "$ME" | sed 's/^/    /'
  record "FIRECRACKER_MANAGER=1"
  ok "The sandbox manager runs as the host service agent-sandbox-manager"
  ;;

disable)
  [ -f "$REPO/.env" ] || exit 0
  grep -q '^SANDBOX_BACKEND=firecracker' "$REPO/.env" || exit 0
  step "Switching the bots back to Docker containers"
  sudo systemctl disable --now agent-sandbox-manager.service >/dev/null 2>&1 || true
  set_env SANDBOX_BACKEND docker
  unset_env COMPOSE_FILE
  ok "The Firecracker manager is stopped (VM disks are kept; --with-firecracker switches back)"
  ;;

remove)
  # Uses the copies in $LIB_DIR when ~/shellhouse is already gone.
  dir="$FC_SCRIPTS"; [ -f "$dir/install-manager.sh" ] || dir="$LIB_DIR"
  [ -f "$dir/install-manager.sh" ] || dir="$(cd "$(dirname "$0")/.." && pwd)/sandbox/firecracker/scripts"
  if [ -f "$dir/install-manager.sh" ]; then
    sudo bash "$dir/install-manager.sh" --remove
    sudo bash "$dir/setup-host.sh" --remove
  fi
  for image in agent-desktop:vm agent-desktop:vm-base; do dkr image rm -f "$image" >/dev/null 2>&1 || true; done
  rm -rf "$HOME/.cache/shellhouse-kernel" "$HOME/.cache/shellhouse-kernel-build.log" "$HOME/.cache/shellhouse-rootfs-build.log"
  ok "Removed the Firecracker backend (service, VMs and their disks, binaries, network policy, guest images)"
  ;;

*) echo "usage: $0 install|disable|remove" >&2; exit 2 ;;
esac
