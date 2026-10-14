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
# Run it again with the same box to update it: nothing is overwritten (its .env and token stay, the image is rebuilt).
# Run it with a NEW box to move to it (a changeover): everything in the app on this Mac (settings, bots, groups,
# conversations, memories) stays as it is, and only the host it uses changes. It also offers to bring the old box's
# .env options and each bot's workspace files over. The old box is left untouched; remove it later with
# ./uninstall.sh --host OLD.
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
SAVED_HOST="$SHELLHOUSE_HOST"; SAVED_USER="$SHELLHOUSE_USER"
[ -n "$SAVED_HOST" ] && info "Shellhouse currently uses $SAVED_USER@$SAVED_HOST. Enter a different box to move to it."
SHELLHOUSE_HOST="${HOST_ARG:-$(ask "IP address or hostname of the Linux box" "${SHELLHOUSE_HOST:-}")}"
valid_host "$SHELLHOUSE_HOST" || die "\"$SHELLHOUSE_HOST\" doesn't look like an IP address or hostname."
SHELLHOUSE_USER="${USER_ARG:-$(ask "SSH user on $SHELLHOUSE_HOST" "${SHELLHOUSE_USER:-$(id -un)}")}"
valid_user "$SHELLHOUSE_USER" || die "\"$SHELLHOUSE_USER\" doesn't look like a Linux user name."

# A changeover: a different box than before (or one a previous, unfinished changeover was moving to).
if [ -n "$SAVED_HOST" ] && { [ "$SAVED_HOST" != "$SHELLHOUSE_HOST" ] || [ "$SAVED_USER" != "$SHELLHOUSE_USER" ]; }; then
  SHELLHOUSE_PREV_HOST="$SAVED_HOST"; SHELLHOUSE_PREV_USER="$SAVED_USER"
fi
CHANGEOVER=0
if [ -n "${SHELLHOUSE_PREV_HOST:-}" ] && [ "$SHELLHOUSE_PREV_HOST@$SHELLHOUSE_PREV_USER" != "$SHELLHOUSE_HOST@$SHELLHOUSE_USER" ]; then
  CHANGEOVER=1
  step "Changeover: $SHELLHOUSE_PREV_USER@$SHELLHOUSE_PREV_HOST → $SHELLHOUSE_USER@$SHELLHOUSE_HOST"
  info "Everything in the app on this Mac stays: settings, bots, groups, conversations and memories."
  info "Only the box it uses changes. $SHELLHOUSE_PREV_HOST itself isn't changed."
else
  SHELLHOUSE_PREV_HOST=""; SHELLHOUSE_PREV_USER=""
  [ "$SAVED_HOST" = "$SHELLHOUSE_HOST" ] && info "Same box as before: updating it in place (its .env and manager token are kept)."
fi
save_state

step "Connecting"
ssh_connect
NEW_TARGET="$SSH_TARGET"
trap 'ssh_close; [ -n "${OLD_TARGET:-}" ] && ssh "${SSH_OPTS[@]}" -O exit "$OLD_TARGET" >/dev/null 2>&1; true' EXIT

# The old box, for a changeover: reachable (the password is asked once if needed), or the move goes on without it.
OLD_TARGET=""; CARRY_ENV=0; CARRY_VOLUMES=0
old_run() { ssh "${SSH_OPTS[@]}" "$OLD_TARGET" "$@"; }
if [ "$CHANGEOVER" = "1" ]; then
  step "Checking the old box"
  if ssh "${SSH_OPTS[@]}" "$SHELLHOUSE_PREV_USER@$SHELLHOUSE_PREV_HOST" true 2>/dev/null; then
    OLD_TARGET="$SHELLHOUSE_PREV_USER@$SHELLHOUSE_PREV_HOST"
    ok "Reached $OLD_TARGET"
    old_run "test -f ~/$SHELLHOUSE_REMOTE_DIR/.env" 2>/dev/null \
      && confirm "Bring its .env options over (sudo in bot VMs, resource limits…)? Its token stays behind; the new box gets its own." Y \
      && CARRY_ENV=1
    confirm "Copy each bot's workspace files (/workspace in its VM) over? Installed packages aren't copied." Y && CARRY_VOLUMES=1
  else
    warn "Couldn't reach $SHELLHOUSE_PREV_HOST. The new box starts fresh: bots get new, empty VMs. The app's settings still stay."
  fi
fi

step "Copying the server side to ~/$SHELLHOUSE_REMOTE_DIR on the host"
# Only what the host runs. The host's own .env, seed folders and manager socket are never overwritten.
rsync -az --delete \
  --exclude '.git/' --exclude 'macos/' --exclude 'avatars/' --exclude 'evals/' --exclude 'docs/' \
  --exclude '.env' --exclude 'box/' --exclude 'workspace/' --exclude 'sandbox-manager-run/' \
  --exclude 'node_modules/' --exclude '__pycache__/' --exclude '.pytest_cache/' --exclude '.venv/' --exclude '.DS_Store' \
  -e "ssh ${SSH_OPTS[*]}" "$REPO/" "$SSH_TARGET:$SHELLHOUSE_REMOTE_DIR/"
ok "Copied"

if [ "$CARRY_ENV" = "1" ]; then
  # Copied box to box through this Mac without being printed; host-setup.sh applies it and deletes it.
  old_run "grep -E '^[A-Z_][A-Z0-9_]*=' ~/$SHELLHOUSE_REMOTE_DIR/.env" \
    | ssh_run "umask 077; cat > ~/$SHELLHOUSE_REMOTE_DIR/.env.carryover" \
    && ok "Brought the old box's options along (applied during setup)" || warn "Couldn't copy the old box's .env options."
fi

step "Setting up the host"
ssh_tty "bash ~/$SHELLHOUSE_REMOTE_DIR/scripts/host-setup.sh ${HOST_FLAGS[*]:-}" || die "Host setup failed (see above). Fix it and run ./initial_setup.sh again; it picks up where it left off."

if [ "$CARRY_VOLUMES" = "1" ]; then
  step "Copying the bots' workspaces from $SHELLHOUSE_PREV_HOST"
  old_run "cat > /tmp/shellhouse-host-volume.sh && chmod 700 /tmp/shellhouse-host-volume.sh" < "$REPO/scripts/host-volume.sh"
  VOLUMES="$(old_run "bash /tmp/shellhouse-host-volume.sh list" 2>/dev/null || true)"
  if [ -z "$VOLUMES" ]; then
    info "No bot workspaces on the old box."
  else
    info "Files are copied as they are now; a bot still working on the old box may change some meanwhile."
    copied=0; skipped=0; failed=0
    for vol in $VOLUMES; do
      if old_run "bash /tmp/shellhouse-host-volume.sh export $vol" \
         | ssh_run "bash ~/$SHELLHOUSE_REMOTE_DIR/scripts/host-volume.sh import $vol" 2>"$SHELLHOUSE_STATE_DIR/volume.err"; then
        copied=$((copied + 1)); ok "$vol"
      elif grep -q "already has files" "$SHELLHOUSE_STATE_DIR/volume.err"; then
        skipped=$((skipped + 1)); info "$vol is already on the new box; left as is"
      else
        failed=$((failed + 1)); warn "$vol didn't copy: $(head -1 "$SHELLHOUSE_STATE_DIR/volume.err")"
      fi
    done
    rm -f "$SHELLHOUSE_STATE_DIR/volume.err"
    ok "Workspaces: $copied copied, $skipped already there, $failed failed"
  fi
  old_run "rm -f /tmp/shellhouse-host-volume.sh" || true
fi

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
SHELLHOUSE_PREV_HOST=""; SHELLHOUSE_PREV_USER=""; save_state

if app_installed; then
  hand_off_to_app
  step "Done"
  if [ "$CHANGEOVER" = "1" ]; then
    info "Shellhouse now uses $SHELLHOUSE_HOST, with all of its settings, bots and groups as they were."
    info "$SHELLHOUSE_PREV_HOST is untouched. Once everything works, you can remove Shellhouse from it:"
    info "  ./uninstall.sh --host $SHELLHOUSE_PREV_HOST --user $SHELLHOUSE_PREV_USER"
  else
    info "Shellhouse is connected to $SHELLHOUSE_HOST. Add a bot from the sidebar's + menu."
  fi
else
  step "Host done. Next: build and install the app"
  info "Run:  ./build.sh"
  info "It installs Shellhouse in /Applications and connects it to $SHELLHOUSE_HOST for you."
fi
