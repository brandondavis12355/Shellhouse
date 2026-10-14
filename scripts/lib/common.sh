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
# Host keys these scripts have verified (fingerprint checked against the box itself) and pinned. Only these are
# accepted: a box answering with any other key is refused, so a connection can't be quietly intercepted.
SHELLHOUSE_KNOWN_HOSTS="$SHELLHOUSE_STATE_DIR/known_hosts"

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

# --- Asking the user: macOS dialogs, or Terminal prompts ---------------------------------------------------
# Dialogs unless --no-ui (SHELLHOUSE_UI=0), or there's no screen to show them on (running over SSH).
ui_on() {
  [ "${SHELLHOUSE_UI:-1}" = "1" ] && [ -z "${SSH_CONNECTION:-}" ] && command -v osascript >/dev/null 2>&1
}
UI_TITLE="${UI_TITLE:-Shellhouse setup}"

# Runs an AppleScript with arguments passed separately (no quoting of user text into the script).
_dialog() { osascript - "$@" 2>/dev/null; }

# ask "Question" default  -> prints the answer (the default on Enter, or with --yes). Cancel stops the script.
ask() {
  local question="$1" default="${2:-}" answer
  if [ "${ASSUME_YES:-0}" = "1" ] && [ -n "$default" ]; then printf '%s' "$default"; return; fi
  if ui_on; then
    answer="$(_dialog "$question" "$default" "$UI_TITLE" <<'AS'
on run argv
  set r to display dialog (item 1 of argv) default answer (item 2 of argv) with title (item 3 of argv) buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel" with icon note
  return text returned of r
end run
AS
)" || die "Cancelled."
    printf '%s' "${answer:-$default}"; return
  fi
  if [ -n "$default" ]; then read -r -p "    $question [$default]: " answer </dev/tty; else read -r -p "    $question: " answer </dev/tty; fi
  printf '%s' "${answer:-$default}"
}

# ask_secret "Question"  -> prints what was typed (hidden). Cancel stops the script.
ask_secret() {
  local question="$1" answer
  if ui_on; then
    answer="$(_dialog "$question" "$UI_TITLE" <<'AS'
on run argv
  set r to display dialog (item 1 of argv) default answer "" with hidden answer with title (item 2 of argv) buttons {"Cancel", "OK"} default button "OK" cancel button "Cancel" with icon caution
  return text returned of r
end run
AS
)" || die "Cancelled."
    printf '%s' "$answer"; return
  fi
  read -r -s -p "    $question: " answer </dev/tty; echo >&2
  printf '%s' "$answer"
}

# confirm "Question" [Y|N] [yes-label] [no-label]  -> exit status 0 for yes
confirm() {
  local question="$1" default="${2:-Y}" yes="${3:-Yes}" no="${4:-No}" answer hint="[Y/n]"
  [ "$default" = "N" ] && hint="[y/N]"
  if [ "${ASSUME_YES:-0}" = "1" ]; then [ "$default" = "Y" ]; return; fi
  if ui_on; then
    local pick; pick="$([ "$default" = "Y" ] && printf '%s' "$yes" || printf '%s' "$no")"
    answer="$(_dialog "$question" "$UI_TITLE" "$no" "$yes" "$pick" <<'AS'
on run argv
  set r to display dialog (item 1 of argv) with title (item 2 of argv) buttons {item 3 of argv, item 4 of argv} default button (item 5 of argv) with icon note
  return button returned of r
end run
AS
)" || return 1
    [ "$answer" = "$yes" ]; return
  fi
  read -r -p "    $question $hint " answer </dev/tty
  answer="${answer:-$default}"
  case "$answer" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# notify "Message": a one-line dialog (UI) or a line in Terminal.
notify() {
  if ui_on && [ "${ASSUME_YES:-0}" != "1" ]; then
    _dialog "$1" "$UI_TITLE" >/dev/null <<'AS' || true
on run argv
  display dialog (item 1 of argv) with title (item 2 of argv) buttons {"OK"} default button "OK" with icon note
end run
AS
  else
    info "$1"
  fi
}

# SSH sign-in passwords and key passphrases asked for in a dialog too (ssh's askpass), when the UI is on.
setup_ssh_askpass() {
  ui_on || return 0
  local helper="$SHELLHOUSE_STATE_DIR/askpass"
  mkdir -p "$SHELLHOUSE_STATE_DIR" && chmod 700 "$SHELLHOUSE_STATE_DIR"
  cat > "$helper" <<'SH'
#!/bin/sh
# ssh calls this with its prompt ("user@host's password:"); the answer goes to ssh on stdout, nowhere else.
osascript - "$1" <<'AS'
on run argv
  set r to display dialog (item 1 of argv) default answer "" with hidden answer with title "Shellhouse setup" buttons {"Cancel", "OK"} default button "OK" cancel button "Cancel" with icon caution
  return text returned of r
end run
AS
SH
  chmod 700 "$helper"
  export SSH_ASKPASS="$helper" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}"
}

valid_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || [[ "$1" =~ ^[0-9a-fA-F:]+$ ]]; }
valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_.-]*$ ]]; }

load_state() {
  SHELLHOUSE_HOST=""; SHELLHOUSE_USER=""; SHELLHOUSE_PREV_HOST=""; SHELLHOUSE_PREV_USER=""
  # shellcheck disable=SC1090
  [ -f "$SHELLHOUSE_STATE_FILE" ] && . "$SHELLHOUSE_STATE_FILE"
  return 0
}

save_state() {
  mkdir -p "$SHELLHOUSE_STATE_DIR" && chmod 700 "$SHELLHOUSE_STATE_DIR"
  printf 'SHELLHOUSE_HOST=%q\nSHELLHOUSE_USER=%q\nSHELLHOUSE_PREV_HOST=%q\nSHELLHOUSE_PREV_USER=%q\n' \
    "$SHELLHOUSE_HOST" "$SHELLHOUSE_USER" "${SHELLHOUSE_PREV_HOST:-}" "${SHELLHOUSE_PREV_USER:-}" > "$SHELLHOUSE_STATE_FILE"
  chmod 600 "$SHELLHOUSE_STATE_FILE"
}

# One shared SSH connection for the whole script, so the password (if any) is asked once.
ssh_setup() {
  mkdir -p "$SHELLHOUSE_STATE_DIR" && chmod 700 "$SHELLHOUSE_STATE_DIR"
  setup_ssh_askpass
  SSH_TARGET="$SHELLHOUSE_USER@$SHELLHOUSE_HOST"
  SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=$SHELLHOUSE_STATE_DIR/ssh-%C" -o ControlPersist=900
            -o ConnectTimeout=10 -o ServerAliveInterval=15
            -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$SHELLHOUSE_KNOWN_HOSTS" -o GlobalKnownHostsFile=/dev/null)
}
ssh_run()     { ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }
ssh_tty()     { ssh -t "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }
ssh_close()   { ssh "${SSH_OPTS[@]}" -O exit "$SSH_TARGET" >/dev/null 2>&1 || true; }

# Makes sure the box's host key is the real one before anything is sent to it, then pins it.
#   - Already pinned by an earlier run: used as is (and a different key is refused by ssh itself).
#   - Already trusted in your own ~/.ssh/known_hosts: it must match, then it's pinned.
#   - New: you compare its fingerprint with what the box itself shows (or pass --host-fingerprint SHA256:…).
# $1 = host. Sets SHELLHOUSE_PINNED_KEYS to the pinned known_hosts lines.
verify_host_key() {
  local host="$1" scanned fingerprints yours match line answer
  mkdir -p "$SHELLHOUSE_STATE_DIR" && chmod 700 "$SHELLHOUSE_STATE_DIR"; touch "$SHELLHOUSE_KNOWN_HOSTS"; chmod 600 "$SHELLHOUSE_KNOWN_HOSTS"
  if ssh-keygen -F "$host" -f "$SHELLHOUSE_KNOWN_HOSTS" >/dev/null 2>&1; then
    SHELLHOUSE_PINNED_KEYS="$(ssh-keygen -F "$host" -f "$SHELLHOUSE_KNOWN_HOSTS" | grep -v '^#')"
    ok "Host key for $host is pinned from an earlier check"
    return 0
  fi
  scanned="$(ssh-keyscan -T 8 -t ed25519,ecdsa,rsa "$host" 2>/dev/null | grep -v '^#' || true)"
  [ -n "$scanned" ] || die "Couldn't read $host's SSH host key (is sshd running and port 22 reachable?)."
  fingerprints="$(printf '%s
' "$scanned" | ssh-keygen -lf - 2>/dev/null)"
  # Your own Mac may already trust this box: then the key has to be that one.
  yours="$(ssh-keygen -F "$host" -f "$HOME/.ssh/known_hosts" 2>/dev/null | grep -v '^#' || true)"
  match=0
  if [ -n "$yours" ]; then
    while IFS= read -r line; do
      blob="$(printf '%s' "$line" | awk '{print $2" "$3}')"
      printf '%s
' "$yours" | awk '{print $2" "$3}' | grep -qxF "$blob" && match=1
    done <<< "$scanned"
    if [ "$match" = "1" ]; then
      ok "$host's host key matches the one your Mac already trusts"
    else
      die "$host answered with a DIFFERENT host key than the one your Mac trusted before. Someone may be intercepting the
       connection, or the box was reinstalled. Check on the box itself (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub);
       if it was reinstalled, remove the old entry with:  ssh-keygen -R $host   and run this again."
    fi
  elif [ -n "${HOST_FINGERPRINT:-}" ]; then
    printf '%s
' "$fingerprints" | awk '{print $2}' | grep -qxF "$HOST_FINGERPRINT" \
      || die "$host's host key doesn't match --host-fingerprint $HOST_FINGERPRINT. Nothing was sent to it."
    ok "$host's host key matches --host-fingerprint"
  else
    [ "${ASSUME_YES:-0}" = "1" ] && die "With --yes, pass --host-fingerprint SHA256:… (from the box: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub) so the box can be verified without asking."
    info "First connection to $host. To be sure nobody is intercepting it, compare its fingerprint with what the box"
    info "itself shows. On the box's own screen (or a console you trust), run:"
    info "    ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
    info "$host answered with:"
    printf '%s
' "$fingerprints" | grep -i ed25519 | awk '{print "        " $2 "  (" $NF ")"}'
    printf '%s
' "$fingerprints" | grep -iv ed25519 | awk '{print "        " $2 "  (" $NF ")"}'
    local shown; shown="$(printf '%s\n' "$fingerprints" | grep -i ed25519 | awk '{print $2}' | head -1)"
    confirm "First connection to $host. To make sure nobody is intercepting it, on the box's own screen (or a console you trust) run:

    ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub

Does it show this fingerprint?

    ${shown:-$(printf '%s\n' "$fingerprints" | awk 'NR==1{print $2}')}" N "It matches" "It doesn't match" \
      || die "Not confirmed; nothing was sent to $host."
  fi
  ssh-keygen -R "$host" -f "$SHELLHOUSE_KNOWN_HOSTS" >/dev/null 2>&1 || true
  rm -f "$SHELLHOUSE_KNOWN_HOSTS.old"
  printf '%s
' "$scanned" >> "$SHELLHOUSE_KNOWN_HOSTS"
  SHELLHOUSE_PINNED_KEYS="$scanned"
  ok "Pinned $host's host key; from now on only this key is accepted"
}

# Opens the shared connection (asking for the password or key passphrase if needed). Offers to install the
# user's own SSH key on the host so later runs don't ask.
ssh_connect() {
  verify_host_key "$SHELLHOUSE_HOST"
  ssh_setup
  if ssh -o BatchMode=yes "${SSH_OPTS[@]}" "$SSH_TARGET" true 2>/dev/null; then ok "Connected to $SSH_TARGET"; return; fi
  info "Connecting to $SSH_TARGET (enter the password for $SHELLHOUSE_USER if asked)…"
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" true || die "Couldn't connect to $SSH_TARGET over SSH. Check the address, the user, and that sshd is running."
  ok "Connected to $SSH_TARGET"
  if [ "${OFFER_KEY_COPY:-1}" = "1" ] && command -v ssh-copy-id >/dev/null \
     && { [ -f "$HOME/.ssh/id_ed25519.pub" ] || [ -f "$HOME/.ssh/id_rsa.pub" ]; } \
     && confirm "Install your SSH key on the host so you aren't asked for a password next time?" Y; then
    ssh-copy-id -o "ControlPath=$SHELLHOUSE_STATE_DIR/ssh-%C" -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$SHELLHOUSE_KNOWN_HOSTS" \
      "$SSH_TARGET" >/dev/null 2>&1 && ok "Your SSH key is installed" || warn "ssh-copy-id didn't work; you'll be asked for the password again next time"
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
  # The key goes over stdin, not the command line. It is authorized with `restrict` (no shell, no pty, no agent or
  # X11 forwarding) plus port forwarding, and a forced command: it may only run scripts/app-ssh-command.sh's two
  # status checks. (No permitopen: OpenSSH checks socket forwards against that list too, and a socket path can't
  # be listed, so it would block the manager connection.)
  printf '%s\n' "$key" | ssh_run 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; read -r k
    case "$k" in "ssh-ed25519 "*" shellhouse-app") ;; *) echo "unexpected key" >&2; exit 1 ;; esac
    dir="$HOME/shellhouse"
    opts="restrict,port-forwarding"
    listen=$(sed -n "s/^[[:space:]]*PermitListen[[:space:]]\{1,\}//p" /etc/ssh/sshd_config.d/50-shellhouse-model-proxy.conf 2>/dev/null | head -1)
    [ -n "$listen" ] && opts="$opts,permitlisten=\"$listen\""
    chmod 755 "$dir/scripts/app-ssh-command.sh"
    opts="$opts,command=\"$dir/scripts/app-ssh-command.sh\""
    tmp=$(mktemp); grep -v " shellhouse-app$" ~/.ssh/authorized_keys > "$tmp" || true
    printf "%s %s\n" "$opts" "$k" >> "$tmp"; cat "$tmp" > ~/.ssh/authorized_keys; rm -f "$tmp"' \
    || { warn "Couldn't add the app's key to ~/.ssh/authorized_keys on the host."; return 1; }
  ok "The app's SSH key is authorized on the host, limited to the tunnel and its status checks"
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
