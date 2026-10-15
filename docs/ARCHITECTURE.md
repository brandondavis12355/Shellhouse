# Architecture notes for this implementation

The Docker/Python stack implements the MVP loop of the full platform design: a
model-agnostic
agent runtime, a permission-gated tool system, a sandboxed execution
environment, and durable/event-sourced task state — wired exclusively to a
local Ollama server.

## What's real here vs. what's a stub

| Layer | This repo | Full design |
|---|---|---|
| Model gateway | Ollama only, one class | Router across Ollama/vLLM/multiple local backends by task type/cost |
| Sandbox | Both backends implemented behind `SandboxProvider`, inside the privileged manager: Docker container (default) and Firecracker microVM (`initial_setup.sh --with-firecracker`; the manager then runs as a host service) | Same, plus pre-warmed VM pools, snapshot-restore fleet, image signing, multi-host scheduling |
| Memory | All four tiers implemented: working (task row), conversation (messages + compaction), user (explicit `remember`), knowledge (Qdrant) with structured evidence | Same, plus graph relationships between evidence and document ingestion pipelines |
| Tools | 17 built-in (files, shell, web, desktop/GUI, memory, secrets) + MCP client for external servers | + productivity tools (spreadsheet/doc/slides), more integrations |
| Multi-tenancy | None (single local user), but privilege is already split |
| Evaluation | 12 deterministic tasks, 4 suites, model-comparison mode | Larger suites (100s of tasks), CI gating, regression tracking over time | Auth, orgs, projects, per-tenant isolation |
| Queue | Redis lists with leases, heartbeats, stale sweep, retry-with-dead-letter, DB-level orphan recovery | NATS/Kafka if you outgrow Redis; per-tenant fairness |
| UI | One page: task creation, live desktop, trace, approvals, files, history, computers, memory search | Artifacts browser, usage/billing, richer trace inspection |

## Sandbox providers (Phase 7 — implemented)

`api/agent/sandbox/base.py` defines the `SandboxProvider` protocol
(`create/start/exec/read_file/write_file/pause/resume/destroy/health`), and
both backends implement it:

```
api:              agent/tools.py -> get_provider() -> ManagerSandboxProvider
                                                           |  unix socket
                                                           v
sandbox-manager:  get_backend() -> DockerBackend       (SANDBOX_BACKEND=docker)
                                \-> FirecrackerBackend  (SANDBOX_BACKEND=firecracker)
```

No tool, and no part of the agent loop, references Docker or Firecracker —
and the API process cannot reach either even if it wanted to.
Full rollout plan, host requirements, isolation verification steps, and open
decisions: **`docs/FIRECRACKER.md`**.

## Path to production hardening (do these before exposing beyond localhost)

1. ~~Stop mounting `/var/run/docker.sock` into the API container.~~ **Done** —
   `sandbox-manager/` is now the only privileged component; the API reaches it
   over a unix socket and holds no host privilege. See `docs/SECURITY.md`.
2. Add authentication (even a single shared token to start) in front of the
   FastAPI app — right now anything on your network that can reach port 8000
   can create tasks.
3. Add an egress allowlist/firewall around the sandbox container so
   `run_shell`-initiated processes can't reach your LAN, cloud metadata
   endpoints, or arbitrary hosts.
4. Move SQLite to PostgreSQL (`DATABASE_URL=postgresql://...`) once more than
   one worker/process needs to touch task state concurrently.
5. Replace the polling event API with a WebSocket/SSE fan-out if you need
   true real-time updates at scale.

## Loop detection

`api/agent/runtime.py` hashes `(tool_name, arguments)` per tool call. If the same
exact call repeats more than `LOOP_REPEAT_THRESHOLD` times in one task, the
task is moved to `BLOCKED` instead of burning tokens/compute forever.

## Prompt-injection stance

The system prompt explicitly tells the model that `web_search`/`fetch_url`/
`read_file` output is data, not instructions. This is a mitigation, not a
guarantee — the actual security boundary is the policy engine
(`api/agent/policy.py`), which is what decides whether a tool call executes,
regardless of what the model "decided" after reading untrusted content.


## The desktop ("computer") layer

The sandbox is a real graphical Linux environment, not a headless shell:

```
supervisord
 ├── Xvfb :1            virtual framebuffer (1280x800x24, set via SCREEN_GEOM)
 ├── start-desktop.sh   feh wallpaper -> tint2 dock -> openbox-session
 │                      and pre-opens xfce4-terminal (/workspace) + Thunar
 ├── x11vnc             binds to 127.0.0.1:5900 inside the container only
 └── websockify         serves noVNC on :6080  <- the UI embeds this
```

The agent drives that desktop through the same policy-gated tool interface as
everything else — `screenshot` (scrot), `list_windows` (wmctrl -lG), `click` /
`type_text` / `press_key` (xdotool), `open_app`. Nothing bypasses
`api/agent/policy.py`.

Two deliberate choices worth knowing about:

- **You and the agent share one desktop.** The noVNC session is read-write, so
  clicking into the panel in the UI gives you the mouse and keyboard on the
  same X display the agent is using. That's the "take control" affordance from
  the product design, and it's also how you rescue a stuck task (log into a
  site by hand, dismiss a dialog, etc). The tradeoff is that you can fight the
  agent for the cursor if you both act at once.
- **`type_text` writes through a file**, not a shell-quoted argument
  (`xdotool type --file`). Passing model-generated text through `bash -c`
  would be an injection hole; the file path avoids shell quoting entirely.

### Why the container needs `seccomp:unconfined` and a bigger `shm_size`

Chromium's own sandbox needs syscalls the default Docker seccomp profile
blocks, and it crashes on the default 64MB `/dev/shm`. Both are set in
`docker-compose.yml`. This is one of the clearest arguments for the
Firecracker migration: with VM-level isolation you get a real security
boundary around the browser instead of relaxing the container's.

### Screen geometry

`SCREEN_GEOM` in `docker-compose.yml` controls the desktop resolution. The UI
panel uses a 16:10 aspect ratio to match the default `1280x800x24`; change
both together if you want a different shape.
