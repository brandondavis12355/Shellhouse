#!/usr/bin/env bash
# Lets the Mac app's reverse SSH forward (the smolagents model proxy) bind on the
# Docker bridge gateway of THIS Linux host, so sandbox containers can reach it —
# and nothing else.
#
# What it does: writes ONE sshd drop-in, /etc/ssh/sshd_config.d/50-shellhouse-model-proxy.conf:
#
#     Match User <you>
#         GatewayPorts clientspecified
#         PermitListen <bridge-gateway>:<port>
#         ClientAliveInterval 15
#         ClientAliveCountMax 3
#
# then validates the whole sshd config and reloads sshd (a reload keeps existing
# SSH sessions alive). If validation fails, the drop-in is removed again.
#
# Run it ON the Linux host:
#     bash enable-model-proxy-forward.sh --dry-run     # look, change nothing, no sudo needed
#     bash enable-model-proxy-forward.sh               # apply (asks for sudo + confirmation)
#     bash enable-model-proxy-forward.sh --uninstall   # remove it again
#
# Options:
#     --user NAME     SSH user the Mac connects as            (default: you)
#     --bind ADDR     address to allow (private IPv4)         (default: docker bridge gateway)
#     --port N        port to allow                           (default: 18434)
#     --yes           don't ask for confirmation
#     --dry-run       print what would happen; change nothing
#     --uninstall     remove the drop-in and reload sshd
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail

DROPIN="/etc/ssh/sshd_config.d/50-shellhouse-model-proxy.conf"
USER_NAME="${SUDO_USER:-${USER:-$(id -un)}}"
BIND=""
PORT="18434"
ASSUME_YES=0
DRY_RUN=0
UNINSTALL=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user)      USER_NAME="${2:?--user needs a value}"; shift 2 ;;
    --bind)      BIND="${2:?--bind needs a value}"; shift 2 ;;
    --port)      PORT="${2:?--port needs a value}"; shift 2 ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- validation helpers -------------------------------------------------------
is_private_ipv4() {
  local ip="$1" a b c d
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}; c=${BASH_REMATCH[3]}; d=${BASH_REMATCH[4]}
  # canonical dotted quad only (no leading zeros), each octet 0-255
  for o in "$a" "$b" "$c" "$d"; do
    [ "$o" -le 255 ] 2>/dev/null || return 1
    [ "$o" = "$((10#$o))" ] || return 1
  done
  [ "$a.$b.$c.$d" != "0.0.0.0" ] || return 1
  [ "$a" -eq 10 ] && return 0
  [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0
  [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 0
  return 1
}

[[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "refusing unusual user name: '$USER_NAME'"
[[ "$PORT" =~ ^[0-9]{4,5}$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || die "port must be 1024-65535 (got '$PORT')"
id "$USER_NAME" >/dev/null 2>&1 || die "no such user: $USER_NAME"

# --- uninstall ------------------------------------------------------------------
service_name() { systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service' && echo ssh || echo sshd; }

if [ "$UNINSTALL" -eq 1 ]; then
  step "Uninstall"
  [ -e "$DROPIN" ] || { say "Nothing to do: $DROPIN does not exist."; exit 0; }
  say "Would remove $DROPIN and reload sshd."
  [ "$DRY_RUN" -eq 1 ] && exit 0
  [ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
  rm -f -- "$DROPIN"
  sshd -t || die "sshd config does not validate after removal; check /etc/ssh manually"
  systemctl reload "$(service_name)"
  say "Removed and reloaded."
  exit 0
fi

# --- checks (all read-only) -------------------------------------------------------
step "Checking this host"

if [ -z "$BIND" ]; then
  command -v docker >/dev/null 2>&1 || die "docker not found; pass --bind <bridge gateway address>"
  BIND="$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
  [ -n "$BIND" ] || die "could not read the docker bridge gateway; pass --bind"
  say "Docker bridge gateway (auto-detected): $BIND"
else
  say "Bind address (given): $BIND"
fi
is_private_ipv4 "$BIND" || die "'$BIND' is not a specific private IPv4 address (wildcards and public addresses are refused)"

grep -Eq '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
  || die "/etc/ssh/sshd_config has no 'Include /etc/ssh/sshd_config.d/*.conf' line; this script only adds a drop-in file and will not edit the main config"

ver_line="$(sshd -V 2>&1 | head -1 || true)"
ver="$(printf '%s' "$ver_line" | sed -n 's/.*OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\1.\2/p')"
if [ -n "$ver" ]; then
  major="${ver%%.*}"; minor="${ver##*.}"
  if [ "$major" -lt 7 ] || { [ "$major" -eq 7 ] && [ "$minor" -lt 8 ]; }; then
    die "OpenSSH $ver is too old for PermitListen (needs 7.8+)"
  fi
  say "OpenSSH $ver: PermitListen supported"
else
  say "Could not parse the OpenSSH version ($ver_line); continuing, 'sshd -t' will catch problems."
fi

if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${PORT}\$"; then
  say "NOTE: something is already listening on port $PORT (fine if it is a previous forward)."
fi

CONTENT="# Added by enable-model-proxy-forward.sh: lets the Mac app's reverse SSH forward
# (smolagents model proxy) bind on the Docker bridge gateway, and nowhere else.
Match User ${USER_NAME}
    GatewayPorts clientspecified
    PermitListen ${BIND}:${PORT}
    # A dead tunnel session is reaped in ~45 s, so a stale one cannot keep the forwarded port busy for hours.
    ClientAliveInterval 15
    ClientAliveCountMax 3
"

step "Planned change"
say "File:    $DROPIN"
say "Reload:  sshd (existing SSH sessions keep running)"
say "Content:"
printf '%s' "$CONTENT" | sed 's/^/    /'
if [ -e "$DROPIN" ]; then
  if [ "$(cat "$DROPIN")" = "$(printf '%s' "$CONTENT")" ]; then
    say; say "Already installed with exactly this content; nothing to change."
    NOOP=1
  else
    say; say "A different $DROPIN exists and will be replaced (the old one is backed up)."
  fi
fi
NOOP="${NOOP:-0}"

if [ "$DRY_RUN" -eq 1 ]; then
  say; say "Dry run: nothing was changed."
  exit 0
fi

# --- apply -------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  say; say "This needs root; re-running with sudo..."
  exec sudo -- "$0" --user "$USER_NAME" --bind "$BIND" --port "$PORT" $( [ "$ASSUME_YES" -eq 1 ] && echo --yes )
fi

if [ "$NOOP" -eq 0 ] && [ "$ASSUME_YES" -ne 1 ]; then
  printf '\nApply this change? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes|YES) ;; *) say "Cancelled; nothing changed."; exit 0 ;; esac
fi

step "Applying"
BACKUP=""
if [ -e "$DROPIN" ]; then
  BACKUP="${DROPIN}.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p -- "$DROPIN" "$BACKUP"
  say "Backed up existing file to $BACKUP"
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
printf '%s' "$CONTENT" > "$TMP"
install -m 0644 -o root -g root "$TMP" "$DROPIN"

rollback() {
  say "Rolling back..."
  if [ -n "$BACKUP" ]; then cp -p -- "$BACKUP" "$DROPIN"; else rm -f -- "$DROPIN"; fi
}

if ! sshd -t; then
  rollback
  die "sshd rejected the new configuration; the change was rolled back and sshd was NOT reloaded"
fi
say "sshd -t: configuration is valid"

systemctl reload "$(service_name)" || { rollback; sshd -t && systemctl reload "$(service_name)" || true; die "reload failed; rolled back"; }
say "sshd reloaded"

# --- verify ------------------------------------------------------------------------
step "Verifying (effective settings for user ${USER_NAME})"
eff="$(sshd -T -C "user=${USER_NAME},host=localhost,addr=127.0.0.1" 2>/dev/null | grep -Ei '^(gatewayports|permitlisten|allowtcpforwarding|clientaliveinterval|clientalivecountmax) ' || true)"
printf '%s\n' "$eff" | sed 's/^/    /'
printf '%s' "$eff" | grep -qi "gatewayports clientspecified" || die "GatewayPorts is not 'clientspecified' for $USER_NAME; check for conflicting Match blocks"
printf '%s' "$eff" | grep -qi "permitlisten ${BIND}:${PORT}" || die "PermitListen is not '${BIND}:${PORT}' for $USER_NAME; check for conflicting Match blocks"

step "Done"
say "Next, in the Mac app: Settings > Agent engine"
say "    Docker bridge address: ${BIND}"
say "    Proxy port:            ${PORT}"
say "    then 'Save & reconnect'."
say
say "Check it afterwards on this host:   ss -ltn | grep ${PORT}     (should show ${BIND}:${PORT})"
say "Undo any time:                      bash $0 --uninstall"
