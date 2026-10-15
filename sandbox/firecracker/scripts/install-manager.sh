#!/usr/bin/env bash
# Installs (or updates) the Sandbox Manager as the host service agent-sandbox-manager, for the Firecracker backend:
#   /opt/agent-sandbox-manager          the manager's code, and its own Python venv (.venv)
#   /etc/agent-sandbox-manager.env      its settings and token (root only), from ~USER/shellhouse/.env
#   /etc/systemd/system/agent-sandbox-manager.service
#   /etc/sudoers.d/shellhouse-firecracker  lets USER re-sync the token after a rotation (that one command only)
# Its socket is ~USER/shellhouse/sandbox-manager-run/manager.sock, where the Mac app's tunnel expects it.
#
#   sudo ./install-manager.sh --user NAME     # install or update, then (re)start it
#   sudo ./install-manager.sh --user NAME --repo DIR --name SVC   # a second instance, for testing side by side
#   sudo ./install-manager.sh --remove
#
# Python packages come from PyPI, pinned in sandbox-manager/requirements.txt, as prebuilt wheels only: nothing is
# compiled on the host, and no build toolchain is downloaded as root.
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/../../.." && pwd)"

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

USER_NAME=""; MODE=install; NAME=agent-sandbox-manager; REPO_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="${2:?--user needs a value}"; shift 2 ;;
    --repo) REPO_ARG="${2:?--repo needs a value}"; shift 2 ;;
    --name) NAME="${2:?--name needs a value}"; shift 2 ;;
    --remove) MODE=remove; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$NAME" =~ ^agent-sandbox-manager(-[a-z0-9]+)?$ ]] || { echo "--name must be agent-sandbox-manager[-suffix]" >&2; exit 2; }
SUFFIX="${NAME#agent-sandbox-manager}"
OPT="/opt/$NAME"
ENV_FILE="/etc/$NAME.env"
UNIT="/etc/systemd/system/$NAME.service"
LIB_DIR=/usr/local/lib/shellhouse-firecracker
SYNC="$LIB_DIR/sync-manager-token$SUFFIX"
SUDOERS="/etc/sudoers.d/shellhouse-firecracker$SUFFIX"

if [[ "$MODE" == remove ]]; then
  systemctl disable --now "$NAME.service" >/dev/null 2>&1 || true
  rm -f "$UNIT" "$ENV_FILE" "$SUDOERS" "$SYNC"
  rm -rf "$OPT"
  [[ -n "$SUFFIX" ]] || rm -rf /var/log/sandbox-manager
  systemctl daemon-reload
  echo "    removed the $NAME service"
  exit 0
fi

[[ "$USER_NAME" =~ ^[a-z_][a-z0-9_.-]*$ ]] && id "$USER_NAME" >/dev/null 2>&1 || { echo "--user must name an existing user" >&2; exit 2; }
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
REPO="${REPO_ARG:-$HOME_DIR/shellhouse}"
SOCKET_DIR="$REPO/sandbox-manager-run"
DOTENV="$REPO/.env"
[[ -f "$DOTENV" ]] || { echo "$DOTENV is missing (scripts/host-setup.sh writes it)" >&2; exit 1; }
install -d -m 0700 -o "$USER_NAME" -g "$(id -g "$USER_NAME")" "$SOCKET_DIR"

echo "==> Installing the manager in $OPT"
install -d -m 0755 "$OPT"
find "$OPT" -mindepth 1 -maxdepth 1 ! -name .venv -exec rm -rf {} +
cp -R "$SRC/sandbox-manager/app/." "$OPT/"
find "$OPT" -name __pycache__ -prune -exec rm -rf {} +
[[ -x "$OPT/.venv/bin/python" ]] || python3 -m venv "$OPT/.venv"
# The Docker SDK is only for the Docker backend.
grep -v '^docker==' "$SRC/sandbox-manager/requirements.txt" > "$OPT/requirements.txt"
"$OPT/.venv/bin/pip" install -q --disable-pip-version-check --only-binary=:all: -r "$OPT/requirements.txt" || {
  echo "A package has no prebuilt wheel for this host's Python ($("$OPT/.venv/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])'), $(uname -m))." >&2
  echo "Use a Python between 3.11 and 3.14 (python3 -m venv uses python3 by default), or update the pins in sandbox-manager/requirements.txt." >&2
  exit 1
}
chmod -R go-w "$OPT"

# Settings from the stack's .env, each checked before it goes into a root service's environment.
dotenv() { sed -n "s/^$1=//p" "$DOTENV" | tail -n 1; }
pick() {  # name default regex
  local v; v="$(dotenv "$1")"; v="${v:-$2}"
  [[ "$v" =~ ^($3)$ ]] || { echo "$1=$v in $DOTENV isn't valid; using $2" >&2; v="$2"; }
  printf '%s=%s\n' "$1" "$v"
}
write_env() {
  local token; token="$(dotenv MANAGER_TOKEN)"
  [[ "$token" =~ ^[A-Za-z0-9]{32,128}$ ]] || { echo "MANAGER_TOKEN in $DOTENV is missing or malformed" >&2; return 1; }
  ( umask 077
    {
      echo "# Written by install-manager.sh from $DOTENV; edit that file and re-run setup instead."
      echo "MANAGER_TOKEN=$token"
      local extra; extra="$(dotenv MANAGER_EXTRA_TOKENS)"
      if [[ "$extra" =~ ^[A-Za-z0-9]{32,128}(,[A-Za-z0-9]{32,128})*$ ]]; then echo "MANAGER_EXTRA_TOKENS=$extra"
      elif [ -n "$extra" ]; then echo "MANAGER_EXTRA_TOKENS in $DOTENV is malformed; ignoring it" >&2; fi
      echo "SANDBOX_BACKEND=firecracker"
      echo "MANAGER_AUDIT_LOG=/var/log/sandbox-manager/audit.log"
      echo "SANDBOX_USER=box"
      echo "FIRECRACKER_UID=$(id -u shellhouse-fc)"
      echo "FIRECRACKER_GID=$(id -g shellhouse-fc)"
      pick FIRECRACKER_VCPUS 2 '[1-9][0-9]?'
      pick FIRECRACKER_MEM_MIB 2048 '[1-9][0-9]{2,5}'
      pick FIRECRACKER_BOOT_TIMEOUT 90 '[1-9][0-9]{1,3}'
      pick FIRECRACKER_PARALLEL_BOOTS 2 '[1-9][0-9]?'
      pick FIRECRACKER_USE_JAILER true 'true|false'
      pick FIRECRACKER_DNS 1.1.1.1 '[0-9]{1,3}(\.[0-9]{1,3}){3}'
      pick FIRECRACKER_IMPORT_DOCKER_WORKSPACES 1 '0|1'
      pick SANDBOX_ALLOW_SUDO 0 '0|1'
      pick SANDBOX_PORT_BASE 6100 '[1-9][0-9]{3,4}'
      pick SANDBOX_PORT_COUNT 32 '[1-9][0-9]?'
    } > "$ENV_FILE.new" )
  mv -f "$ENV_FILE.new" "$ENV_FILE"
}
id shellhouse-fc >/dev/null 2>&1 || { echo "Run setup-host.sh first (no shellhouse-fc user)" >&2; exit 1; }
write_env

echo "==> Installing the service"
sed -e "s#@SOCKET_DIR@#$SOCKET_DIR#g" -e "s#@OPT@#$OPT#g" -e "s#@ENV_FILE@#$ENV_FILE#g" \
  "$SRC/sandbox-manager/systemd/agent-sandbox-manager.service" > "$UNIT.new"
mv -f "$UNIT.new" "$UNIT"

# Token rotation (scripts/host-rotate-token.sh) runs as USER without a password: it may run this one fixed helper,
# which only copies MANAGER_TOKEN from USER's own .env and restarts the manager.
install -d -m 0755 "$LIB_DIR"
cat > "$SYNC" <<SH
#!/bin/sh
# Copies a rotated MANAGER_TOKEN from $DOTENV into $ENV_FILE and restarts the manager. Takes no arguments.
set -eu
token="\$(sed -n 's/^MANAGER_TOKEN=//p' '$DOTENV' | tail -n 1)"
printf '%s' "\$token" | grep -Eqx '[A-Za-z0-9]{32,128}' || { echo "malformed token" >&2; exit 1; }
umask 077
sed "s/^MANAGER_TOKEN=.*/MANAGER_TOKEN=\$token/" '$ENV_FILE' > '$ENV_FILE.new'
mv -f '$ENV_FILE.new' '$ENV_FILE'
exec systemctl restart $NAME.service
SH
chmod 0755 "$SYNC"
printf '%s ALL=(root) NOPASSWD: %s\n' "$USER_NAME" "$SYNC" > "$SUDOERS.new"
chmod 0440 "$SUDOERS.new"
visudo -cqf "$SUDOERS.new" && mv -f "$SUDOERS.new" "$SUDOERS" || { rm -f "$SUDOERS.new"; echo "sudoers rule rejected" >&2; }

systemctl daemon-reload
systemctl enable "$NAME.service" >/dev/null 2>&1
systemctl stop "$NAME.service" >/dev/null 2>&1 || true
rm -f "$SOCKET_DIR/manager.sock"      # so the wait below sees the new one, not a stale file
systemctl start "$NAME.service"
up() { curl -fsS --unix-socket "$SOCKET_DIR/manager.sock" http://localhost/healthz >/dev/null 2>&1; }
for _ in $(seq 1 30); do up && break; sleep 1; done
up || { echo "The manager didn't create its socket. Check: journalctl -u $NAME" >&2; exit 1; }
echo "    $NAME is running; socket $SOCKET_DIR/manager.sock"
