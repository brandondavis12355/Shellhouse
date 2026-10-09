#!/usr/bin/env bash
# One-time local setup: generates the manager token and detects the docker GID
# so the Sandbox Manager can read the socket via group membership instead of
# running as root.
set -euo pipefail

cd "$(dirname "$0")"

if [[ -f .env ]]; then
  echo ".env already exists — not overwriting. Delete it first to regenerate."
else
  cp .env.example .env

  # Shared secret between api and sandbox-manager.
  TOKEN="$(openssl rand -hex 32)"
  # macOS/BSD sed needs the empty -i arg; GNU sed doesn't accept it.
  if sed --version >/dev/null 2>&1; then
    sed -i "s|^MANAGER_TOKEN=.*|MANAGER_TOKEN=${TOKEN}|" .env
  else
    sed -i '' "s|^MANAGER_TOKEN=.*|MANAGER_TOKEN=${TOKEN}|" .env
  fi
  echo "Generated MANAGER_TOKEN in .env"
fi

# The GID that owns /var/run/docker.sock, so the manager gets socket access
# through a group rather than root.
if [[ -S /var/run/docker.sock ]]; then
  if stat -c '%g' /var/run/docker.sock >/dev/null 2>&1; then
    DGID="$(stat -c '%g' /var/run/docker.sock)"     # GNU
  else
    DGID="$(stat -f '%g' /var/run/docker.sock)"     # BSD/macOS
  fi
  if grep -q '^DOCKER_GID=' .env; then
    if sed --version >/dev/null 2>&1; then
      sed -i "s|^DOCKER_GID=.*|DOCKER_GID=${DGID}|" .env
    else
      sed -i '' "s|^DOCKER_GID=.*|DOCKER_GID=${DGID}|" .env
    fi
  else
    echo "DOCKER_GID=${DGID}" >> .env
  fi
  echo "Detected docker socket GID: ${DGID}"
else
  echo "WARN: /var/run/docker.sock not found. On Docker Desktop (macOS/Windows)"
  echo "      the default DOCKER_GID=999 usually works."
fi

# The host user sandbox-manager runs as, and where its socket lives on the
# host filesystem — a bind mount (not a named volume) so something outside
# Docker entirely (e.g. an SSH-tunneled remote client; see
# README.md › Linux host setup) can reach it too. Docker volumes'
# backing paths are internal and normally root-owned, which such a client
# can't get to.
set_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" .env; then
    if sed --version >/dev/null 2>&1; then
      sed -i "s|^${key}=.*|${key}=${value}|" .env
    else
      sed -i '' "s|^${key}=.*|${key}=${value}|" .env
    fi
  else
    echo "${key}=${value}" >> .env
  fi
}
set_env MANAGER_SOCKET_UID "$(id -u)"
set_env MANAGER_SOCKET_GID "$(id -g)"
set_env MANAGER_SOCKET_HOST_DIR "./sandbox-manager-run"
echo "Manager socket: $(id -u):$(id -g) @ ./sandbox-manager-run"

chmod 600 .env

# The sandbox image seeds /home/box and /workspace from box/ and workspace/.
# Both are git-ignored (they can hold real credentials), so a fresh clone has
# neither: create a minimal seed so the image builds. Existing files are left
# alone; add your own dotfiles or starter files there if you want them.
mkdir -p box/.config box/reference workspace
for f in .bashrc .profile .bash_logout .gitconfig; do
  if [ ! -e "box/$f" ]; then
    if [ -f "/etc/skel/$f" ]; then cp "/etc/skel/$f" "box/$f"; else : > "box/$f"; fi
  fi
done

# The workspace volume name is project-prefixed by compose, and the Sandbox
# Manager needs it verbatim to mount into per-task sandboxes. The project name
# is pinned by `name:` in docker-compose.yml, so read it from there rather than
# from this folder's name.
PROJECT="$(sed -n 's/^name:[[:space:]]*//p' docker-compose.yml | head -1)"
PROJECT="${PROJECT:-shellhouse}"
VOL="${PROJECT}_workspace"
if grep -q '^WORKSPACE_VOLUME=' .env; then
  if sed --version >/dev/null 2>&1; then
    sed -i "s|^WORKSPACE_VOLUME=.*|WORKSPACE_VOLUME=${VOL}|" .env
  else
    sed -i '' "s|^WORKSPACE_VOLUME=.*|WORKSPACE_VOLUME=${VOL}|" .env
  fi
else
  echo "WORKSPACE_VOLUME=${VOL}" >> .env
fi
echo "Workspace volume: ${VOL}"
echo "  (verify after first start with: docker volume ls | grep workspace)"

cat <<'NEXT'

Setup complete. Next:

  docker compose up -d --build
  docker exec agent-ollama ollama pull qwen2.5:7b-instruct

Then open http://localhost:3000

Verify the privilege split actually holds:

  # the api must NOT be able to reach docker
  docker exec agent-api ls /var/run/docker.sock   # expect: No such file

  # the manager's socket must be group-only, not world-writable
  docker exec agent-sandbox-manager ls -l /run/sandbox-manager/manager.sock

  # watch what the agent actually does
  docker exec agent-sandbox-manager tail -f /var/log/sandbox-manager/audit.log
NEXT
