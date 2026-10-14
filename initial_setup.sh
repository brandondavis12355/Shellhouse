#!/usr/bin/env bash
# Sets up a Linux box as Shellhouse's sandbox host, from your Mac, over ordinary SSH.
#
#   ./initial_setup.sh                    # asks for the address and user
#   ./initial_setup.sh --host 192.0.2.10 --user alice
#
# What it does, start to finish:
#   1. Connects over SSH (password or your key; offers to install your key so later runs don't ask).
#   2. Copies the server side of this repo to ~/shellhouse on the host.
#   3. On the host (asks for your sudo password once): installs Docker and Compose if they're missing,
#      adds you to the docker group, makes sure sshd allows the forwarding the app uses, writes .env
#      with a fresh manager token, builds the sandbox image and starts the sandbox manager.
#      Everything it changes is recorded in ~/.shellhouse-install-state for uninstall.sh.
#   4. Prepares the app's settings (host, user, manager token) in ~/.config/shellhouse, readable only by you.
#      If Shellhouse is already installed, hands them over now; otherwise ./build.sh does it after installing.
#
# Options:
#   --host ADDR           the Linux box's IP address or hostname
#   --user NAME           SSH user on the box (default: your Mac user name)
#   --with-smolagents     also allow the optional smolagents engine's model-proxy forward (docs/SMOLAGENTS.md)
#   --no-sudo-in-sandboxes  don't give the bots sudo inside their own VMs (they then can't apt-get install)
#   --yes                 accept the defaults instead of asking
#
# Requires: macOS with ssh and rsync (both built in); a Debian/Ubuntu or Fedora host you can SSH into with
# sudo rights. The SSH port must be 22 (the app's tunnel uses it).
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$REPO/scripts/lib/common.sh"

HOST_ARG=""; USER_ARG=""; HOST_FLAGS=(); ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST_ARG="${2:?--host needs a value}"; shift 2 ;;
    --user) USER_ARG="${2:?--user needs a value}"; shift 2 ;;
    --with-smolagents) HOST_FLAGS+=(--with-smolagents); shift ;;
    --no-sudo-in-sandboxes) HOST_FLAGS+=(--no-sudo-in-sandboxes); shift ;;
    --yes) ASSUME_YES=1; HOST_FLAGS+=(--yes); shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done
export ASSUME_YES

[ "$(uname -s)" = "Darwin" ] || die "Run this on your Mac; it sets up the Linux box over SSH."
command -v rsync >/dev/null || die "rsync is missing."

printf '%sShellhouse — Linux host setup%s\n' "$C_BOLD" "$C_RESET"
load_state

step "Which Linux box?"
SHELLHOUSE_HOST="${HOST_ARG:-$(ask "IP address or hostname of the Linux box" "${SHELLHOUSE_HOST:-}")}"
valid_host "$SHELLHOUSE_HOST" || die "\"$SHELLHOUSE_HOST\" doesn't look like an IP address or hostname."
SHELLHOUSE_USER="${USER_ARG:-$(ask "SSH user on $SHELLHOUSE_HOST" "${SHELLHOUSE_USER:-$(id -un)}")}"
valid_user "$SHELLHOUSE_USER" || die "\"$SHELLHOUSE_USER\" doesn't look like a Linux user name."
save_state

step "Connecting"
ssh_connect
trap ssh_close EXIT

step "Copying the server side to ~/$SHELLHOUSE_REMOTE_DIR on the host"
# Only what the host runs. The host's own .env, seed folders and manager socket are never overwritten.
rsync -az --delete \
  --exclude '.git/' --exclude 'macos/' --exclude 'avatars/' --exclude 'evals/' --exclude 'docs/' \
  --exclude '.env' --exclude 'box/' --exclude 'workspace/' --exclude 'sandbox-manager-run/' \
  --exclude 'node_modules/' --exclude '__pycache__/' --exclude '.pytest_cache/' --exclude '.venv/' --exclude '.DS_Store' \
  -e "ssh ${SSH_OPTS[*]}" "$REPO/" "$SSH_TARGET:$SHELLHOUSE_REMOTE_DIR/"
ok "Copied"

step "Setting up the host"
ssh_tty "bash ~/$SHELLHOUSE_REMOTE_DIR/scripts/host-setup.sh ${HOST_FLAGS[*]:-}" || die "Host setup failed (see above). Fix it and run ./initial_setup.sh again; it picks up where it left off."

step "Preparing the app's settings"
# The token is read straight into this file; it is never printed or put on a command line.
mkdir -p "$SHELLHOUSE_STATE_DIR" && chmod 700 "$SHELLHOUSE_STATE_DIR"
TOKEN="$(ssh_run "sed -n 's/^MANAGER_TOKEN=//p' ~/$SHELLHOUSE_REMOTE_DIR/.env | head -1")"
[[ "$TOKEN" =~ ^[A-Za-z0-9]{32,}$ ]] || die "Couldn't read the manager token from the host's ~/$SHELLHOUSE_REMOTE_DIR/.env."
umask 077
cat > "$SHELLHOUSE_PENDING_SETTINGS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>format</key><string>shellhouse-settings</string>
	<key>version</key><integer>1</integer>
	<key>app</key>
	<dict>
		<key>linuxHostSettings.v1</key>
		<dict>
			<key>host</key><string>$(xml_escape "$SHELLHOUSE_HOST")</string>
			<key>user</key><string>$(xml_escape "$SHELLHOUSE_USER")</string>
			<key>recentHosts</key><array><string>$(xml_escape "$SHELLHOUSE_HOST")</string></array>
		</dict>
	</dict>
	<key>secrets</key>
	<dict>
		<key>SANDBOX_MANAGER_TOKEN</key><string>$TOKEN</string>
	</dict>
</dict>
</plist>
EOF
unset TOKEN
chmod 600 "$SHELLHOUSE_PENDING_SETTINGS"
ok "Saved for the app (readable only by you; deleted once the app takes it)"

if app_installed; then
  hand_off_to_app
  step "Done"
  info "Shellhouse is connected to $SHELLHOUSE_HOST. Add a bot from the sidebar's + menu."
else
  step "Host done. Next: build and install the app"
  info "Run:  ./build.sh"
  info "It installs Shellhouse in /Applications and connects it to $SHELLHOUSE_HOST for you."
fi
