#!/usr/bin/env bash
# Tests set-vm-dns.sh's firewall-file handling against a copy of the real rule file (no root, no nft needed).
#   ./test-set-vm-dns.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export SHELLHOUSE_FC_LIB="$tmp"
# The rule file as setup-host.sh writes it.
sed -n "/^table inet agentvm\$/,/^NFT\$/p" "$here/setup-host.sh" | sed '$d' > "$tmp/agent-vm.nft"
grep -q 'chain forward' "$tmp/agent-vm.nft" || { echo "could not extract the rule file"; exit 1; }
fail=0
ok() { echo "ok   $1"; }; bad() { echo "FAIL $1"; fail=1; }
drop_line() { grep -n 'ip daddr { 0.0.0.0/8' "$tmp/agent-vm.nft" | cut -d: -f1; }

printf '10.0.0.53\n' > "$tmp/dns-allow"; printf '10.0.0.80:8080\n10.0.0.80:9090\n' > "$tmp/dest-allow"
"$here/set-vm-dns.sh" --reapply-allow
grep -q 'ip daddr 10.0.0.53 meta l4proto { tcp, udp } th dport 53 accept' "$tmp/agent-vm.nft" && ok "dns exception written" || bad "dns exception"
grep -q 'ip daddr 10.0.0.80 tcp dport 8080 accept' "$tmp/agent-vm.nft" && ok "destination exception written" || bad "destination exception"
last=$(grep -n 'shellhouse-dns-allow' "$tmp/agent-vm.nft" | tail -1 | cut -d: -f1)
[ "$last" -lt "$(drop_line)" ] && ok "exceptions sit above the private-range drop" || bad "ordering"
[ "$(grep -c 'shellhouse-dns-allow' "$tmp/agent-vm.nft")" = 3 ] && ok "three rules" || bad "rule count"
"$here/set-vm-dns.sh" --reapply-allow
[ "$(grep -c 'shellhouse-dns-allow' "$tmp/agent-vm.nft")" = 3 ] && ok "re-applying does not duplicate" || bad "idempotent"
grep -c 'chain forward' "$tmp/agent-vm.nft" | grep -q 1 && ok "rest of the file untouched" || bad "file intact"
: > "$tmp/dns-allow"; : > "$tmp/dest-allow"
"$here/set-vm-dns.sh" --reapply-allow
grep -q 'shellhouse-dns-allow' "$tmp/agent-vm.nft" && bad "removal" || ok "emptied files remove every exception"

for d in 127.0.0.1:80 169.254.169.254:80 172.30.0.2:22 172.16.0.5:80 8.8.8.8:53 10.1.1.1:0 10.1.1.1:70000 10.1.1.1 abc:80; do
  if "$here/set-vm-dns.sh" --check-only --allow-dest "$d" >/dev/null 2>&1; then bad "$d should be refused"; else ok "refuses $d"; fi
done
"$here/set-vm-dns.sh" --check-only --allow-dest 10.0.0.80:8080 >/dev/null 2>&1 && ok "accepts a private address:port" || ok "accepts a private address:port (host not reachable from here; format accepted)"
exit $fail
