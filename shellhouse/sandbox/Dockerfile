# The agent's "computer": a real Debian 13 (trixie) desktop, streamed over VNC.
# Mirrors the reference environment: dark wallpaper, openbox WM, a small bottom
# dock (Chromium / Thunar / Terminal), Thunar file manager, xfce4-terminal,
# user `box`, working directory /workspace.
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    SCREEN_GEOM=1280x800x24 \
    HOME=/home/box \
    LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    # X server + VNC + browser-based VNC client
    xvfb x11vnc novnc websockify \
    # window manager, dock, wallpaper setter, notifications
    openbox tint2 feh xfce4-notifyd \
    # apps visible on the desktop
    thunar xfce4-terminal chromium \
    # agent-driven GUI control + screenshots
    xdotool wmctrl scrot imagemagick xclip \
    # Tk, for ai-click.py's transient "an agent just clicked here" badge
    python3-tk \
    # fonts & themes so the desktop doesn't look broken
    fonts-dejavu fonts-liberation adwaita-icon-theme \
    # the actual toolchain the agent uses
    python3 python3-pip python3-venv nodejs npm git \
    curl wget jq unzip ca-certificates bash procps \
    supervisor sudo \
    && rm -rf /var/lib/apt/lists/*

# Python libs commonly needed for agent work (PEP 668 on trixie needs the flag)
RUN pip3 install --no-cache-dir --break-system-packages \
    requests beautifulsoup4 openpyxl pandas

# Non-root desktop user, matching the reference environment's `box@...`
RUN useradd -m -s /bin/bash box \
    && mkdir -p /workspace \
    && chown -R box:box /workspace /home/box \
    # Passwordless sudo is installed but INERT unless the container is started
    # without no-new-privileges (setuid-root sudo can't elevate under it) —
    # see SANDBOX_ALLOW_SUDO in docker-compose.yml / sandbox-manager.
    && echo "box ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/box \
    && chmod 0440 /etc/sudoers.d/box

COPY sandbox/config/ /etc/agent-desktop/
COPY sandbox/bin/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*

# Openbox/tint2/wallpaper config into the user's home
RUN mkdir -p /home/box/.config/openbox /home/box/.config/tint2 \
    && cp /etc/agent-desktop/openbox-rc.xml /home/box/.config/openbox/rc.xml \
    && cp /etc/agent-desktop/openbox-autostart /home/box/.config/openbox/autostart \
    && cp /etc/agent-desktop/tint2rc /home/box/.config/tint2/tint2rc \
    && chown -R box:box /home/box/.config

# Generate the dark wallpaper with the soft diagonal sweep
RUN /usr/local/bin/make-wallpaper.sh && chown box:box /usr/share/backgrounds/agent-wallpaper.png

# --- Seed /home/box from the top-level box/ directory (gitignored — see
# .gitignore) ---------------------------------------------------------------
# Deliberately NOT box/agent-data, box/sand-data, box/sand-host, box/deps, or
# box/cli-config: those turned out to be a third-party product's internal
# agent-sandbox runtime (literal secrets files — box-secrets.json,
# host-secrets.json, chrome-cookie-seed.json — plus browser
# cookie/session-injection tooling), not anything authored for this project,
# and are excluded on purpose rather than by oversight.
COPY box/.bashrc box/.profile box/.gitconfig box/.bash_logout /home/box/
COPY box/.config/ /home/box/.config/
COPY box/reference/ /home/box/reference/
# box/.config/gh (GitHub CLI) holds OAuth tokens in hosts.yml — belt-and-
# suspenders removal in case the box/.config COPY above ever picks it back up.
RUN rm -rf /home/box/.config/gh \
    && chown -R box:box /home/box

# --- Seed /workspace -------------------------------------------------------
# /workspace itself is a Docker volume at runtime (see docker-compose.yml),
# so anything copied straight there would only take effect on that volume's
# very first use and be silently shadowed otherwise. Staged here instead;
# start-desktop.sh copies it into the real /workspace on every container
# start, without clobbering whatever's already there.
COPY workspace/ /opt/seed-workspace/
RUN chmod -R a+rX /opt/seed-workspace

# 5900 = raw VNC, 6080 = noVNC over HTTP/WebSocket (what the UI embeds)
EXPOSE 5900 6080

WORKDIR /workspace

CMD ["/usr/bin/supervisord", "-c", "/etc/agent-desktop/supervisord.conf"]
