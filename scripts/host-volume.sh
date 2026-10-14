#!/usr/bin/env bash
# Runs ON a Linux host: streams one bot's workspace volume out (tar on stdout) or in (tar on stdin), for
# initial_setup.sh's changeover from one box to another. Uses the sandbox image's own tar, so nothing is pulled.
#
#   bash host-volume.sh list                       # names of the bots' workspace volumes
#   bash host-volume.sh export agent-workspace-X   > file.tgz
#   bash host-volume.sh import agent-workspace-X   < file.tgz   (refuses if it already has files)
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail
IMAGE="agent-desktop:local"
if docker info >/dev/null 2>&1; then D=(docker)
elif sg docker -c "docker info" >/dev/null 2>&1; then D=(sg docker -c)
else D=(sudo -n docker); fi
dkr() { if [ "${D[0]}" = sg ]; then sg docker -c "$(printf '%q ' docker "$@")"; else "${D[@]}" "$@"; fi; }

case "${1:-}" in
  list)
    dkr volume ls -q --filter label=agent.sandbox=true | grep '^agent-workspace-' || true ;;
  export)
    vol="${2:?volume name}"; [[ "$vol" =~ ^agent-workspace-[A-Za-z0-9_-]+$ ]] || { echo "bad volume name" >&2; exit 2; }
    dkr run --rm -i --user 0 --network none --entrypoint tar -v "$vol:/v:ro" "$IMAGE" -C /v -czf - . ;;
  import)
    vol="${2:?volume name}"; [[ "$vol" =~ ^agent-workspace-[A-Za-z0-9_-]+$ ]] || { echo "bad volume name" >&2; exit 2; }
    task="${vol#agent-workspace-}"
    if dkr volume inspect "$vol" >/dev/null 2>&1; then
      if [ -n "$(dkr run --rm --user 0 --network none --entrypoint sh -v "$vol:/v" "$IMAGE" -c 'ls -A /v | head -1')" ]; then
        echo "already has files; left as is" >&2; cat >/dev/null; exit 3
      fi
    else
      dkr volume create --label agent.sandbox=true --label "agent.task_id=$task" "$vol" >/dev/null
    fi
    dkr run --rm -i --user 0 --network none --entrypoint tar -v "$vol:/v" "$IMAGE" -C /v -xzpf - ;;
  *) echo "usage: host-volume.sh list | export VOLUME | import VOLUME" >&2; exit 2 ;;
esac
