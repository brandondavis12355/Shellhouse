# Shared by initial_setup.sh, build.sh and uninstall.sh (run on the Mac). Source it; don't run it.
#
# Drafted with AI assistance (Claude Code); read it before you run it.

SHELLHOUSE_STATE_DIR="${SHELLHOUSE_STATE_DIR:-$HOME/.config/shellhouse}"
SHELLHOUSE_STATE_FILE="$SHELLHOUSE_STATE_DIR/setup.env"
SHELLHOUSE_PENDING_SETTINGS="$SHELLHOUSE_STATE_DIR/pending-setup.shellhousesettings"
SHELLHOUSE_APP="/Applications/Shellhouse.app"
SHELLHOUSE_BUNDLE_ID="com.shellhouse.app"
SHELLHOUSE_REMOTE_DIR="shellhouse"          # under the SSH user's home on the Linux host; the app expects this path
SHELLHOUSE_KEY_COMMENT="shellhouse-app"     # comment on the app's own SSH public key (AppSSHIdentity.swift)

if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_RESET=""
fi

step() { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '\n%sError:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# ask "Question" default  -> prints the answer (the default on Enter, or with --yes)
ask() {
  local question="$1" default="${2:-}" answer
  if [ "${ASSUME_YES:-0}" = "1" ] && [ -n "$default" ]; then printf '%s' "$default"; return; fi
  if [ -n "$default" ]; then read -r -p "    $question [$default]: " answer </dev/tty; else read -r -p "    $question: " answer </dev/tty; fi
  printf '%s' "${answer:-$default}"
}

# confirm "Question" [Y|N]  -> exit status 0 for yes
confirm() {
  local question="$1" default="${2:-Y}" answer hint="[Y/n]"
  [ "$default" = "N" ] && hint="[y/N]"
  if [ "${ASSUME_YES:-0}" = "1" ]; then [ "$default" = "Y" ]; return; fi
  read -r -p "    $question $hint " answer </dev/tty
  answer="${answer:-$default}"
  case "$answer" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

valid_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || [[ "$1" =~ ^[0-9a-fA-F:]+$ ]]; }
valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_.-]*$ ]]; }

load_state() {
  SHELLHOUSE_HOST=""; SHELLHOUSE_USER=""
  # shellcheck disable=SC1090
  [ -f "$SHELLHOUSE_STATE_FILE" ] && . "$SHELLHOUSE_STATE_FILE"
  return 0
}

save_state() {
  mkdir -p "$SHELLHOUSE_STATE_DIR" && chmod 700 "$SHELLHOUSE_STATE_DIR"
  printf 'SHELLHOUSE_HOST=%q\nSHELLHOUSE_USER=%q\n' "$SHELLHOUSE_HOST" "$SHELLHOUSE_USER" > "$SHELLHOUSE_STATE_FILE"
  chmod 600 "$SHELLHOUSE_STATE_FILE"
}

# One shared SSH connection for the whole script, so the password (if any) is asked once.
ssh_setup() {
  mkdir -p "$SHELLHOUSE_STATE_DIR" && chmod 700 "$SHELLHOUSE_STATE_DIR"
  SSH_TARGET="$SHELLHOUSE_USER@$SHELLHOUSE_HOST"
  SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=$SHELLHOUSE_STATE_DIR/ssh-%C" -o ControlPersist=900
            -o ConnectTimeout=10 -o ServerAliveInterval=15 -o StrictHostKeyChecking=accept-new)
}
ssh_run()     { ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }
ssh_tty()     { ssh -t "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }
ssh_close()   { ssh "${SSH_OPTS[@]}" -O exit "$SSH_TARGET" >/dev/null 2>&1 || true; }

# Opens the shared connection (asking for the password or key passphrase if needed). Offers to install the
# user's own SSH key on the host so later runs don't ask.
ssh_connect() {
  ssh_setup
  if ssh -o BatchMode=yes "${SSH_OPTS[@]}" "$SSH_TARGET" true 2>/dev/null; then ok "Connected to $SSH_TARGET"; return; fi
  info "Connecting to $SSH_TARGET (enter the password for $SHELLHOUSE_USER if asked)…"
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" true || die "Couldn't connect to $SSH_TARGET over SSH. Check the address, the user, and that sshd is running."
  ok "Connected to $SSH_TARGET"
  if [ "${OFFER_KEY_COPY:-1}" = "1" ] && command -v ssh-copy-id >/dev/null \
     && { [ -f "$HOME/.ssh/id_ed25519.pub" ] || [ -f "$HOME/.ssh/id_rsa.pub" ]; } \
     && confirm "Install your SSH key on the host so you aren't asked for a password next time?" Y; then
    ssh-copy-id -o "ControlPath=$SHELLHOUSE_STATE_DIR/ssh-%C" "$SSH_TARGET" >/dev/null 2>&1 && ok "Your SSH key is installed" || warn "ssh-copy-id didn't work; you'll be asked for the password again next time"
  fi
}

app_installed() { [ -d "$SHELLHOUSE_APP" ]; }
app_running()   { pgrep -x "Shellhouse" >/dev/null 2>&1; }

launch_app() {
  app_running && return 0
  open "$SHELLHOUSE_APP" || return 1
  for _ in $(seq 1 40); do app_running && { sleep 2; return 0; }; sleep 0.5; done
  return 1
}

# Asks the running app for its own SSH public key (shellhouse://ssh-public-key puts it on the clipboard), and
# authorizes it on the host. Your clipboard is put back afterwards. Only the public key ever leaves the app.
authorize_app_key() {
  local saved key=""
  saved="$(pbpaste 2>/dev/null || true)"
  printf '' | pbcopy
  open "shellhouse://ssh-public-key"
  for _ in $(seq 1 40); do
    key="$(pbpaste 2>/dev/null || true)"
    [[ "$key" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+\ $SHELLHOUSE_KEY_COMMENT$ ]] && break
    key=""; sleep 0.25
  done
  printf '%s' "$saved" | pbcopy
  [ -n "$key" ] || { warn "The app didn't hand over its SSH key. In the app: Settings › Linux host › Copy authorize command."; return 1; }
  # The key goes over stdin, not the command line.
  printf '%s\n' "$key" | ssh_run 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; read -r k;
    grep -qxF "$k" ~/.ssh/authorized_keys || printf "%s\n" "$k" >> ~/.ssh/authorized_keys' \
    || { warn "Couldn't add the app's key to ~/.ssh/authorized_keys on the host."; return 1; }
  ok "The app's SSH key is authorized on the host"
}

# Hands the pending settings file (host, user, manager token) to the app, waits for its receipt, then deletes it.
import_pending_settings() {
  [ -f "$SHELLHOUSE_PENDING_SETTINGS" ] || return 0
  open -a "$SHELLHOUSE_APP" "$SHELLHOUSE_PENDING_SETTINGS"
  for _ in $(seq 1 60); do
    if grep -q "shellhouse-settings-receipt" "$SHELLHOUSE_PENDING_SETTINGS" 2>/dev/null; then
      rm -f "$SHELLHOUSE_PENDING_SETTINGS"
      ok "The app has the host address and the sandbox manager token"
      return 0
    fi
    sleep 0.5
  done
  warn "The app didn't confirm the import. The file is still at $SHELLHOUSE_PENDING_SETTINGS (it holds the manager token);"
  warn "open it with Shellhouse, or delete it and paste the token in Settings › Sandbox manager token."
  return 1
}

# Everything the app needs from the host, once it is installed: its SSH key authorized, then the settings.
hand_off_to_app() {
  load_state
  [ -n "$SHELLHOUSE_HOST" ] || return 0
  [ -f "$SHELLHOUSE_PENDING_SETTINGS" ] || return 0
  step "Connecting the app to $SHELLHOUSE_HOST"
  launch_app || { warn "Couldn't start Shellhouse."; return 1; }
  ssh_setup
  OFFER_KEY_COPY=0 ssh_connect
  authorize_app_key || true
  import_pending_settings || true
}

# XML-escapes $1 for a plist <string>.
xml_escape() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; printf '%s' "$s"; }
