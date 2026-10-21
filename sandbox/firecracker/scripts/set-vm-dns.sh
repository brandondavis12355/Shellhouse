#!/usr/bin/env bash
# Fixes DNS inside the Firecracker VMs. Run on the Linux host, as root. Idempotent.
#
#   sudo ./set-vm-dns.sh                          # pick the first public resolver that works from this host
#   sudo ./set-vm-dns.sh --dns 8.8.8.8            # use this one (checked first; refused if it does not answer)
#   sudo ./set-vm-dns.sh --allow-private          # also consider this host's own (private) resolvers
#   sudo ./set-vm-dns.sh --dns 10.1.2.3 --allow-private
#   ./set-vm-dns.sh --check-only                  # test the candidates, change nothing
#
# A VM uses one resolver, `FIRECRACKER_DNS` (default 1.1.1.1). On a corporate network that address is often blocked, so
# every lookup in every VM times out. This script finds a resolver that answers from this host, writes it to the
# manager's settings and restarts the manager. VMs read it at boot, so a running VM keeps its old resolver until it
# is restarted (stopping the manager stops them; each boots again on first use).
#
# A PRIVATE resolver (RFC 1918 and similar) is blocked from the VMs by design, so using one also adds a firewall
# exception for that one address, UDP/TCP 53 only. That loosens VM isolation: it needs --allow-private and, in a
# company, a nod from your security team. The exception is kept in $LIB/dns-allow and re-applied by setup-host.sh.
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail

LIB=/usr/local/lib/shellhouse-firecracker
ALLOW_FILE="$LIB/dns-allow"
NFT_FILE="$LIB/agent-vm.nft"
MARK="# shellhouse-dns-allow"
ENV_FILES=(/etc/agent-sandbox-manager.env)
SERVICE=agent-sandbox-manager
NET_SERVICE=shellhouse-vm-net

WANT="" ALLOW_PRIVATE=0 CHECK_ONLY=0 REAPPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dns) WANT="${2:?--dns needs an address}"; shift 2 ;;
    --allow-private) ALLOW_PRIVATE=1; shift ;;
    --check-only) CHECK_ONLY=1; shift ;;
    --reapply-allow) REAPPLY=1; shift ;;   # used by setup-host.sh after it rewrites the firewall file
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
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

# The nftables rule file is rewritten by setup-host.sh; the exception is kept in $ALLOW_FILE and put back here.
apply_allow() {
  [ -f "$NFT_FILE" ] || { echo "no $NFT_FILE: run setup-host.sh first" >&2; return 1; }
  sed -i "/$MARK/d" "$NFT_FILE"
  [ -s "$ALLOW_FILE" ] || return 0
  local ip rules=""
  while read -r ip; do
    is_ipv4 "$ip" || continue
    rules+="        iifname \"fctap*\" ip daddr $ip meta l4proto { tcp, udp } th dport 53 accept $MARK\n"
  done < "$ALLOW_FILE"
  # Above the rule that drops private ranges, so the exception wins for that address and port only.
  sed -i "0,/iifname \"fctap\*\" ip daddr {/s//${rules//\//\\/}&/" "$NFT_FILE"
}

if [ "$REAPPLY" = 1 ]; then apply_allow; exit $?; fi
if [ "$CHECK_ONLY" = 0 ] && [ $EUID -ne 0 ]; then exec sudo "$0" "$@"; fi

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
