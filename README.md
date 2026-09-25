# Local AI Computer (self-hosted AI agent computer)

> **Two builds live here, both real.**
> - **`macos/` — [Shellhouse](shellhouse/macos/README.md)**, a native Swift/SwiftUI Mac
>   app. This is where active development is happening: a roster of
>   independent agent bots, each with its own persistent sandbox, memory,
>   scheduled routines, and the ability to delegate to and coordinate with
>   each other. Start there if you're on a Mac.
> - **Docker/Python stack (this root)** — the original reference
>   implementation this whole project grew out of: a single-agent loop
>   behind a web UI, containerized, with the fuller Phase 0–5 feature set
>   below (Firecracker microVMs, Qdrant memory, MCP, evals). Still the
>   design oracle for anything the macOS build hasn't ported yet — see
>   `shellhouse/docs/MACOS-NATIVE.md` for how the two relate.

A self-hosted "give an agent a goal and a controlled computer" platform,
built entirely from open-source / free components. It talks **only** to a
local Ollama server — there is no code path anywhere in this repo that calls
a cloud model API.

This is the MVP slice of the larger architecture in
`shellhouse/docs/ARCHITECTURE.md` (Phases 0–2, plus permissions and loop detection):

```
Prompt -> Agent -> Model (local Ollama) -> Tools (sandboxed) -> Observation -> Agent -> Result
```

## What's included

| Component        | Tech (all free/OSS)                       |
|-------------------|-------------------------------------------|
| Local model server| Ollama (Apache-2.0)                       |
| Agent runtime     | FastAPI + Python, custom agent loop        |
| Durable state     | SQLite via SQLAlchemy (swap to Postgres later, same models) |
| Sandbox (dev)     | Debian 13 (trixie) **graphical desktop** container: Xvfb + openbox + tint2 dock + Thunar + xfce4-terminal + Chromium, non-root user `box`, `/workspace` home |
| Sandbox (prod)    | **Firecracker microVMs** — per-task VM, own kernel, jailed VMM, CoW rootfs, snapshot pause/resume (`shellhouse/docs/FIRECRACKER.md`) |
| Desktop streaming | x11vnc + noVNC (embedded in the UI; click in to take control) |
| Tools             | filesystem (list/read/write), `run_shell` (in-sandbox), `web_search` (DuckDuckGo via `ddgs`), `fetch_url` (requests + BeautifulSoup), and computer use: `screenshot`, `list_windows`, `focus_window`, `open_app`, `click`, `type_text`, `press_key` (xdotool/wmctrl/scrot) |
| Permissions       | Policy engine: ALLOW / REQUIRE_APPROVAL / DENY per tool |
| Privilege split   | **Sandbox Manager** — the only component with the Docker socket; the agent loop has none (`shellhouse/docs/SECURITY.md`) |
| Durability        | Redis queue + worker processes; tasks survive an API restart and interrupted tasks are recovered |
| Memory            | Qdrant + local `nomic-embed-text` embeddings; structured evidence with provenance, confidence and relationships |
| Secrets           | Encrypted store (Fernet); values injected as sandbox env vars, never into model context |
| Integrations      | MCP client with per-server permissions; all MCP tools require approval by default |
| Evaluation        | 12 deterministic tasks across 4 suites (`evals/`), no LLM judges |
| UI                | Single static HTML page, polls the API (no build step) |

None of these require a paid account, license, or API key.

## Quick start

Requirements: Docker + Docker Compose. A GPU is optional but recommended for
larger local models.

```bash
git clone <this-repo>
cd Shellhouse/shellhouse
./setup.sh                 # generates MANAGER_TOKEN, detects the docker GID
docker compose up -d --build

# Pull a tool-calling-capable local model (first run only, takes a few minutes):
docker exec agent-ollama ollama pull qwen2.5:7b-instruct

# For semantic memory (small, CPU-friendly):
docker exec agent-ollama ollama pull nomic-embed-text

# Optional, for vision/computer-use:
docker exec agent-ollama ollama pull qwen2.5vl:7b
```

Then open:

- **Web UI (with live desktop): http://localhost:3000**
- Desktop only, full screen: http://localhost:6080/vnc.html
- API docs (Swagger): http://localhost:8000/docs

The desktop takes ~10 seconds after `up` to finish booting (X server →
openbox → dock → terminal + Thunar). Once it's up, the left panel of the UI
shows the agent's actual screen: dark wallpaper, a terminal sitting in
`/workspace`, Thunar next to it, and a small dock at the bottom with
Chromium / Thunar / Terminal. **Click anywhere inside that panel to take over
the mouse and keyboard yourself** — you and the agent share one desktop.

Type a goal like:

> Search for three open-source vector databases, note their licenses, and write a short comparison to notes.md

The agent will call `web_search` / `fetch_url` automatically. If it ever
calls `run_shell`, the UI will show an **Approve / Deny** prompt before
anything executes inside the sandbox container.

To exercise the graphical side specifically, ask for something that needs the
GUI, e.g.:

> Open the browser to news.ycombinator.com, take a screenshot, and save the top five story titles to hn.md

You'll see Chromium launch on the live desktop while the trace on the right
shows `open_app` → `screenshot` → `list_windows` → `write_file`.

## Model choice

Any Ollama model works for plain chat, but **tool calling requires a model
that supports it**. Good free options to `ollama pull`:

- `qwen2.5:7b-instruct` (default, good balance of speed/quality on CPU or a mid GPU)
- `llama3.1:8b-instruct`
- `mistral-nemo`
- `firefunction-v2` (built specifically for reliable function calling)

Switch models per-task from the dropdown in the UI, or set `OLLAMA_MODEL` in
`.env` for the default.

## Switching to Firecracker isolation

The agent runtime talks to a `SandboxProvider` interface, never to Docker
directly, so the execution substrate is one env var:

```bash
# Set on the sandbox-manager service, not the api — the agent loop does not
# get to choose its own isolation level.
SANDBOX_BACKEND=docker        # default: shared-kernel container
SANDBOX_BACKEND=firecracker   # per-task microVM
```

Firecracker needs one-time host setup (and a host with `/dev/kvm` — most
standard cloud VMs can't do this):

```bash
cd shellhouse/sandbox/firecracker/scripts
sudo ./setup-host.sh      # firecracker + jailer, bridge, NAT, nftables egress policy
sudo ./build-kernel.sh    # -> /var/lib/agent-vm/vmlinux
sudo ./build-rootfs.sh    # -> /var/lib/agent-vm/rootfs.ext4 (same desktop image)
```

The guest image is built from the *same* desktop Dockerfile, so the agent's
computer looks identical either way — only the isolation boundary changes.
Read `shellhouse/docs/FIRECRACKER.md` before enabling it: it covers the staged rollout,
the isolation checks you should actually run, the leaked-VM reaping gap, and
why VM control belongs in a separate Sandbox Manager rather than in the API
container.

## How it maps to the bigger architecture doc

This repo intentionally does **not** implement everything in
`shellhouse/docs/ARCHITECTURE.md` — Firecracker microVMs, multi-agent orchestration,
Qdrant/vector memory, MCP, billing, Cloudflare edge, etc. Those are the
"Phase 3+" items. What's here is the smallest version of the loop that
proves the concept end-to-end and is structured so each later phase slots in
without a rewrite:

- `agent/model_gateway.py` — swap/extend for vLLM or another local
  OpenAI-compatible server; still no cloud calls.
- Tasks are event-sourced (`TaskEvent` table) — a full observability/tracing
  layer (OpenTelemetry, Langfuse) can subscribe to the same event stream.
- Tool execution already goes through `agent/policy.py` — add more nuanced
  rules or per-user policies there.
- `sandbox-manager/app/providers/` implements the `SandboxProvider`
  abstraction with both a Docker and a Firecracker backend, so Phase 7 is a
  config change plus host provisioning rather than a rewrite.

## Security notes (read before exposing this beyond localhost)

Full write-up in **`shellhouse/docs/SECURITY.md`**, including commands to verify the
claims below yourself. The short version:

- **The agent loop holds no host privilege.** The API container has no Docker
  socket, no host mounts, and `cap_drop: ALL`. All sandbox operations go
  through the `sandbox-manager` service over a unix socket (no TCP), which
  authenticates every call and will only touch sandboxes it created itself.
  This matters because the API is the component reading untrusted web pages.
- **Everything binds to 127.0.0.1.** Nothing in this stack is reachable from
  your LAN as shipped.
- **There is no API authentication.** That's a deliberate call for a
  single-user loopback deployment — and a hole the moment you expose port
  3000 or 8000. Add auth first if you do.
- Content from `web_search`/`fetch_url` is explicitly treated as **untrusted
  data** in the system prompt, not instructions — but no prompt is a
  complete prompt-injection defense. Don't hand this agent real credentials
  or connect it to anything you're not prepared to have it misuse.
- `run_shell` always requires human approval by default. Don't relax that
  policy without understanding what you're exposing.


## Architecture at a glance

```
  web (3000)                 you
      |
      v
  api (8000) ----enqueue----> redis ----claim----> worker(s)
      |                                               |
      |  no host privilege                            |  runs the agent loop
      |                                               v
      +--------- unix socket ------> sandbox-manager (privileged)
                                           |
                                           v
                                   sandbox: Debian desktop
                                   (Docker container, or
                                    Firecracker microVM)

  ollama (11434)   local models, chat + embeddings, no cloud calls
  qdrant (6333)    vector memory
```

Ports are all bound to `127.0.0.1`.

## Phase status

| Phase | State |
|---|---|
| 0 — Architecture skeleton | Done |
| 1 — Tool calling | Done (17 tools) |
| 2 — Computer (desktop, browser, vision) | Done |
| 3 — Durable tasks | Done (queue, workers, recovery, budgets, cancel, compaction) |
| 4 — Memory | Done (Qdrant, evidence, recall, user memory) |
| 5 — Permissions & secrets | Done (policy engine, approvals, encrypted secrets, network policy) |
| 6 — MCP | Client done; needs a real server to validate against |
| 7 — Firecracker sandbox | Implemented, unrun (needs `/dev/kvm` host) |
| 8 — Multi-agent | Not started (deliberately — ADR-005) |
| 9 — Cloud | Not started |

**Nothing here has been executed.** Everything is syntax-checked and
cross-checked (tools↔schemas↔policy all reconcile), but a first build will
find real issues. `shellhouse/docs/BUILD-NOTES.md` lists what I expect to break and in
what order to debug it.

## Evaluation

```bash
python shellhouse/evals/run_evals.py --all --model qwen2.5:7b-instruct --out baseline.json
# after changing a model, prompt, or tool:
python shellhouse/evals/run_evals.py --all --compare baseline.json
```

Checks are deterministic — files created, strings present, tools called,
budgets respected, policy not tripped. No LLM judges, because scoring a local
model's output with the same local model mostly measures self-consistency.
