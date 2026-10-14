#!/usr/bin/env bash
# Runs ON the Linux host, as the SSH user (initial_setup.sh copies the repo to ~/shellhouse and runs this there).
# Installs what the stack needs, starts the sandbox manager, and records everything it changed in
# ~/.shellhouse-install-state so uninstall.sh can put it all back.
#
#   bash ~/shellhouse/scripts/host-setup.sh [--with-smolagents] [--no-sudo-in-sandboxes] [--yes]
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail

WITH_SMOLAGENTS=0
ALLOW_SUDO=1
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --with-smolagents) WITH_SMOLAGENTS=1 ;;
    --no-sudo-in-sandboxes) ALLOW_SUDO=0 ;;
    --yes) ASSUME_YES=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

REPO="$HOME/shellhouse"
STATE="$HOME/.shellhouse-install-state"
ME="$(id -un)"
cd "$REPO"

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nError: %s\n' "$*" >&2; exit 1; }

# key=value lines; a later run adds to it, never forgets what an earlier run did.
record() { touch "$STATE"; chmod 600 "$STATE"; grep -qxF "$1" "$STATE" || echo "$1" >> "$STATE"; }

[ "$(id -u)" != "0" ] || die "Run this as your normal user, not root (it uses sudo where needed)."
[ -r /etc/os-release ] || die "Can't tell which Linux this is (/etc/os-release is missing)."
# shellcheck disable=SC1091
. /etc/os-release
ARCH="$(uname -m)"
step "Host: ${PRETTY_NAME:-Linux} ($ARCH)"

if command -v apt-get >/dev/null; then PM=apt
elif command -v dnf >/dev/null; then PM=dnf
else die "Only Debian/Ubuntu (apt) and Fedora/RHEL (dnf) hosts are supported."
fi

step "Checking sudo"
note "Some steps need administrator rights; enter your password if asked."
sudo -v || die "sudo is required for the one-time install."
# Keep the sudo timestamp fresh while the long build runs.
( while true; do sudo -n true 2>/dev/null; sleep 50; done ) &
SUDO_KEEPALIVE=$!
trap 'kill $SUDO_KEEPALIVE 2>/dev/null || true' EXIT

# --- Packages -------------------------------------------------------------------------------------------
install_pkgs() {
  [ $# -gt 0 ] || return 0
  if [ "$PM" = apt ]; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null
  else
    sudo dnf install -y -q "$@" >/dev/null
  fi
  for p in "$@"; do record "PACKAGE=$p"; done
}
pkg_installed() {
  if [ "$PM" = apt ]; then dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
  else rpm -q "$1" >/dev/null 2>&1; fi
}

step "Installing packages"
if [ "$PM" = apt ]; then sudo apt-get update -qq >/dev/null; fi
need=()
for p in curl openssl rsync ca-certificates; do pkg_installed "$p" || need+=("$p"); done
install_pkgs "${need[@]}"

if ! command -v docker >/dev/null; then
  if [ "$PM" = apt ]; then
    install_pkgs docker.io
    # Compose v2 comes as its own package on Ubuntu 22.04+ and Debian 13+.
    if apt-cache show docker-compose-v2 >/dev/null 2>&1; then install_pkgs docker-compose-v2
    elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then install_pkgs docker-compose-plugin
    fi
  else
    install_pkgs moby-engine docker-compose
  fi
  ok "Installed Docker"
else
  ok "Docker is already installed ($(docker --version 2>/dev/null | head -1))"
fi
docker compose version >/dev/null 2>&1 || sudo docker compose version >/dev/null 2>&1 \
  || die "Docker Compose v2 isn't available from this distribution's packages. Install it (https://docs.docker.com/compose/install/linux/) and run initial_setup.sh again."

if ! systemctl is-enabled docker >/dev/null 2>&1 || ! systemctl is-active docker >/dev/null 2>&1; then
  sudo systemctl enable --now docker >/dev/null 2>&1
  record "ENABLED_DOCKER_SERVICE=1"
fi
ok "Docker is running"

if ! id -nG "$ME" | tr ' ' '\n' | grep -qx docker; then
  sudo usermod -aG docker "$ME"
  record "ADDED_TO_DOCKER_GROUP=$ME"
  ok "Added $ME to the docker group"
fi
# This session doesn't have the new group yet: run docker through sg until the next login.
if docker info >/dev/null 2>&1; then DOCKER_PREFIX=()
elif sg docker -c "docker info" >/dev/null 2>&1; then DOCKER_PREFIX=(sg docker -c)
else DOCKER_PREFIX=(sudo)
fi
dkr() {
  if [ "${#DOCKER_PREFIX[@]}" -eq 0 ]; then "$@"
  elif [ "${DOCKER_PREFIX[0]}" = sg ]; then sg docker -c "$(printf '%q ' "$@")"
  else sudo "$@"; fi
}

# --- sshd: the app tunnels to the manager's unix socket and to the per-bot desktop ports -----------------
step "Checking SSH forwarding"
SSHD_DROPIN="/etc/ssh/sshd_config.d/49-shellhouse.conf"
sshd_value() { sudo sshd -T -C "user=$ME,host=localhost,addr=127.0.0.1" 2>/dev/null | awk -v k="$1" '$1==k {print $2}'; }
streamlocal="$(sshd_value allowstreamlocalforwarding)"
tcp="$(sshd_value allowtcpforwarding)"
if [ "$streamlocal" = "no" ] || [ "$streamlocal" = "remote" ] || [ "$tcp" = "no" ] || [ "$tcp" = "remote" ]; then
  if [ -d /etc/ssh/sshd_config.d ] && grep -qiE '^\s*Include\s+/etc/ssh/sshd_config.d' /etc/ssh/sshd_config; then
    printf 'Match User %s\n    AllowStreamLocalForwarding local\n    AllowTcpForwarding local\n' "$ME" | sudo tee "$SSHD_DROPIN" >/dev/null
    if sudo sshd -t; then
      sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd
      record "SSHD_DROPIN=$SSHD_DROPIN"
      ok "Allowed local port and socket forwarding for $ME"
    else
      sudo rm -f "$SSHD_DROPIN"; die "sshd rejected the forwarding change; nothing was left behind."
    fi
  else
    die "sshd forbids the forwarding the app needs (AllowStreamLocalForwarding/AllowTcpForwarding), and has no sshd_config.d to add an exception to."
  fi
else
  ok "sshd allows the forwarding the app uses"
fi

# --- The stack -------------------------------------------------------------------------------------------
step "Configuring the stack in ~/shellhouse"
./setup.sh >/dev/null
set_env() {
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi
}
# Bots install what their work needs (apt-get) inside their own VM; this is how the app is normally run.
set_env SANDBOX_ALLOW_SUDO "$ALLOW_SUDO"
DGID="$(stat -c '%g' /var/run/docker.sock)"
set_env DOCKER_GID "$DGID"
mkdir -p sandbox-manager-run
chmod 600 .env
ok "Wrote .env (manager token generated; it never leaves this host except to your Mac's Keychain)"

step "Building the sandbox image (the first build takes a while)"
dkr docker compose build sandbox sandbox-manager
record "COMPOSE_PROJECT=shellhouse"
step "Starting the sandbox manager"
dkr docker compose up -d sandbox sandbox-manager >/dev/null
for _ in $(seq 1 60); do [ -S sandbox-manager-run/manager.sock ] && break; sleep 1; done
[ -S sandbox-manager-run/manager.sock ] || die "The sandbox manager didn't create its socket. Check: docker logs agent-sandbox-manager"
if curl -fsS --unix-socket sandbox-manager-run/manager.sock http://localhost/healthz >/dev/null 2>&1; then
  ok "Sandbox manager is up"
else
  note "The manager socket exists but /healthz didn't answer yet; it may still be starting."
fi

if [ "$WITH_SMOLAGENTS" = "1" ]; then
  step "Allowing the smolagents model proxy forward"
  bash scripts/enable-model-proxy-forward.sh --yes
  record "SSHD_DROPIN=/etc/ssh/sshd_config.d/50-shellhouse-model-proxy.conf"
fi

record "INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
step "Host is ready"
