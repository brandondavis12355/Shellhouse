#!/usr/bin/env bash
# Runs ON the Linux host, as the SSH user (initial_setup.sh copies the repo to ~/shellhouse and runs this there).
# Installs what the stack needs, starts the sandbox manager, and records everything it changed in
# ~/.shellhouse-install-state so uninstall.sh can put it all back.
#
#   bash ~/shellhouse/scripts/host-setup.sh [--with-smolagents] [--with-firecracker|--no-firecracker] [--no-sudo-in-sandboxes] [--yes]
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail

WITH_SMOLAGENTS=0
ALLOW_SUDO=1
ASSUME_YES=0
PASSWORD_STDIN=0
NO_PASSWORD_LOGIN=0
RELAY_BIND_ARG=""
WITH_EGRESS=0
WITH_FIRECRACKER=""      # empty: keep whichever backend this box already uses
for arg in "$@"; do
  case "$arg" in
    # The friends relay, listening on this address (the box's own, on the network friends use).
    --with-relay=*) RELAY_BIND_ARG="${arg#--with-relay=}" ;;
    # Outbound-traffic allowlist for the bots' VMs (experimental; docs/EGRESS.md).
    --with-egress) WITH_EGRESS=1 ;;
    # The bots' computers as Firecracker microVMs instead of Docker containers (docs/FIRECRACKER.md).
    --with-firecracker) WITH_FIRECRACKER=1 ;;
    --no-firecracker) WITH_FIRECRACKER=0 ;;
    --with-smolagents) WITH_SMOLAGENTS=1 ;;
    --no-sudo-in-sandboxes) ALLOW_SUDO=0 ;;
    --yes) ASSUME_YES=1 ;;
    # initial_setup.sh asked for the sudo password in a dialog and sends it as the first line of stdin.
    --sudo-password-stdin) PASSWORD_STDIN=1 ;;
    # Key sign-in was checked to work: turn off password sign-in for this user.
    --no-password-login) NO_PASSWORD_LOGIN=1 ;;
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
if [ "$PASSWORD_STDIN" = "1" ]; then
  # Kept only in this process's environment, for an askpass helper every `sudo` here (and in scripts this one
  # runs) uses via a wrapper on PATH. Removed when the script ends.
  IFS= read -r SHELLHOUSE_SUDO_PW || true
  export SHELLHOUSE_SUDO_PW
  SUDO_HELPERS="$(mktemp -d)"
  printf '#!/bin/sh\nprintf "%%s\\n" "$SHELLHOUSE_SUDO_PW"\n' > "$SUDO_HELPERS/askpass"
  printf '#!/bin/sh\nexec /usr/bin/sudo -A "$@"\n' > "$SUDO_HELPERS/sudo"
  chmod 700 "$SUDO_HELPERS/askpass" "$SUDO_HELPERS/sudo"
  export SUDO_ASKPASS="$SUDO_HELPERS/askpass" PATH="$SUDO_HELPERS:$PATH"
  trap 'rm -rf "$SUDO_HELPERS"; unset SHELLHOUSE_SUDO_PW' EXIT
  sudo -v 2>/dev/null || die "That sudo password wasn't accepted."
else
  note "Some steps need administrator rights; enter your password if asked."
  # `sudo -v` asks for a password even under NOPASSWD unless every matching rule is NOPASSWD.
  sudo -n true 2>/dev/null || sudo -v || die "sudo is required for the one-time install."
fi
# Keep the sudo timestamp fresh while the long build runs.
( while true; do sudo -n true 2>/dev/null; sleep 50; done ) &
SUDO_KEEPALIVE=$!
trap 'kill $SUDO_KEEPALIVE 2>/dev/null || true; [ -n "${SUDO_HELPERS:-}" ] && rm -rf "$SUDO_HELPERS"; unset SHELLHOUSE_SUDO_PW' EXIT

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
# Compose v2 where the distribution doesn't package it (Debian 12, for one): Docker's own release of the plugin,
# from github.com/docker/compose, checked against its published SHA-256 before it's installed.
if ! docker compose version >/dev/null 2>&1 && ! sudo docker compose version >/dev/null 2>&1; then
  case "$ARCH" in x86_64|amd64) carch=x86_64 ;; aarch64|arm64) carch=aarch64 ;; armv7l) carch=armv7 ;; *) die "No Docker Compose build for $ARCH." ;; esac
  note "Docker Compose v2 isn't packaged here; installing Docker's own release of it (github.com/docker/compose)…"
  url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$carch"
  tmpc="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmpc/docker-compose" && curl -fsSL "$url.sha256" -o "$tmpc/docker-compose.sha256" \
    || die "Couldn't download Docker Compose from GitHub."
  ( cd "$tmpc" && sed -i 's#  .*#  docker-compose#; s# \*.*#  docker-compose#' docker-compose.sha256 && sha256sum -c docker-compose.sha256 >/dev/null ) \
    || die "The Docker Compose download didn't match its published checksum; nothing was installed."
  sudo install -D -m 755 "$tmpc/docker-compose" /usr/local/lib/docker/cli-plugins/docker-compose
  rm -rf "$tmpc"
  record "COMPOSE_PLUGIN=/usr/local/lib/docker/cli-plugins/docker-compose"
  docker compose version >/dev/null 2>&1 || sudo docker compose version >/dev/null 2>&1 || die "Docker Compose still doesn't run."
  ok "Installed Docker Compose $(docker compose version --short 2>/dev/null || true)"
fi

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
# set_env and write_stack_env: the stack's .env and seed folders (shared with scripts/make-env.sh).
# shellcheck source=lib/stack-env.sh
. scripts/lib/stack-env.sh
write_stack_env
# Bots install what their work needs (apt-get) inside their own VM; this is how the app is normally run.
set_env SANDBOX_ALLOW_SUDO "$ALLOW_SUDO"
# A changeover from another box: its options come along (initial_setup.sh copied them to .env.carryover), but not
# what is this machine's own (the token, the docker group, the socket owner, the relay's address, and whether it
# runs Docker containers or Firecracker microVMs: that is asked for each box).
if [ -f .env.carryover ]; then
  carried=0
  while IFS= read -r line; do
    [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    case "$key" in SANDBOX_BACKEND|COMPOSE_FILE|MANAGER_TOKEN|DOCKER_GID|MANAGER_SOCKET_UID|MANAGER_SOCKET_GID|MANAGER_SOCKET_HOST_DIR|RELAY_BIND|EGRESS_ADMIN_TOKEN|SECRETS_KEY) continue ;; esac
    set_env "$key" "$value"; carried=$((carried + 1))
  done < .env.carryover
  rm -f .env.carryover
  ok "Kept $carried option(s) from the previous host's .env"
fi
mkdir -p sandbox-manager-run
chmod 600 .env
# Only you: the manager's socket (anyone who can reach it runs commands in the bots' VMs), the token, and the
# scripts the app's SSH key is limited to.
chmod 700 "$REPO" sandbox-manager-run
chmod 755 scripts/app-ssh-command.sh 2>/dev/null || true
ok "Wrote .env (manager token generated; it never leaves this host except to your Mac's Keychain)"

if [ -z "$WITH_FIRECRACKER" ]; then
  WITH_FIRECRACKER=0; grep -q '^SANDBOX_BACKEND=firecracker' .env && WITH_FIRECRACKER=1
fi
record "COMPOSE_PROJECT=shellhouse"
if [ "$WITH_FIRECRACKER" = "1" ]; then
  # The manager becomes a host service and the bots' computers microVMs; it builds the same desktop image.
  bash scripts/host-firecracker.sh install
else
  bash scripts/host-firecracker.sh disable
  step "Building the sandbox image (the first build takes a while)"
  dkr docker compose build sandbox sandbox-manager
  step "Starting the sandbox manager"
  dkr docker compose up -d sandbox sandbox-manager >/dev/null
fi
for _ in $(seq 1 60); do [ -S sandbox-manager-run/manager.sock ] && break; sleep 1; done
[ -S sandbox-manager-run/manager.sock ] || die "The sandbox manager didn't create its socket. Check: $([ "$WITH_FIRECRACKER" = 1 ] && echo 'journalctl -u agent-sandbox-manager' || echo 'docker logs agent-sandbox-manager')"
if curl -fsS --unix-socket sandbox-manager-run/manager.sock http://localhost/healthz >/dev/null 2>&1; then
  ok "Sandbox manager is up"
else
  note "The manager socket exists but /healthz didn't answer yet; it may still be starting."
fi

# --- Optional: the friends relay -------------------------------------------------------------------------
if [ -n "$RELAY_BIND_ARG" ]; then
  step "Setting up the friends relay"
  RELAY_IP="${RELAY_BIND_ARG%%:*}"; RELAY_PORT_SET="8443"
  [[ "$RELAY_BIND_ARG" == *:* ]] && RELAY_PORT_SET="${RELAY_BIND_ARG##*:}"
  set_env RELAY_BIND "$RELAY_IP"
  set_env RELAY_PORT "$RELAY_PORT_SET"
  grep -q '^RELAY_REGISTRATION_TOKEN=.\+' .env || set_env RELAY_REGISTRATION_TOKEN "$(openssl rand -hex 16)"
  if [ ! -f group-relay/certs/fullchain.pem ]; then
    # Self-signed, for every name the box answers to; the app pins its fingerprint.
    mkdir -p group-relay/certs
    san="IP:$RELAY_IP"; hn="$(hostname)"; [ -n "$hn" ] && san="$san,DNS:$hn,DNS:$hn.local"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 825 \
      -keyout group-relay/certs/privkey.pem -out group-relay/certs/fullchain.pem \
      -subj "/CN=$RELAY_IP" -addext "subjectAltName=$san" >/dev/null 2>&1 || die "Couldn't create the relay's certificate."
    # The relay runs as uid 10001 in its container: it alone may read the key.
    sudo chown 10001:10001 group-relay/certs/privkey.pem group-relay/certs/fullchain.pem
    sudo chmod 600 group-relay/certs/privkey.pem; sudo chmod 644 group-relay/certs/fullchain.pem
    ok "Created the relay's certificate"
  else
    ok "Kept the relay's existing certificate"
  fi
  dkr docker compose --profile relay up -d --build group-relay >/dev/null
  record "RELAY=1"
  ok "Relay running on https://$RELAY_IP:$RELAY_PORT_SET"
fi

# --- Optional: outbound allowlist for the bots (experimental) --------------------------------------------
if [ "$WITH_EGRESS" = "1" ] && [ "$WITH_FIRECRACKER" = "1" ]; then
  # The proxy works on the Docker backend's networks; the microVMs have their own network policy instead.
  note "Skipped the outbound allowlist: it applies to Docker containers only. The microVMs reach the public internet"
  note "and nothing else (docs/FIRECRACKER.md › Network policy)."
elif [ "$WITH_EGRESS" = "1" ]; then
  step "Setting up the outbound allowlist (egress proxy)"
  set_env SANDBOX_EGRESS_MODE allowlist
  grep -q '^EGRESS_ADMIN_TOKEN=.\+' .env || set_env EGRESS_ADMIN_TOKEN "$(openssl rand -hex 32)"
  set_env EGRESS_VNC_FORWARD "6100-6131"
  gw="$(dkr docker network inspect shellhouse_default --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
  [ -n "$gw" ] && set_env EGRESS_VNC_ALLOW_CIDRS "$gw/32"
  dkr docker compose --profile egress up -d --build egress-proxy >/dev/null
  # Without an allowlist everything is denied: start from the example (package mirrors, GitHub, PyPI…).
  if ! dkr docker exec agent-egress-proxy test -f /data/allowlist.txt; then
    dkr docker cp egress-proxy/allowlist.example.txt agent-egress-proxy:/data/allowlist.txt
  fi
  # The manager reads the mode at start.
  dkr docker compose up -d --no-deps sandbox-manager >/dev/null
  record "EGRESS=1"
  ok "Bots' outbound traffic now goes through the allowlist (edit it in the egress_data volume: /data/allowlist.txt)"
  note "Bot VMs that already exist keep open access until they're reset (Bot settings › Delete or reset › Reset sandbox)."
fi

# --- Firecracker: offered when the box can run it --------------------------------------------------------
if [ -e /dev/kvm ] && [ "$WITH_FIRECRACKER" != "1" ]; then
  note "This box supports KVM: initial_setup.sh --with-firecracker runs each bot's computer as its own microVM"
  note "instead of a Docker container (docs/FIRECRACKER.md)."
fi

if [ "$WITH_SMOLAGENTS" = "1" ]; then
  step "Allowing the smolagents model proxy forward"
  bash scripts/enable-model-proxy-forward.sh --yes
  record "SSHD_DROPIN=/etc/ssh/sshd_config.d/50-shellhouse-model-proxy.conf"
fi

if [ "$NO_PASSWORD_LOGIN" = "1" ]; then
  step "Turning off password sign-in for $ME"
  AUTH_DROPIN="/etc/ssh/sshd_config.d/48-shellhouse-auth.conf"
  printf 'Match User %s\n    PasswordAuthentication no\n    KbdInteractiveAuthentication no\n' "$ME" | sudo tee "$AUTH_DROPIN" >/dev/null
  if sudo sshd -t; then
    sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd
    record "SSHD_DROPIN=$AUTH_DROPIN"
    ok "Only SSH keys can sign in as $ME now"
  else
    sudo rm -f "$AUTH_DROPIN"; note "sshd rejected that change; password sign-in is unchanged."
  fi
fi

record "INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
step "Host is ready"
