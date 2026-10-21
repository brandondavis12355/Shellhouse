#!/bin/bash
# Raw VNC server on loopback. When VNC_PASSWORD is set (per-container, by the
# sandbox manager), require it; otherwise (the legacy compose-managed
# container) fall back to no password as before.
#
# The mouse pointer is sent to the viewer (`-cursor most`, with XFIXES on so the real shape is followed): with `-noxfixes` a
# viewer shows no pointer at all, and a person watching a bot work cannot see where it is clicking. If that set of options
# makes x11vnc exit at once, the old set is used instead, so the desktop still comes up.
set -e
BASE=(-display :1 -forever -shared -localhost -rfbport 5900 -xkb -noxrecord -noxdamage -wait 20)
NEW=("${BASE[@]}" -cursor most -arrow 1)
OLD=("${BASE[@]}" -noxfixes)
if [ -n "${VNC_PASSWORD:-}" ]; then
  PASSFILE=/etc/agent-desktop/vncpass
  /usr/bin/x11vnc -storepasswd "$VNC_PASSWORD" "$PASSFILE" >/dev/null 2>&1
  chmod 600 "$PASSFILE"
  AUTH=(-rfbauth "$PASSFILE")
else
  AUTH=(-nopw)
fi
started=$(date +%s)
set +e
/usr/bin/x11vnc "${NEW[@]}" "${AUTH[@]}"
code=$?
set -e
if [ $(( $(date +%s) - started )) -lt 8 ]; then
  echo "x11vnc exited after $(( $(date +%s) - started )) s with the pointer options; starting it without them" >&2
  exec /usr/bin/x11vnc "${OLD[@]}" "${AUTH[@]}"
fi
exit "$code"
