#!/bin/bash
# Raw VNC server on loopback. When VNC_PASSWORD is set (per-container, by the
# sandbox manager), require it; otherwise (the legacy compose-managed
# container) fall back to no password as before.
set -e
ARGS=(-display :1 -forever -shared -localhost -rfbport 5900 -xkb -noxrecord -noxfixes -noxdamage -wait 20)
if [ -n "${VNC_PASSWORD:-}" ]; then
  PASSFILE=/etc/agent-desktop/vncpass
  /usr/bin/x11vnc -storepasswd "$VNC_PASSWORD" "$PASSFILE" >/dev/null 2>&1
  chmod 600 "$PASSFILE"
  exec /usr/bin/x11vnc "${ARGS[@]}" -rfbauth "$PASSFILE"
fi
exec /usr/bin/x11vnc "${ARGS[@]}" -nopw
