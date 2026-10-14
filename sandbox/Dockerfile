# The agent's "computer": a real Debian 13 (trixie) desktop, streamed over VNC.
# Dark wallpaper, openbox WM, a small bottom
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
    python3 python3-pip python3-venv python-is-python3 python3-pytest nodejs npm git \
    curl wget jq unzip ca-certificates bash procps \
    # remote access and file transfer
    openssh-client rsync gnupg gh \
    # building native packages (pip/npm extensions), patching
    build-essential pkg-config patch \
    # archives
    zip xz-utils bzip2 zstd p7zip-full \
    # finding and reading files
    ripgrep fd-find tree file less nano vim-tiny sqlite3 poppler-utils bc \
    # network and process debugging
    iputils-ping dnsutils netcat-openbsd iproute2 traceroute lsof htop tmux \
    supervisor sudo \
    && rm -rf /var/lib/apt/lists/* \
    # Debian names these fdfind / vim.tiny; give them their usual names.
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && ln -s /usr/bin/vim.tiny /usr/local/bin/vim

# Python libs commonly needed for agent work (PEP 668 on trixie needs the flag)
RUN pip3 install --no-cache-dir --break-system-packages \
    requests beautifulsoup4 openpyxl pandas

# Non-root desktop user (`box@...` in the shell prompt)
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
# .gitignore; ./setup.sh creates a minimal one) ------------------------------
# Only these named files are copied, so nothing else that lands in box/ ends
# up in the image.
COPY box/.bashrc box/.profile box/.gitconfig box/.bash_logout /home/box/
COPY box/.config/ /home/box/.config/
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

# --- Shellhouse agent runner (smolagents) ----------------------------------------
# UNBUILT / UNTESTED in an image: written on a macOS dev box without Docker.
# New third-party dependency: smolagents (Apache-2.0) + the `openai` client and
# transitive packages, pinned in sandbox/agent-runner/requirements.lock.
# Runs in its own venv so it cannot disturb the system pip packages above.
# `python3 -m shellhouse_agent ...` works from system python3 via PYTHONPATH; the `run`
# subcommand re-execs into /opt/shellhouse-agent/bin/python (where smolagents lives).
COPY sandbox/agent-runner/requirements.lock /opt/shellhouse-agent/requirements.lock
COPY sandbox/agent-runner/src/shellhouse_agent/ /opt/shellhouse-agent/src/shellhouse_agent/
RUN python3 -m venv /opt/shellhouse-agent \
    && /opt/shellhouse-agent/bin/pip install --no-cache-dir -r /opt/shellhouse-agent/requirements.lock \
    && chmod -R a+rX /opt/shellhouse-agent \
    && printf '#!/bin/sh\nexec /opt/shellhouse-agent/bin/python -m shellhouse_agent "$@"\n' > /usr/local/bin/shellhouse-agent \
    && chmod 0755 /usr/local/bin/shellhouse-agent
ENV PYTHONPATH=/opt/shellhouse-agent/src

# 5900 = raw VNC, 6080 = noVNC over HTTP/WebSocket (what the UI embeds)
EXPOSE 5900 6080

WORKDIR /workspace

CMD ["/usr/bin/supervisord", "-c", "/etc/agent-desktop/supervisord.conf"]
