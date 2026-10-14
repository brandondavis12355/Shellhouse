#!/usr/bin/env bash
# Removes Shellhouse from a Linux host, over SSH from your Mac, as if it had never been set up there:
# all of its containers, volumes, networks and images, ~/shellhouse, the app's SSH key, the sshd changes, and
# the packages / docker group membership initial_setup.sh added (anything that was there before stays).
#
#   ./uninstall.sh                         # asks which host
#   ./uninstall.sh --host 192.0.2.10 --user alice
#   ./uninstall.sh --keep-packages         # leave Docker and the other packages setup installed
#   ./uninstall.sh --mac                   # also remove the app, its data and its Keychain items from this Mac
#
# It asks you to type the host's address to confirm: this deletes every bot VM and its files on that host.
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$REPO/scripts/lib/common.sh"

HOST_ARG=""; USER_ARG=""; REMOTE_FLAGS=(); ALSO_MAC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST_ARG="${2:?--host needs a value}"; shift 2 ;;
    --user) USER_ARG="${2:?--user needs a value}"; shift 2 ;;
    --keep-packages) REMOTE_FLAGS+=(--keep-packages); shift ;;
    --mac) ALSO_MAC=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "Run this on your Mac; it cleans up the Linux box over SSH."
printf '%sShellhouse — uninstall%s\n' "$C_BOLD" "$C_RESET"
load_state

step "Which Linux box?"
SHELLHOUSE_HOST="${HOST_ARG:-$(ask "IP address or hostname of the Linux box" "${SHELLHOUSE_HOST:-}")}"
valid_host "$SHELLHOUSE_HOST" || die "\"$SHELLHOUSE_HOST\" doesn't look like an IP address or hostname."
SHELLHOUSE_USER="${USER_ARG:-$(ask "SSH user on $SHELLHOUSE_HOST" "${SHELLHOUSE_USER:-$(id -un)}")}"
valid_user "$SHELLHOUSE_USER" || die "\"$SHELLHOUSE_USER\" doesn't look like a Linux user name."

warn "This deletes every Shellhouse VM on $SHELLHOUSE_HOST, with the files in them, and ~$SHELLHOUSE_USER/$SHELLHOUSE_REMOTE_DIR."
typed="$(ask "Type the host's address ($SHELLHOUSE_HOST) to confirm")"
[ "$typed" = "$SHELLHOUSE_HOST" ] || die "That didn't match; nothing was changed."

step "Connecting"
OFFER_KEY_COPY=0 ssh_connect
trap ssh_close EXIT

step "Cleaning up the host"
REMOTE_SCRIPT="/tmp/shellhouse-host-uninstall.sh"
ssh_run "cat > $REMOTE_SCRIPT && chmod 700 $REMOTE_SCRIPT" < "$REPO/scripts/host-uninstall.sh"
ssh_tty "bash $REMOTE_SCRIPT ${REMOTE_FLAGS[*]:-}" || die "Cleanup on the host stopped early (see above). It's safe to run ./uninstall.sh again."
ssh_close

# The Mac side: this script's own state, and the app if asked.
rm -f "$SHELLHOUSE_PENDING_SETTINGS"
rm -f "$SHELLHOUSE_STATE_DIR"/ssh-* 2>/dev/null || true
if [ "$ALSO_MAC" = "1" ]; then
  step "Removing Shellhouse from this Mac"
  osascript -e 'tell application "Shellhouse" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do app_running || break; sleep 0.5; done
  app_running && pkill -x "Shellhouse" || true
  rm -rf "$SHELLHOUSE_APP" && ok "Removed $SHELLHOUSE_APP"
  # The app's Keychain items (manager token, API keys, saved secrets).
  removed=0
  while security delete-generic-password -s "ai.compute.agent.secrets" >/dev/null 2>&1; do removed=$((removed + 1)); done
  [ "$removed" -gt 0 ] && ok "Removed $removed Keychain item(s)"
  defaults delete "$SHELLHOUSE_BUNDLE_ID" >/dev/null 2>&1 || true
  # The app's sandbox container: macOS may protect it from Terminal; then delete it in Finder.
  CONTAINER="$HOME/Library/Containers/$SHELLHOUSE_BUNDLE_ID"
  if [ -d "$CONTAINER" ]; then
    if rm -rf "$CONTAINER" 2>/dev/null; then ok "Removed the app's data"
    else warn "macOS didn't let Terminal delete the app's data. Delete $CONTAINER in Finder (or give Terminal Full Disk Access)."; fi
  fi
  rm -rf "$SHELLHOUSE_STATE_DIR"
  ok "Removed ~/.config/shellhouse"
else
  rm -f "$SHELLHOUSE_STATE_FILE"
  info "The app is still installed on this Mac. Run ./uninstall.sh --mac to remove it too."
fi

step "Done"
info "$SHELLHOUSE_HOST no longer has anything from Shellhouse."
