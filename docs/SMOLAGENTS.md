# smolagents as the agent backbone (design, pilot scope)

Status: **pilot, exercised end to end and compared against the built-in engine (October 2026, see [Evaluation results](#evaluation-results-october-2026)). Kept as an opt-in engine; not the default.** Drafted and built with AI assistance (Claude Code); review before relying on it. Implemented: Swift `AgentEngine` seam, `SmolAgentsEngine`, `ModelProxy`, reverse-forward support, per-bot Engine setting, Settings › Agent engine, and the Python runner in `sandbox/agent-runner/` (see its `PROTOCOL.md` and `SPIKE-RESULTS.md`).

Decisions already made:

| Question | Decision |
|---|---|
| Where smolagents runs | **Inside each bot's own sandbox container** |
| Scope | **Pilot: a per-bot engine switch** (`Built-in` \| `smolagents`), not a replacement |
| Agent style | **`ToolCallingAgent` first**; `CodeAgent` later |

## Why the shape is what it is

- The Swift `AgentRuntime` owns more than a loop: approvals, run-lock, budgets, repeat detection, context compaction, and the event stream the UI and Debug Console consume. smolagents provides none of the approval/policy/secrets/routines/group/goal machinery (it is an agent loop + tools + model wrappers). So those stay in Swift.
- `docs/MACOS-NATIVE.md` rejects embedding Python in the signed app. Running smolagents **in the sandbox container** keeps the Mac app pure Swift.
- smolagents' own guidance: the safe way to run model-written code is a sandbox, and *managed (multi-)agents* require the whole agent system inside it. Each bot already has a persistent Docker sandbox on the Linux host, so that is the natural home.
- **Honest caveat:** with `ToolCallingAgent` (no model-written code) running in the container buys little isolation, because tools are fixed wrappers. The placement pays off when `CodeAgent` is added. We take the placement now so that step is cheap.
- smolagents' multi-agent feature does **not** help across bots: each bot has its own container and model. `message_bot`, group turns and goals stay Swift-orchestrated; the engine is just what runs one bot's turn.

## Architecture

```
Mac (Swift)                                         Linux host
┌──────────────────────────────────┐   SSH tunnel  ┌──────────────────────────── bot container ┐
│ Bot ── AgentEngine (new protocol) │──────────────▶│ sandbox-manager /v1/exec, read/write_file │
│   ├─ BuiltInEngine  (AgentRuntime)│               │                                           │
│   └─ SmolAgentsEngine             │   events.jsonl│  shellhouse-agent runner (Python)               │
│        launch / poll / answer     │◀──────────────│   └─ smolagents ToolCallingAgent          │
│ Policy · ToolRegistry             │   rpc/*.json  │        ├─ in-sandbox tools (shell, fs, GUI)│
│ Memory · Routines · Secrets · UI  │──────────────▶│        └─ bridge tools (Mac-side state)    │
│ Model proxy (token-gated)  ◀──────┼── ssh -R ─────┼── OpenAI-compatible calls ────────────────│
└──────────────────────────────────┘               └───────────────────────────────────────────┘
```

### 1. Transport: files, not a new network channel (MVP)
The existing manager API only has request/response `exec`, `read_file`, `write_file`. The runner is started detached via `exec` and talks through `/workspace/.shellhouse/runs/<run_id>/`:

- `events.jsonl` (runner → Mac): `status`, `message_delta`, `message`, `tool_started`, `tool_completed`, `approval_needed`, `rpc_request`, `finished`. Same shapes as `AgentRuntime.Event`, so the UI and Debug Console need no changes.
- `rpc/<id>.json` (Mac → runner): replies to approvals and bridge calls.
- `cancel` file: Stop button.

Polled at ~0.5 s through the existing tunnel. Durable across tunnel drops and Mac sleep (bots keep working). A streaming endpoint (`/v1/exec_stream`) is a later optimization.

### 2. Tools
- **In-sandbox tools** run natively in the container: `run_shell`, `read_file`, `write_file`, `list_files`, screenshot/window/click/type/key/scroll (port the exact commands from `ToolRegistry.swift`).
- **Bridge tools** execute in Swift: `remember`, `recall_memory`, tasks, routines, `list_bots`, `message_bot`, `create_bot`, `post_to_group`, `use_skill`, secrets, goal tools. The runner sends `rpc_request`; Swift runs the existing implementation and replies.
- **Policy stays Swift's.** Before any approval-tier tool the runner sends a `policy_check`; Swift's `Policy` answers allow/deny or raises the approval card, then the runner proceeds. Untrusted-run rules (friend messages → always ask) are passed in the run config.
- **Rule:** anything touching Mac state, memory, or secrets is enforced in Swift. In-container gating of in-sandbox tools is sound for `ToolCallingAgent` (fixed wrappers) but only best-effort once `CodeAgent` exists, because model-written Python could call `subprocess` directly. Treat the container as untrusted either way.

### 3. Model access (the hard part)
Ollama (and any remote provider) lives on the Mac; the container is on another machine and must not get raw model credentials.

- Mac app runs a small **model proxy** (OpenAI-compatible `/v1/chat/completions`, `/v1/models`) bound to loopback.
- `SSHTunnel` adds a reverse forward (`-R`) so the Linux host exposes it to containers on the docker bridge. Needs sshd `GatewayPorts clientspecified` (or equivalent) on the host, and the bound address must be the bridge gateway only.
- Each run gets a **per-run bearer token** (stored in the run config, discarded at finish). The proxy enforces: model allow-list = the bot's selected model, max tokens/requests = the bot's budget, no pull/delete/other Ollama routes.
- Remote-provider API keys stay in the Mac Keychain; the proxy adds them upstream. Nothing secret enters the container or model context.
- Rejected alternatives: exposing Ollama on the LAN (`OLLAMA_HOST=0.0.0.0`) and putting API keys in container env (smolagents' sandbox guide lists this as a downside of running everything inside).

### 4. Swift seam
```swift
protocol AgentEngine {            // what Bot talks to
    func run(messages: [ChatMessage], budgets: Budgets,
             onEvent: @Sendable (AgentRuntime.Event) -> Void,
             requestApproval: ...) async
    func cancel()
}
```
`AgentRuntime` conforms unchanged; `SmolAgentsEngine` is new. `BotConfig.engine` (default `.builtin`) persists the choice; Bot settings > Model gets an **Engine** row. Run-lock, group turns, delegation, routines and the Debug Console are untouched because they sit above the seam.

### 5. Grounding gains (what smolagents actually adds)
Web search and page-visiting tools, MCP tools via `ToolCollection.from_mcp`, periodic re-planning (`planning_interval`), step callbacks mapped to events. MCP servers must be reachable from the container or bridged through Swift (decide per server; MCP tools stay approval-gated as today).

## Phases and gates

| Phase | Work | Gate |
|---|---|---|
| **0 Spike** (no app changes) | Standalone runner + `ToolCallingAgent` + Ollama via an OpenAI-compatible model class, run the 12 tasks in `evals/` against the same local models the bots use; compare pass rate, steps, tokens vs the Swift runtime (`aic`) | **Go/no-go.** If small local models do clearly worse, stop here |
| 1 Sandbox + protocol | Add runner + smolagents to the sandbox image; event/RPC file protocol; Python-side tools | Runner passes phase-0 evals inside a real bot container |
| 2 Proxy + tunnel | Model proxy, per-run tokens, `-R` forward, budget enforcement | Container can call only the allowed model; token expires at run end |
| 3 Swift engine | `AgentEngine` seam, `SmolAgentsEngine`, bridge + policy RPC, Engine setting | One bot runs end-to-end incl. approvals, Stop, resume after tunnel drop |
| 4 Parity | Budgets, repeat detection, compaction seeding, vision/screenshot attach, crash recovery, group turns | Side-by-side with Built-in on the evals and real use |
| 5 Decide | Make default, keep as option, or drop | Your call |

## Evaluation results (October 2026)

**Decision: keep smolagents as an opt-in pilot; the built-in engine stays the default.** Both engines answer
equally well. smolagents was faster at first, but only because it ends a turn in one model call; once the
built-in engine got the same ability, it became the faster of the two.

**Setup.** `macos/Tests/AgentCoreTests/EngineABEval.swift` (run with `SHELLHOUSE_EVAL=1`, see its header) drives
both engines through the app's own code: `AgentRuntime` against Ollama, and `SmolAgentsEngine` with the
runner in a real sandbox, reached through the token-gated `ModelProxy` over the reverse SSH forward. One
throwaway sandbox, reset before every run; same model (`qwen3.8:27b-mlx`), system prompt, bundled skills
and auto-approval. 12 tasks adapted from `evals/` (the originals call Python-stack-only tools): files (3),
shell and data (3), desktop GUI (2), web lookup (1), safety (prompt injection, invented facts, false
premise). Each answer is checked against the sandbox's real state. 2 trials per task.

| | Built-in (before) | smolagents | Built-in (after) |
|---|---|---|---|
| Passed | 23/24 | 23/24 | **24/24** |
| Total time | 1,751 s | 1,224 s | **501 s** |
| Median run | 38.5 s | 24.6 s | **18.1 s** |
| Tool calls per task (mean) | 3.8 | 2.5 | 2.8 |

"After" is the built-in engine with `answerEndsTurnAfterTools`: a substantial plain-text answer ends the
turn once tools have run in it, unless it reads as an announcement or its last sentence is a plan. Before,
every turn needed one more model call to resend the same answer through `finish_task`. The other
group-latency changes (cache-friendly prompts, batched collapsing) were also in place for "after".

**Findings**
- Answer quality was about equal. Both engines resisted the injected instruction every time, corrected the
  false premise, refused to invent an employee count, cited the PostgreSQL licence page, and fixed and
  re-ran the broken script.
- smolagents showed raw `Calling tools: [...]` text in two answers: smolagents writes earlier calls into the
  history as that text and local models copy it. Fixed in the runner and in the app.
- GUI work is weak on both with this model, because the bots don't have the "model has vision" setting on.
  Built-in fell back to reading the page's HTML; smolagents timed out once after a screenshot.
- Built-in once searched the web 22 times for a fictional company until it hit the wall-clock budget
  (before the change); smolagents hit the same problem once but answered honestly.
- smolagents had one proxy `502 upstream unavailable` on the very first request of an earlier run; it did
  not recur in 48 runs.

**Caveats.** Two trials per task on single-bot tasks with one model is a signal, not a benchmark. smolagents
still runs 1:1 chats only; group turns, delegations and routines always use the built-in engine.

## Verify before building (not confirmed from docs)
- Exact model class/config for an OpenAI-compatible endpoint with Ollama, and whether LiteLLM (another third-party dependency) is required. Prefer avoiding it.
- Streaming of partial output and per-step callbacks in the current release; how to pass prior conversation into `run`.
- Image observations (screenshots) for vision models; behavior of `final_answer_checks`.
- Behavior and token cost on 7B-class local models; `CodeAgent` quality on them.
- Stopping a run mid-step cleanly (we plan a cancel file + process kill).

## Security: guardrails come first
The full guardrail design (effect classes, taint tracking, deny/ask rules, egress allowlist, budgets, audit, red-team tests) is in [`GUARDRAILS.md`](GUARDRAILS.md). **Its build order puts the Swift policy engine v2 and the egress/credential containment before Phase 1 here**, because moving the loop into the container makes the container's reach, not the loop's own checks, the real boundary.

## Disclosure and security notes
- **New third-party dependency:** `smolagents` (Hugging Face, PyPI) and its transitive packages, installed into the sandbox image. Check its license and pin versions before shipping.
- **Not used:** the optional hosted executors (E2B, Modal, Blaxel). The bot's own Docker sandbox is the executor.
- New network path (reverse tunnel + proxy) widens the attack surface; run it past your Information Security team before enabling beyond a dev machine.
- Event logs and RPC files live in `/workspace`, which the sandbox (untrusted) can read and write. Treat every runner-supplied value as untrusted data in Swift: size-cap, validate, never execute.

## Trying the pilot
The steps below have been run against a real sandbox image and sshd (October 2026 evaluation). Needs InfoSec review before enabling beyond a dev machine (new dependency and a new network path).
1. **Build the sandbox image** from the repo root (`sandbox/Dockerfile` has an unbuilt runner section). Regenerate `sandbox/agent-runner/requirements.lock` on Linux, review the transitive packages (the macOS lock includes `httpx2`/`httpcore2`, which need a supply-chain check), and pin hashes.
2. **sshd on the Linux host:** `GatewayPorts clientspecified` so the Mac's reverse forward can bind to the docker bridge gateway address.
3. **In the Mac app:** Settings › Agent engine: enter the bridge gateway address (private IPv4 only) and port, Save & reconnect. If you run the egress allowlist (`docs/EGRESS.md`), enable the model relay and enter its alias in "Address sandboxes use".
4. **Per bot:** Bot settings › Model › Engine → smolagents (local Ollama models only in this pilot). 1:1 chat only; group turns, delegations and routines still use the built-in engine.
5. **Phase-0 gate (answered):** see [Evaluation results](#evaluation-results-october-2026). Previously: the spike (`sandbox/agent-runner/SPIKE-RESULTS.md`) shows the plumbing works with two small local models on six easy tasks, not that smolagents beats the built-in loop. Run the 12 tasks in `evals/` against both before deciding anything.

Security notes specific to this engine: the runner is untrusted. Hard guarantees come from what the container can reach (workspace, egress allowlist, token-gated proxy) and from Swift-side enforcement of bridge tools, secrets, memory and routines. In-container approval of in-sandbox tools is advisory against a compromised runner and gets weaker with `CodeAgent`. The per-run model token sits briefly in `config.json` before the runner scrubs it, and `run_shell` can read process memory, so treat a leaked token as bounded (one model, request/token budget, short TTL) rather than impossible.
