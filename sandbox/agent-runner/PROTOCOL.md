# Shellhouse agent runner: protocol v1

Status: implemented in `src/shellhouse_agent`; the Swift side is `SmolAgentsEngine` in `macos/Sources/AgentCore/Engine/`. This file is the source of truth. Drafted with AI assistance (Claude Code); review before relying on it.

The runner executes in an **untrusted** container and the run directory is readable and writable by the model's own tools. Swift must treat every runner-written value as untrusted data: size-cap it, validate it, never execute it.

## 1. Run directory

`/workspace/.shellhouse/runs/<run_id>/` (any path works; the final component must equal `run_id`).

| Path | Writer | Meaning |
|---|---|---|
| `config.json` | Mac, before launch | Run configuration (section 2). **Single use**: the runner rewrites it after loading, replacing `model.api_key` and every `env` value with `[scrubbed-by-runner]`, so the model cannot read them through its tools. To retry a run, write a new config. |
| `pid` | runner | PID of the runner process (decimal text, written atomically at start). Liveness check: `kill -0`. |
| `events/<8-digit seq>.json` | runner | One event per file (section 3). |
| `rpc/<id>.reply.json` | Mac | Reply to an `rpc_request` (section 4). |
| `cancel` | Mac | Existence means "stop" (section 5). Contents ignored. |

The runner creates `events/` and `rpc/`. The whole `.shellhouse/` tree is hidden from, and unreachable by, `list_files`/`read_file`/`write_file`; `run_shell` is not restricted, so the sandbox itself remains the boundary.

## 2. config.json

Strictly validated: unknown keys, wrong types, or `protocol != 1` fail the run (`error` with `fatal:true`, then `status failed`, exit code 2).

```json
{
  "protocol": 1,
  "run_id": "string, [A-Za-z0-9_-]{1,64}, equals the directory name",
  "model": {"base_url": "http(s)://host:port/v1", "api_key": "string (per-run token)", "model_id": "string", "temperature": 0.2},
  "system_prompt": "string, appended to smolagents' own tool-calling prompt as custom instructions",
  "history": [{"role": "user|assistant", "content": "string"}],
  "task": "string, non-empty; the new user message",
  "max_steps": 20,
  "planning_interval": null,
  "tainted": false,
  "workspace": "/workspace",
  "policy_free": ["read_file", "list_files"],
  "bridge_tools": [{"name": "recall_memory", "description": "...", "parameters": {"type": "object", "properties": {"query": {"type": "string", "description": "..."}}, "required": ["query"]}}],
  "in_sandbox_tools": ["run_shell", "read_file", "write_file", "list_files"],
  "env": {"NAME": "value"}
}
```

Optional additive keys (defaults shown): `"rpc_timeout_s": 1800` (number in (0, 86400]), `"vision": false` (attach the newest screenshot to the model's next prompt; only enable for vision models).

Notes:
- `max_steps` 1..500; `planning_interval` null or >= 1.
- `in_sandbox_tools` is a subset of `run_shell read_file write_file list_files screenshot list_windows focus_window open_app click type_text press_key scroll`.
- `bridge_tools[].name` must be a Python identifier, unique, and not `final_answer` or an in-sandbox tool name. Parameter types map from JSON schema `string|integer|number|boolean|array|object` (anything else becomes "any"); parameters not in `required` are optional.
- `tainted` is informational for the runner (Swift enforces taint rules in its policy answers). `final_answer` is always available and never policy-checked.
- `env` is the only environment given to `run_shell` children, on top of fixed defaults `PATH=/usr/local/bin:/usr/bin:/bin HOME DISPLAY LANG=C.UTF-8 TERM=dumb`. The runner's own environment is not inherited. `use_secrets` is accepted by `run_shell` but ignored.
- Values in `model.api_key` and `env` (length >= 8) are redacted (`[redacted]`) from every event and from `run_shell` output.
- The file tools also accept the spelling `/workspace/...` when `workspace` is elsewhere.

## 3. Events

Each event is written to `events/.<seq>.tmp` then `os.replace`d to `events/<seq as 8 digits>.json`, so a reader never sees a partial file. `seq` starts at 1, is gap-free and strictly increasing (a restarted runner continues from the highest existing file). Event files larger than 256 KB are shrunk (long strings truncated, `"truncated": true`).

Common fields: `seq` (int), `ts` (unix seconds, float), `type`.

| type | Fields | Notes |
|---|---|---|
| `status` | `state`: `planning\|executing\|waiting_policy\|completed\|failed\|aborted`; `detail?` | First event is `executing` (or `planning` when `planning_interval` is set). `waiting_policy` (detail = tool name) is emitted with each `rpc_request`, followed by `executing` once answered. **Exactly one terminal status (`completed`, `failed`, `aborted`) is the last event of a run.** |
| `message_delta` | `text` | Streamed model text, coalesced to >= 100 ms windows. Informational; the following `message` is authoritative. |
| `message` | `role:"assistant"`, `content`, `tool_calls?: [{id,name,args}]`, `kind?: "plan"` | Emitted when the model finishes a reply, before its tools run. `kind:"plan"` marks a planning-step output. |
| `tool_started` | `name`, `args` | Always precedes the `rpc_request` for that call. |
| `tool_completed` | `name`, `result` | `result` is the JSON the model sees. Denial: `{"error":"denied: <reason>"}`. |
| `rpc_request` | `id`, `kind: "policy_check"\|"bridge_call"`, `name`, `args` | Runner waits for the reply (section 4). |
| `final` | `summary`, `outcome: done\|blocked\|needs_user_input\|silent`, `reason?`, `usage?` | From `final_answer`. If the step limit is hit: `outcome:"blocked"`, `reason:"max_steps"`. `usage` = `{input_tokens, output_tokens, model_calls, seconds}`. |
| `error` | `message`, `fatal: bool` | `fatal:false` = a recoverable step problem (bad tool arguments, model replied without a tool call, empty answer); the run continues. `fatal:true` is followed by `status failed`. |
| `truncated` | `seq`, `reason` | Only ever produced by `tail`, never written to disk (section 6). |

Terminal mapping (mirrors Swift `finish_task`): `final.outcome == done` -> `status completed`; any other outcome -> `status aborted` with `detail` = the outcome (`max_steps` for the step limit); cancel -> `status aborted` `detail:"cancelled"` (no `final`); unrecoverable error (model unreachable, bug) -> `error fatal:true` then `status failed`.

Plain text without a tool call never ends a run: the model is told to call `final_answer` (surfaced as a non-fatal `error`).

## 4. RPC: policy checks and bridge calls

For every tool call **not** in `policy_free` (and not `final_answer`) the runner emits `rpc_request {id, kind:"policy_check", name, args}` and blocks. For a bridge tool it emits `kind:"bridge_call"` (always, regardless of `policy_free`); Swift both policy-checks it and, on allow, executes it.

Mac replies by atomically writing `rpc/<id>.reply.json`:

```json
{"id": "<same id>", "decision": "allow|deny", "reason": "optional string", "result": "any JSON, bridge_call only"}
```

- `policy_check` + `allow`: the runner executes the tool. `deny`: the model gets `{"error":"denied: <reason>"}` and nothing executes.
- `bridge_call` + `allow`: the model gets `result` (`{"ok":true}` if absent). `deny`: same denial result.
- The runner polls every <= 100 ms. A reply that is not yet valid JSON (partially written) is retried. A reply with the wrong `id`, a `decision` other than allow/deny, or > 1 MiB is treated as **deny**.
- No reply within `rpc_timeout_s` (default 1800) => deny (`reason: "timed out ..."`).
- `id` is 12 hex characters chosen by the runner. Parallel tool calls produce several outstanding requests.

## 5. Cancel

Creating `cancel` makes the runner stop at the next opportunity: while waiting for an RPC reply, between model-stream chunks, while a `run_shell` child runs, and at step boundaries. It kills every `run_shell` process group it started, emits `status aborted` (`detail:"cancelled"`) and exits 0. SIGTERM to the runner does the same.

## 6. Commands

Start (detached by the Mac, e.g. `nohup ... &`):

```
python3 -m shellhouse_agent run --dir <run_dir>
```
Exit code 0 for any ended run (done, blocked, cancelled), 1 for an unrecoverable runtime error, 2 for an invalid config. All outcomes are also reported through events; stdout/stderr carry nothing needed.

Read events (bounded):

```
python3 -m shellhouse_agent tail --dir <run_dir> --after <seq> --max-bytes <n>
```
Prints, as JSON lines, events with `seq > after` in order, at most `n` bytes of event data, then one final line:

```json
{"tail_done": true, "last_seq": 17, "finished": false}
```
`last_seq` is the last seq consumed (== `after` if none). `finished` is true only when the last event on disk is a terminal `status` and it has been delivered. If a single event is larger than `n`, it is replaced by `{"seq":N,"type":"truncated","reason":"..."}` so the reader always advances. A reader loops `--after <last_seq>` until `finished` (checking the `pid` file for a runner that died without a terminal status).

## 7. Tools and limits

Mirrors `Sources/AgentCore/Tools/ToolRegistry.swift`. File tools resolve with `realpath` before checking containment, so `..` and symlinks leading outside the workspace are rejected (`path escapes /workspace`); `.shellhouse/` is reserved.

| Limit | Value |
|---|---|
| `read_file` | 200,000 bytes (`truncated:true` beyond); regular files only |
| `write_file` | 2,000,000 bytes; atomic replace; creates parent dirs |
| `list_files` | 1,000 entries; directories end with `/` |
| `run_shell` | `timeout` default 120 s, clamped 1..1800 s; process-group SIGKILL on timeout/cancel; 20,000 chars returned per stream (1 MB retained); stdin is /dev/null; cwd = workspace; result `{exit_code,stdout,stderr}` or `{error,timed_out:true,stdout,stderr}` |
| any tool result to the model | 100,000 chars |
| GUI tools | same `xdotool`/`wmctrl`/`scrot`/`ai-click.py` commands as Swift (no shell involved); when a binary is missing they return `{"error":"<bin> is not available in this environment"}` |

`final_answer(answer, outcome?)` replaces smolagents' built-in: `outcome` in `done|blocked|needs_user_input|silent` (default `done`); an empty `answer` is rejected (except for `silent`) and the model must retry.

## 8. Not covered in v1

Resume of a half-finished run (config is single use), multiple concurrent runs per directory, `CodeAgent`, MCP tools, web tools, image attachments in `history`. Hard links created by the model between files in and outside the workspace are not detected.
