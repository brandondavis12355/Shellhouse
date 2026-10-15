#!/usr/bin/env bash
# Runs ON the Linux host (initial_setup.sh --rotate-token copies it to /tmp and runs it). Generates a new random
# sandbox manager token, writes it everywhere the manager reads it (.env, and with Firecracker the service's own
# settings), restarts only the manager (Docker bots keep running), and then CHECKS it: the manager must accept the
# new token and refuse the old one, so a token that is out of step between .env and the running manager (the cause
# of "401 Unauthorized" in the app) is repaired, or reported, instead of silently staying wrong. The new token is
# never printed; initial_setup.sh reads it from .env straight into the app's settings file.
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail
cd "$HOME/shellhouse" || { echo "No ~/shellhouse here; run initial_setup.sh first." >&2; exit 1; }
[ -f .env ] || { echo "No .env in ~/shellhouse; run initial_setup.sh first." >&2; exit 1; }

if docker info >/dev/null 2>&1; then dkr() { docker "$@"; }
elif sg docker -c "docker info" >/dev/null 2>&1; then dkr() { sg docker -c "$(printf '%q ' docker "$@")"; }
else echo "Can't run docker as $(id -un); is it in the docker group?" >&2; exit 1; fi

old="$(sed -n 's/^MANAGER_TOKEN=//p' .env | head -1)"
new="$(openssl rand -hex 32)"
umask 077
if grep -q '^MANAGER_TOKEN=' .env; then
  sed -i "s|^MANAGER_TOKEN=.*|MANAGER_TOKEN=$new|" .env
else
  echo "MANAGER_TOKEN=$new" >> .env
fi
chmod 600 .env

if grep -q '^SANDBOX_BACKEND=firecracker' .env; then
  # The manager is a host service (host-firecracker.sh): a fixed root helper, allowed for this user without a
  # password, copies the new token into its settings and restarts it.
  sudo -n /usr/local/lib/shellhouse-firecracker/sync-manager-token \
    || { echo "Couldn't hand the new token to the agent-sandbox-manager service; run initial_setup.sh again." >&2; exit 1; }
else
  dkr compose up -d --no-deps --force-recreate sandbox-manager >/dev/null
fi
for _ in $(seq 1 60); do
  [ -S sandbox-manager-run/manager.sock ] && curl -fsS --unix-socket sandbox-manager-run/manager.sock http://localhost/healthz >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS --unix-socket sandbox-manager-run/manager.sock http://localhost/healthz >/dev/null 2>&1 \
  || { echo "The manager didn't come back after the restart. Check: docker logs agent-sandbox-manager" >&2; exit 1; }

# The HTTP status the manager gives a token, from an authenticated call that touches no sandbox: 404 (unknown
# sandbox) means the token was accepted, 401 means it was refused. The token goes in on stdin, not on a command line.
probe() {
  printf 'header = "x-manager-token: %s"\n' "$1" | curl -s -o /dev/null -w '%{http_code}' -K - \
    --unix-socket sandbox-manager-run/manager.sock -H 'content-type: application/json' \
    -X POST http://localhost/v1/health -d '{"sandbox_id":"rotation-check"}' 2>/dev/null || true
}
backend_hint="docker logs agent-sandbox-manager"
grep -q '^SANDBOX_BACKEND=firecracker' .env && backend_hint="journalctl -u agent-sandbox-manager"
got="$(probe "$new")"
if [ "$got" != "404" ]; then
  echo "The manager is running but doesn't accept the new token (it answered HTTP ${got:-none}). Its settings are out of step with .env." >&2
  echo "Check: $backend_hint   Then run initial_setup.sh again." >&2
  exit 1
fi
if [ -n "$old" ] && [ "$(probe "$old")" = "404" ]; then
  echo "The manager still accepts the OLD token, so it wasn't restarted with the new one. Check: $backend_hint" >&2
  exit 1
fi
unset new old
if grep -q '^SANDBOX_BACKEND=firecracker' .env; then
  echo "    ✓ New manager token in place and checked: the manager accepts it and refuses the old one (bot VMs start again on next use, with their files)"
else
  echo "    ✓ New manager token in place and checked: the manager accepts it and refuses the old one (bot VMs kept running)"
fi
