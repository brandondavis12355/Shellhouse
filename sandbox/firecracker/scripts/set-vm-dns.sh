#!/usr/bin/env bash
# Fixes DNS inside the Firecracker VMs. Run on the Linux host, as root. Idempotent.
#
#   sudo ./set-vm-dns.sh                          # pick the first public resolver that works from this host
#   sudo ./set-vm-dns.sh --dns 8.8.8.8            # use this one (checked first; refused if it does not answer)
#   sudo ./set-vm-dns.sh --allow-private          # also consider this host's own (private) resolvers
#   sudo ./set-vm-dns.sh --dns 10.1.2.3 --allow-private
#   ./set-vm-dns.sh --check-only                  # test the candidates, change nothing
#
#   sudo ./set-vm-dns.sh --allow-dest 10.12.132.170:3005   # let VMs open connections to that one address and port
#   sudo ./set-vm-dns.sh --remove-dest 10.12.132.170:3005  # take it away again
#   ./set-vm-dns.sh --check-only --allow-dest 10.12.132.170:3005   # can THIS host reach it? (changes nothing)
#   (--allow-dest / --remove-dest alone leave DNS as it is; add --dns to change that too.)
#
# A VM uses one resolver, `FIRECRACKER_DNS` (default 1.1.1.1). On a corporate network that address is often blocked, so
# every lookup in every VM times out. This script finds a resolver that answers from this host, writes it to the
# manager's settings and restarts the manager. VMs read it at boot, so a running VM keeps its old resolver until it
# is restarted (stopping the manager stops them; each boots again on first use).
#
# VMs cannot open connections to private addresses at all, so even a name that resolves cannot be reached. --allow-dest
# adds an exception for ONE address and ONE port (private ranges only: 10/8, 192.168/16, 100.64/10; never loopback,
# link-local/metadata, other VMs or Docker networks). Each one lets a VM, including a misused one, talk to that service:
# get your security team's approval first. Kept in $LIB/dest-allow and re-applied by setup-host.sh.
#
# A PRIVATE resolver (RFC 1918 and similar) is blocked from the VMs by design, so using one also adds a firewall
# exception for that one address, UDP/TCP 53 only. That loosens VM isolation: it needs --allow-private and, in a
# company, a nod from your security team. The exception is kept in $LIB/dns-allow and re-applied by setup-host.sh.
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail

LIB="${SHELLHOUSE_FC_LIB:-/usr/local/lib/shellhouse-firecracker}"
ALLOW_FILE="$LIB/dns-allow"
DEST_FILE="$LIB/dest-allow"
NFT_FILE="$LIB/agent-vm.nft"
MARK="# shellhouse-dns-allow"
ENV_FILES=(/etc/agent-sandbox-manager.env)
SERVICE=agent-sandbox-manager
NET_SERVICE=shellhouse-vm-net

WANT="" ALLOW_PRIVATE=0 CHECK_ONLY=0 REAPPLY=0 DEST_ADD=() DEST_DEL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dns) WANT="${2:?--dns needs an address}"; shift 2 ;;
    --allow-private) ALLOW_PRIVATE=1; shift ;;
    --check-only) CHECK_ONLY=1; shift ;;
    --allow-dest) DEST_ADD+=("${2:?--allow-dest needs ADDRESS:PORT}"); shift 2 ;;
    --remove-dest) DEST_DEL+=("${2:?--remove-dest needs ADDRESS:PORT}"); shift 2 ;;
    --reapply-allow) REAPPLY=1; shift ;;   # used by setup-host.sh after it rewrites the firewall file
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ! [[ "$1" =~ (^|\.)(25[6-9]|2[6-9][0-9]|[3-9][0-9]{2})(\.|$) ]]; }
is_private() { [[ "$1" =~ ^(0\.|10\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|22[4-9]\.|2[3-5][0-9]\.) ]]; }

# Does $1 answer an A query for example.com within 2 s? (Raw UDP from python3, which the manager needs anyway.)
answers() {
  python3 - "$1" <<'PY'
import socket, struct, sys
q = struct.pack(">HHHHHH", 0x5348, 0x0100, 1, 0, 0, 0) + b"\x07example\x03com\x00" + struct.pack(">HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2)
try:
    s.sendto(q, (sys.argv[1], 53)); r, _ = s.recvfrom(512)
    ok = len(r) >= 12 and r[:2] == q[:2] and (r[3] & 0x0F) == 0 and struct.unpack(">H", r[6:8])[0] > 0
except Exception:
    ok = False
sys.exit(0 if ok else 1)
PY
}

# The nftables rule file is rewritten by setup-host.sh; the exceptions are kept in $ALLOW_FILE (DNS servers) and
# $DEST_FILE (address:port) and put back here.
apply_allow() {
  [ -f "$NFT_FILE" ] || { echo "no $NFT_FILE: run setup-host.sh first" >&2; return 1; }
  local ip port rules="" tmp; tmp="$(mktemp)"
  if [ -s "$ALLOW_FILE" ]; then
    while read -r ip; do
      is_ipv4 "$ip" || continue
      rules+="        iifname \"fctap*\" ip daddr $ip meta l4proto { tcp, udp } th dport 53 accept $MARK"$'\n'
    done < "$ALLOW_FILE"
  fi
  if [ -s "$DEST_FILE" ]; then
    while IFS=: read -r ip port; do
      is_ipv4 "$ip" && [[ "$port" =~ ^[0-9]{1,5}$ ]] || continue
      rules+="        iifname \"fctap*\" ip daddr $ip tcp dport $port accept $MARK"$'\n'
    done < "$DEST_FILE"
  fi
  # Our old lines out; the new ones in above the rule that drops private ranges, so an exception wins for that
  # address and port only. (awk and grep, not GNU-only sed, so this behaves the same everywhere.)
  local rf; rf="$(mktemp)"; printf '%s' "$rules" > "$rf"
  grep -vF "$MARK" "$NFT_FILE" | awk -v rf="$rf" '!done && /iifname "fctap\*" ip daddr \{/ { while ((getline line < rf) > 0) print line; done = 1 } { print }' > "$tmp"
  rm -f "$rf"
  cat "$tmp" > "$NFT_FILE"; rm -f "$tmp"
}

# An address:port that may be opened: one private IPv4 and a port, nothing that reaches the host, other VMs or metadata.
valid_dest() {
  local ip="${1%%:*}" port="${1##*:}"
  is_ipv4 "$ip" && [[ "$port" =~ ^[0-9]{1,5}$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
  [[ "$ip" =~ ^(10\.|192\.168\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]] || return 1
  [[ "$ip" =~ ^172\.30\. ]] && return 1
  return 0
}

if [ "$REAPPLY" = 1 ]; then apply_allow; exit $?; fi
if [ "$CHECK_ONLY" = 0 ] && [ $EUID -ne 0 ]; then exec sudo "$0" "$@"; fi

if [ ${#DEST_ADD[@]} -gt 0 ] || [ ${#DEST_DEL[@]} -gt 0 ]; then
  for d in ${DEST_ADD[@]+"${DEST_ADD[@]}"} ${DEST_DEL[@]+"${DEST_DEL[@]}"}; do
    valid_dest "$d" || { echo "'$d' is not allowed: use ADDRESS:PORT with a private 10.x / 192.168.x / 100.64-127.x address" >&2; exit 2; }
  done
  if [ "$CHECK_ONLY" = 1 ]; then
    for d in ${DEST_ADD[@]+"${DEST_ADD[@]}"}; do
      if (exec 3<>"/dev/tcp/${d%%:*}/${d##*:}") 2>/dev/null; then echo "  $d   reachable from this host"; else echo "  $d   NOT reachable from this host (no firewall change on the VMs would help)"; fi
    done
    [ -z "$WANT" ] && exit 0
  else
    touch "$DEST_FILE"
    for d in ${DEST_DEL[@]+"${DEST_DEL[@]}"}; do grep -vxF "$d" "$DEST_FILE" > "$DEST_FILE.new" || true; mv -f "$DEST_FILE.new" "$DEST_FILE"; done
    for d in ${DEST_ADD[@]+"${DEST_ADD[@]}"}; do grep -qxF "$d" "$DEST_FILE" || echo "$d" >> "$DEST_FILE"; done
    apply_allow
    systemctl restart "$NET_SERVICE" 2>/dev/null || nft -f "$NFT_FILE"
    echo "Firewall: VMs may open connections to:"; sed 's/^/  /' "$DEST_FILE"
    [ -z "$WANT" ] && { echo "(Takes effect at once for running VMs; DNS was not changed.)"; exit 0; }
  fi
fi

# Candidates, in the order they are tried.
candidates=()
if [ -n "$WANT" ]; then
  is_ipv4 "$WANT" || { echo "--dns must be an IPv4 address" >&2; exit 2; }
  candidates=("$WANT")
else
  candidates=(1.1.1.1 8.8.8.8 9.9.9.9)
  if [ "$ALLOW_PRIVATE" = 1 ]; then
    host_resolvers="$( { resolvectl dns 2>/dev/null | tr ' ' '\n'; sed -n 's/^nameserver[[:space:]]*//p' /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null; } | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | awk '!seen[$0]++' || true)"
    while read -r r; do [ -n "$r" ] && candidates+=("$r"); done <<< "$host_resolvers"
  fi
fi

echo "Testing resolvers from this host (example.com, 2 s each):"
chosen=""
for ip in "${candidates[@]}"; do
  if is_private "$ip" && [ "$ALLOW_PRIVATE" = 0 ]; then
    echo "  $ip   private address: skipped (needs --allow-private, see the header of this script)"; continue
  fi
  if answers "$ip"; then echo "  $ip   answers"; [ -z "$chosen" ] && chosen="$ip"; else echo "  $ip   no answer"; fi
done

if [ -z "$chosen" ]; then
  echo
  echo "No resolver answered from this host. Nothing was changed." >&2
  echo "If this network only allows its own DNS server, run again with --allow-private (and ask your security team first)." >&2
  exit 3
fi
echo "Using $chosen"
[ "$CHECK_ONLY" = 1 ] && exit 0

for f in "${ENV_FILES[@]}"; do
  [ -f "$f" ] || { echo "missing $f (is the manager installed on this host?)" >&2; exit 1; }
  if grep -q '^FIRECRACKER_DNS=' "$f"; then sed -i "s/^FIRECRACKER_DNS=.*/FIRECRACKER_DNS=$chosen/" "$f"; else echo "FIRECRACKER_DNS=$chosen" >> "$f"; fi
done
# The source install-manager.sh rebuilds that file from: the user's stack .env.
for env in /home/*/shellhouse/.env; do
  [ -f "$env" ] || continue
  if grep -q '^FIRECRACKER_DNS=' "$env"; then sed -i "s/^FIRECRACKER_DNS=.*/FIRECRACKER_DNS=$chosen/" "$env"; else echo "FIRECRACKER_DNS=$chosen" >> "$env"; fi
done

if is_private "$chosen"; then
  echo "$chosen" > "$ALLOW_FILE"
  apply_allow
  systemctl restart "$NET_SERVICE" 2>/dev/null || nft -f "$NFT_FILE"
  echo "Firewall: VMs may now reach $chosen on port 53 only (and nothing else private)."
else
  rm -f "$ALLOW_FILE"; apply_allow || true
  systemctl restart "$NET_SERVICE" 2>/dev/null || true
fi

systemctl restart "$SERVICE"
echo
echo "Done. Restarting the manager stopped the VMs; each boots again, with DNS $chosen, the next time a bot uses it."
echo "Check from a bot:  getent hosts example.com"
