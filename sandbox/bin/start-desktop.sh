#!/bin/bash
# Brings up the agent's desktop session and pre-opens its two working windows:
# a terminal in /workspace (left) and Thunar showing /workspace (right).
set -e

export DISPLAY=:1

# Seed /workspace from the image's baked-in copy, without clobbering
# anything already there — /workspace is a Docker volume, so on a fresh
# volume this populates it; on one that already has real agent output, it
# only fills in whatever's missing. -n = no-clobber (skip existing files).
if [ -d /opt/seed-workspace ]; then
  cp -rn /opt/seed-workspace/. /workspace/ 2>/dev/null || true
fi

# Wait for the X server to accept connections
for _ in $(seq 1 50); do
  xdotool getdisplaygeometry >/dev/null 2>&1 && break
  sleep 0.2
done

# Wallpaper + window manager + dock
feh --no-fehbg --bg-fill /usr/share/backgrounds/agent-wallpaper.png || true
tint2 -c "$HOME/.config/tint2/tint2rc" &
xfce4-notifyd &

# Pre-open the workspace windows, tiled left/right like the reference desktop
(
  sleep 2
  xfce4-terminal --working-directory=/workspace \
                 --geometry=100x30+8+8 \
                 --title="Terminal - box@$(hostname): /workspace" &
  sleep 1
  thunar /workspace &
  sleep 2
  # Nudge Thunar to the right half of the screen
  wmctrl -r "workspace" -e 0,660,8,610,480 2>/dev/null || true
) &

# openbox is the session leader — supervisor restarts the whole session if it dies
exec openbox-session
