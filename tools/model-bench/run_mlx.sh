#!/bin/bash
# usage: run_mlx.sh NAME MODEL [DRAFT_MODEL [NUM_DRAFT_TOKENS]]
# Starts mlx_lm.server on port 8081, runs bench.py against it, then stops the server.
set -u
NAME="$1"; MODEL="$2"; DRAFT="${3:-}"; N="${4:-4}"
PORT=8081
ARGS=(--model "$MODEL" --host 127.0.0.1 --port $PORT)
[ -n "$DRAFT" ] && ARGS+=(--draft-model "$DRAFT" --num-draft-tokens "$N")
~/mlx-env/bin/mlx_lm.server "${ARGS[@]}" > "results/server-$NAME.log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null' EXIT
for i in $(seq 1 120); do curl -sf -m 2 http://127.0.0.1:$PORT/v1/models >/dev/null && break; sleep 3; done
python3 -I "$(dirname "$0")/bench.py" --name "$NAME" --url http://127.0.0.1:$PORT/v1 --model "$MODEL" --runs 3 --json "results/$NAME.json" 2>&1 | grep -E "chat:|code:|long_prompt:|qa|json|tool|Error|error" 
grep -c "Exception occurred" "results/server-$NAME.log" | sed 's/^/server exceptions: /'
