#!/usr/bin/env bash
# Runs ON the Linux host (initial_setup.sh --rotate-token copies it to /tmp and runs it). Replaces the sandbox
# manager's token with a new random one and restarts only the manager: the bots' VMs keep running. The new token
# is never printed; initial_setup.sh reads it from .env straight into the app's settings file.
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail
cd "$HOME/shellhouse" || { echo "No ~/shellhouse here; run initial_setup.sh first." >&2; exit 1; }
[ -f .env ] || { echo "No .env in ~/shellhouse; run initial_setup.sh first." >&2; exit 1; }

if docker info >/dev/null 2>&1; then dkr() { docker "$@"; }
elif sg docker -c "docker info" >/dev/null 2>&1; then dkr() { sg docker -c "$(printf '%q ' docker "$@")"; }
else echo "Can't run docker as $(id -un); is it in the docker group?" >&2; exit 1; fi

new="$(openssl rand -hex 32)"
umask 077
if grep -q '^MANAGER_TOKEN=' .env; then
  sed -i "s|^MANAGER_TOKEN=.*|MANAGER_TOKEN=$new|" .env
else
  echo "MANAGER_TOKEN=$new" >> .env
fi
unset new
chmod 600 .env

dkr compose up -d --no-deps --force-recreate sandbox-manager >/dev/null
for _ in $(seq 1 60); do
  [ -S sandbox-manager-run/manager.sock ] && curl -fsS --unix-socket sandbox-manager-run/manager.sock http://localhost/healthz >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS --unix-socket sandbox-manager-run/manager.sock http://localhost/healthz >/dev/null 2>&1 \
  || { echo "The manager didn't come back after the restart. Check: docker logs agent-sandbox-manager" >&2; exit 1; }
echo "    ✓ New manager token in place; the manager restarted (bot VMs kept running)"
