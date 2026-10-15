#!/usr/bin/env bash
# Writes .env (and the box/ and workspace/ seed folders) for running the Docker stack by hand, on Linux or macOS:
#
#   ./scripts/make-env.sh
#
# What it does:
#   - creates .env from .env.example, with a fresh manager token (an existing .env keeps its token);
#   - sets the Docker group, the manager socket's owner and folder, and the workspace volume's name;
#   - creates minimal box/ and workspace/ seed folders if they're missing (existing files are kept).
# initial_setup.sh does the same on the Linux box by itself; you only need this to run the stack without it.
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib/stack-env.sh
. scripts/lib/stack-env.sh
command -v openssl >/dev/null || [ -f .env ] || { echo "openssl is needed to generate the manager token." >&2; exit 1; }

write_stack_env
echo "Wrote $(pwd)/.env (mode 600) and the box/ and workspace/ seeds."
cat <<'NEXT'

Next:

  docker compose up -d --build
  docker exec agent-ollama ollama pull qwen2.5:7b-instruct

Then open http://localhost:3000. Every port binds to 127.0.0.1.
NEXT
