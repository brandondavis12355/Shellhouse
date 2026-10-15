# Writes the stack's .env and the seed folders the desktop image needs. Sourced by scripts/host-setup.sh (on the
# Linux box) and scripts/make-env.sh (by hand, on Linux or macOS). Run from the repo folder. Source it; don't run it.
#
# Drafted with AI assistance (Claude Code); read it before you run it.

# set_env KEY VALUE: sets KEY=VALUE in ./.env, replacing an existing line (GNU and BSD sed).
set_env() {
  if grep -q "^$1=" .env; then
    if sed --version >/dev/null 2>&1; then sed -i "s|^$1=.*|$1=$2|" .env; else sed -i '' "s|^$1=.*|$1=$2|" .env; fi
  else
    echo "$1=$2" >> .env
  fi
}

# The stack's .env. An existing .env is kept as it is (its token stays); only what belongs to this machine is
# refreshed. Says what it couldn't detect on stderr.
write_stack_env() {
  [ -f .env.example ] || { echo "No .env.example here: run this from the repo folder." >&2; return 1; }
  [ -f .env ] || (umask 077; cp .env.example .env)
  chmod 600 .env
  # The secret shared by the API and the sandbox manager; every call to the manager carries it.
  grep -q '^MANAGER_TOKEN=.\+' .env || set_env MANAGER_TOKEN "$(openssl rand -hex 32)"
  # The group that owns the Docker socket, so the manager container reads it through the group, not as root.
  local gid=""
  if [ -S /var/run/docker.sock ]; then
    gid="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || stat -f '%g' /var/run/docker.sock 2>/dev/null || true)"
  fi
  if [ -n "$gid" ]; then
    set_env DOCKER_GID "$gid"
  else
    echo "    ! /var/run/docker.sock not found; DOCKER_GID stays as it is ($(sed -n 's/^DOCKER_GID=//p' .env)). On Docker Desktop that default usually works." >&2
  fi
  # The manager's socket is a plain folder owned by this user, so the app's SSH tunnel (also this user) can reach it.
  set_env MANAGER_SOCKET_UID "$(id -u)"
  set_env MANAGER_SOCKET_GID "$(id -g)"
  set_env MANAGER_SOCKET_HOST_DIR "./sandbox-manager-run"
  # The desktop image seeds /home/box and /workspace from box/ and workspace/. Both are git-ignored (they can hold
  # real credentials), so a fresh copy has neither: a minimal seed lets the image build. Existing files are kept.
  mkdir -p box/.config workspace
  local f
  for f in .bashrc .profile .bash_logout .gitconfig; do
    if [ ! -e "box/$f" ]; then
      if [ -f "/etc/skel/$f" ]; then cp "/etc/skel/$f" "box/$f"; else : > "box/$f"; fi
    fi
  done
  # Compose prefixes volume names with the project name (pinned by `name:` in docker-compose.yml); the manager
  # needs the workspace volume's real name to mount it into per-bot sandboxes.
  local project; project="$(sed -n 's/^name:[[:space:]]*//p' docker-compose.yml | head -1)"
  set_env WORKSPACE_VOLUME "${project:-shellhouse}_workspace"
}
