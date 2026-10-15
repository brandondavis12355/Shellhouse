# Build notes — what to expect on first run

> **Historical.** Written before the Docker/Python stack had ever been run.
> Kept as a debugging checklist; the stack has since been built and run.

None of this has been executed. It is syntax-checked, and the tool/schema/
policy tables reconcile, but that only rules out a category of error. Below is
where I actually expect trouble, roughly in the order you'll hit it, so the
first pass is debugging rather than discovery.

## Start here

```bash
./scripts/make-env.sh               # writes .env and the box/ and workspace/ seeds
docker compose up -d --build        # expect 10-20 min on first build
docker compose ps                   # all 8 services should be Up
docker compose logs -f api worker sandbox-manager
```

Then, in order:

```bash
docker exec agent-ollama ollama pull qwen2.5:7b-instruct
docker exec agent-ollama ollama pull nomic-embed-text
curl -s localhost:8000/health | python3 -m json.tool
```

`/health` reports queue and memory status, so it's the fastest way to see
which dependency is unhappy.

## Expected failure points, in likely order

### 1. The sandbox image build (highest risk)
Debian trixie package names and Chromium's flags are the least verifiable
things here. Specific suspects:

- `chromium` vs `chromium-browser` package naming.
- `novnc` + `websockify` paths: the entrypoint assumes `/usr/share/novnc`.
  Check with `docker exec agent-sandbox ls /usr/share/novnc`.
- `magick` vs `convert` for the wallpaper — ImageMagick 7 renamed the binary.
  If `make-wallpaper.sh` fails the build, that's why.
- `scrot -o -F` flag support varies by version.

Debug: `docker compose logs sandbox`, then
`docker exec -it agent-sandbox bash` and run the pieces by hand.

### 2. The desktop not appearing in the UI
Layers: Xvfb → openbox → x11vnc → websockify → iframe. Test bottom-up:

```bash
docker exec agent-sandbox supervisorctl status     # all RUNNING?
curl -sI localhost:6080/vnc.html                   # noVNC serving?
docker exec agent-sandbox env DISPLAY=:1 xdotool getdisplaygeometry
```

### 3. Manager socket handshake
If `api` logs "Cannot reach the Sandbox Manager", check in this order:

```bash
docker exec agent-sandbox-manager ls -l /run/sandbox-manager/manager.sock
docker exec agent-api ls -l /run/sandbox-manager/manager.sock
docker exec agent-sandbox-manager tail -50 /var/log/sandbox-manager/audit.log
```

The socket is `0660` via umask. **[unverified]** whether the api container's
user lands in the right group to read it across a Docker volume — a volume
doesn't preserve group semantics the way a bind mount does. If this fails,
switching `manager_socket` to a host bind mount is the fix.

### 4. `WORKSPACE_VOLUME` name
`scripts/make-env.sh` (and the host setup) set the compose-prefixed volume name from the project name in docker-compose.yml.
Verify and correct:

```bash
docker volume ls | grep workspace
```

Wrong value = per-task ephemeral sandboxes fail to start.

### 5. Ollama tool calling
Test the model directly before blaming the agent:

```bash
curl -s localhost:11434/api/chat -d '{
  "model":"qwen2.5:7b-instruct","stream":false,
  "messages":[{"role":"user","content":"list files in /workspace"}],
  "tools":[{"type":"function","function":{"name":"list_files",
    "parameters":{"type":"object","properties":{"path":{"type":"string"}}}}}]
}' | python3 -m json.tool
```

If `tool_calls` is absent, the model isn't tool-capable and no amount of
agent-side work will fix it.

### 6. Token accounting
Assumes Ollama populates `prompt_eval_count` / `eval_count` on `/api/chat`. If
it doesn't, the token budget silently never fires. The iteration and wall-clock
budgets still work, so this degrades rather than breaks.

### 7. Embeddings endpoint
`/api/embed` (batch) with a fallback to `/api/embeddings` (single). If both
404, the Ollama version is older than expected and memory writes will fail —
non-fatally, by design, but you'll see `evidence.capture_failed` events.

### 8. Qdrant client API surface
`qdrant-client==1.11.3` — `search()` is being deprecated in favour of
`query_points()` in newer releases. If you bump the pin and searches break,
that's the cause.

### 9. Vision + tool calling together
The weakest assumption in the whole build. Some local models handle images
well, tools well, and both together badly. If tool calls stop working once a
screenshot is attached, the fallback is a two-model split: a vision model
describes the screen, the tool-calling model acts on the description.

### 10. Ephemeral sandbox `/workspace` symlink
Per-task containers symlink `/workspace` → `/workspaces/<task>` *after* boot,
so the pre-opened terminal and Thunar may be pointed at the pre-symlink path.
Probably wants fixing in the image rather than at runtime.

## Things worth verifying even if nothing looks broken

```bash
# The api must hold no host privilege.
docker exec agent-api ls /var/run/docker.sock        # expect: No such file

# The manager must reject unauthenticated calls.
docker exec agent-sandbox-manager python -c "
import httpx
t=httpx.HTTPTransport(uds='/run/sandbox-manager/manager.sock')
print(httpx.Client(transport=t, base_url='http://m').post(
  '/v1/exec', json={'sandbox_id':'agent-sandbox','command':'id'}).status_code)"
# expect: 401

# Durability: a task should survive an API restart.
#   start a long task, then:
docker compose restart api
#   the task should keep running (the worker owns it)

# Recovery: an interrupted task should be picked back up.
docker compose restart worker
#   look for "Recovering task" in the worker logs

# Secrets must never reach the model.
grep -rn "resolve_env" api/    # should appear only in tools.py run_shell
```

## Suggested order for the next pass

1. Get `docker compose ps` fully green.
2. Get the desktop rendering in the UI.
3. Get one file-suite eval passing: `python evals/run_evals.py --suite evals/suites/files.json`
   — it needs no network, so it isolates tool-calling from web flakiness.
4. Then research suite (adds web + memory), then computer suite (adds GUI +
   vision), then safety.
5. Save that run as `baseline.json` and compare against it from then on.

Expect the computer-use suite to be the weakest on a 7B model. That's the
signal it exists to give you, not a bug.
