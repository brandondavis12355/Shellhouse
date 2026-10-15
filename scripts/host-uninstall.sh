#!/usr/bin/env bash
# Runs ON the Linux host (uninstall.sh copies it to /tmp and runs it). Removes everything Shellhouse put there:
# every container, volume, network and image the stack or the sandbox manager created, ~/shellhouse, the app's
# SSH key in ~/.ssh/authorized_keys, and the sshd drop-ins. Then reverts what host-setup.sh recorded in
# ~/.shellhouse-install-state: packages it installed, the docker group membership, the docker service, and the
# Firecracker backend (--with-firecracker: its host service, VMs, binaries and network policy).
# Anything that was already on the host before setup (Docker, for one) stays.
#
#   bash /tmp/shellhouse-host-uninstall.sh [--keep-packages] [--yes]
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail

KEEP_PACKAGES=0; ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --keep-packages) KEEP_PACKAGES=1 ;;
    --yes) ASSUME_YES=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

REPO="$HOME/shellhouse"
STATE="$HOME/.shellhouse-install-state"
ME="$(id -un)"
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
recorded() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE"; }

[ "$(id -u)" != "0" ] || { echo "Run this as the user Shellhouse was set up for, not root." >&2; exit 1; }

step "Checking sudo"
sudo -v

if [ -n "$(recorded FIRECRACKER)" ]; then
  step "Removing the Firecracker backend"
  # Its own copy outside ~/shellhouse is used if the repo is already gone.
  helper="$REPO/scripts/host-firecracker.sh"
  [ -f "$helper" ] || helper=/usr/local/lib/shellhouse-firecracker/host-firecracker.sh
  if [ -f "$helper" ]; then bash "$helper" remove; else note "Its scripts are gone; nothing removed."; fi
fi

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then D=(docker); else D=(sudo docker); fi

  step "Removing the stack's containers, volumes and images"
  if [ -f "$REPO/docker-compose.yml" ]; then
    ( cd "$REPO" && "${D[@]}" compose --profile relay --profile egress down --volumes --rmi local --remove-orphans >/dev/null 2>&1 ) || true
  fi
  # What the sandbox manager created on its own (per-bot VMs and their volumes and networks), by its label.
  mapfile -t containers < <("${D[@]}" ps -aq --filter label=agent.sandbox=true)
  [ "${#containers[@]}" -gt 0 ] && "${D[@]}" rm -f "${containers[@]}" >/dev/null
  mapfile -t volumes < <("${D[@]}" volume ls -q --filter label=agent.sandbox=true)
  [ "${#volumes[@]}" -gt 0 ] && "${D[@]}" volume rm -f "${volumes[@]}" >/dev/null
  mapfile -t networks < <("${D[@]}" network ls -q --filter label=agent.sandbox=true)
  [ "${#networks[@]}" -gt 0 ] && "${D[@]}" network rm "${networks[@]}" >/dev/null 2>&1 || true
  # Anything else of the compose project's (label set by Docker Compose), and the images it built.
  mapfile -t leftovers < <("${D[@]}" ps -aq --filter label=com.docker.compose.project=shellhouse)
  [ "${#leftovers[@]}" -gt 0 ] && "${D[@]}" rm -f "${leftovers[@]}" >/dev/null
  mapfile -t projvols < <("${D[@]}" volume ls -q --filter label=com.docker.compose.project=shellhouse)
  [ "${#projvols[@]}" -gt 0 ] && "${D[@]}" volume rm -f "${projvols[@]}" >/dev/null
  for image in agent-desktop:local $("${D[@]}" images --format '{{.Repository}}:{{.Tag}}' | grep -E '^shellhouse[-_]' || true); do
    "${D[@]}" image rm -f "$image" >/dev/null 2>&1 || true
  done
  "${D[@]}" builder prune -af --filter label=com.docker.compose.project=shellhouse >/dev/null 2>&1 || true
  ok "Docker objects removed (count left with Shellhouse's label: $("${D[@]}" ps -aq --filter label=agent.sandbox=true | wc -l | tr -d ' '))"
else
  note "Docker isn't installed; nothing to remove there."
fi

step "Removing ~/shellhouse"
if [ -d "$REPO" ]; then
  # The socket folder and seed copies can be owned by container users: sudo for those.
  rm -rf "$REPO" 2>/dev/null || sudo rm -rf "$REPO"
  ok "Removed"
else
  note "Not there"
fi

step "Removing the app's SSH key"
if [ -f "$HOME/.ssh/authorized_keys" ] && grep -q ' shellhouse-app$' "$HOME/.ssh/authorized_keys"; then
  tmp="$(mktemp)"; grep -v ' shellhouse-app$' "$HOME/.ssh/authorized_keys" > "$tmp" || true
  cat "$tmp" > "$HOME/.ssh/authorized_keys"; rm -f "$tmp"
  ok "Removed from ~/.ssh/authorized_keys"
else
  note "Not authorized; nothing to remove"
fi

step "Removing sshd changes"
reload=0
for dropin in /etc/ssh/sshd_config.d/48-shellhouse-auth.conf /etc/ssh/sshd_config.d/49-shellhouse.conf /etc/ssh/sshd_config.d/50-shellhouse-model-proxy.conf $(recorded SSHD_DROPIN); do
  if [ -f "$dropin" ]; then sudo rm -f "$dropin"; ok "Removed $dropin"; reload=1; fi
done
if [ "$reload" = "1" ]; then
  sudo sshd -t && { sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd; } && ok "sshd reloaded"
else
  note "None"
fi

step "Reverting what setup installed"
if [ -n "$(recorded ADDED_TO_DOCKER_GROUP)" ]; then
  sudo gpasswd -d "$ME" docker >/dev/null 2>&1 && ok "Removed $ME from the docker group" || true
fi
packages="$(recorded PACKAGE | tr '\n' ' ')"
if [ -n "${packages// /}" ] && [ "$KEEP_PACKAGES" = "0" ]; then
  if [ -n "$(recorded ENABLED_DOCKER_SERVICE)" ]; then sudo systemctl disable --now docker docker.socket >/dev/null 2>&1 || true; fi
  if command -v apt-get >/dev/null; then
    # shellcheck disable=SC2086
    sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq $packages >/dev/null 2>&1 || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq >/dev/null 2>&1 || true
  else
    # shellcheck disable=SC2086
    sudo dnf remove -y -q $packages >/dev/null 2>&1 || true
  fi
  ok "Removed packages setup installed: $packages"
  if [[ " $packages " == *" docker.io "* || " $packages " == *" moby-engine "* ]]; then
    # Docker's own data, only when setup was what installed Docker.
    sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker
    ok "Removed Docker's data directories (Docker was installed by setup)"
  fi
elif [ "$KEEP_PACKAGES" = "1" ]; then
  note "Kept packages (--keep-packages): $packages"
else
  note "Setup didn't install any packages"
fi

rm -f "$STATE"
step "The host is back to how it was before Shellhouse"
rm -f "$0" 2>/dev/null || true
