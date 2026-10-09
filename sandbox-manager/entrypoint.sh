#!/bin/sh
# Serve on a unix domain socket only. No TCP listener is ever opened, so the
# manager is unreachable from the network regardless of firewall state.
set -e

SOCKET="${MANAGER_SOCKET:-/run/sandbox-manager/manager.sock}"
mkdir -p "$(dirname "$SOCKET")"
rm -f "$SOCKET"

if [ -z "$MANAGER_TOKEN" ]; then
  echo "FATAL: MANAGER_TOKEN is unset. Refusing to start a privileged" >&2
  echo "       service with no authentication. Generate one with:" >&2
  echo "       openssl rand -hex 32" >&2
  exit 1
fi

# uvicorn has no socket-permission flag, so set the umask before binding:
# 0117 makes the socket 0660 (owner + group rw, world nothing). The api
# container shares the group; nothing else on the host can connect.
umask 0117

exec uvicorn main:app \
  --uds "$SOCKET" \
  --no-access-log \
  --log-level warning
