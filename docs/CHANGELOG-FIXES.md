# Fixes 1–3

> **Historical.** The "(fix 1/2/3)" labels in `.env.example`,
> `docker-compose.yml` and `api/` comments refer to this document.

Three changes, in dependency order. None of this has been executed — it is
written carefully, syntax-checked, and reviewed, but a first build will find
things. Assumptions that a build will confirm or break are marked **[unverified]**.

---

## Fix 1 — Per-task sandbox lifecycle

**Was:** `tools.py` called `provider.create(task_id="default", persistent=True)`
once and cached the handle in a module global. Every task shared one computer;
the ephemeral/persistent distinction and Firecracker's per-VM design had no
caller.

**Now:**

- `AgentRuntime._attach_sandbox()` creates a sandbox per task on start and
  records `sandbox_id` / `vnc_url` on the task row; `_release_sandbox()`
  destroys it in the loop's `finally` when the task reaches a terminal state.
  Persistent computers are never destroyed. Cleanup failures are logged, not
  raised — a successful task should not report failure because teardown
  hiccuped.
- Sandbox binding moved from a module global to a `contextvars.ContextVar`
  (`set_active_sandbox()`), so concurrent tasks on different computers cannot
  act on each other's desktop.
- `DockerBackend` was rewritten to actually create fresh containers:
  per-task name, own noVNC port from a pool (6100+, loopback-only), own
  workspace subdirectory, `mem_limit` / `nano_cpus` / `pids_limit` ceilings,
  `cap_drop: ALL`, and Docker labels for discovery.
- `reconcile()` reaps orphaned ephemeral containers at manager startup;
  `list_sandboxes()` + `/v1/list` + `GET /sandboxes` expose what's running.
- File tools no longer read the host filesystem. They go through the provider,
  because a per-task sandbox's workspace isn't necessarily a path the API
  container can see. `_safe_path` → `_safe_rel`.
- UI gets a Fresh-vs-Persistent computer selector, and the desktop view now
  follows the active task's own noVNC URL.

**[unverified]** The `WORKSPACE_VOLUME` name is project-prefixed by compose;
the setup script (now `write_stack_env` in `scripts/host-setup.sh`) guessed it from the directory name. Check with
`docker volume ls | grep workspace` after first start.

**[unverified]** Ephemeral containers symlink `/workspace` to
`/workspaces/<task>` after boot. The desktop starts before that symlink
exists, so the pre-opened terminal and Thunar may be showing the old path
until reopened. Likely needs the symlink created in the image instead.

**Known tradeoff:** per-task sandboxes share one workspace volume and are
separated by subdirectory, not by a mount boundary — the API serves
screenshots off that volume. Fine for single-user local use, not for
multi-tenant.

---

## Fix 2 — Loop control: cancel, budgets, compaction

**Was:** `cancel` wrote `status=CANCELLED` and the running loop never looked,
so it kept going. The only limit was a 20-iteration cap. Context grew forever,
so long tasks would eventually exceed the model's window and start failing
mid-run with no explanation.

**Now:**

- **Cooperative cancellation.** `POST /tasks/{id}/cancel` sets
  `cancel_requested`. `_check_budgets()` re-reads the row at the top of every
  iteration and before every tool call, so the task stops at the next safe
  point instead of being killed mid-tool-call — and its sandbox gets released
  on the way out. A task parked on an approval has no running loop to notice,
  so that case is marked cancelled directly and its sandbox reaped by the
  endpoint.
- **Budgets:** iterations (40), wall clock (1800s), tokens (200k), all env-
  tunable. Each raises `TaskAborted` with a distinct status
  (`CANCELLED` / `TIMED_OUT` / `FAILED` / `BLOCKED`) and a recorded reason, so
  "it just stopped" is always answerable.
- **Token accounting** is real now: `ModelGateway` surfaces Ollama's
  `prompt_eval_count` / `eval_count` as `_usage`, which the runtime sums onto
  the task.
- **Context compaction:** when the serialized conversation exceeds
  ~48k chars, the middle is summarized by the same local model into one dense
  working-memory message, keeping the system prompt, the goal, and the last 8
  turns verbatim. Compaction happens *before* the model call that would have
  overflowed. If summarization itself fails, the oldest middle is dropped
  rather than letting context grow unbounded.
- **Loop detection** now raises `BLOCKED` through the same abort path, so it
  releases the sandbox like every other exit.
- `_run_async` uses one module-level thread pool instead of building and
  tearing one down per tool call.

**[unverified]** Token counts assume Ollama populates `prompt_eval_count` and
`eval_count` on `/api/chat` responses. If a model or version omits them the
token budget silently never triggers — the iteration and time budgets still
do.

---

## Fix 3 — Vision: the agent can see its screen

**Was:** `screenshot` returned a filename. The model never saw an image, so
every `click` was a guess at coordinates. This was the biggest hole in the
computer-use story.

**Now:**

- After a successful `screenshot`, the runtime reads the PNG back through the
  provider and appends a user-role message with the image attached
  (`images: [base64]`, which is how Ollama takes them), telling the model the
  coordinates in it are absolute screen coordinates it can pass to `click`.
- If the active model is not vision-capable, the screenshot is still saved but
  the observation says so explicitly and points the agent at `list_windows`
  instead — silently useless was worse than a clear message.
- Vision capability is detected by substring match on the model name
  (`VISION_MODEL_HINTS`), since Ollama's API doesn't advertise modality.
- `MODEL_TIMEOUT_SECONDS` default raised to 600 — vision prompts on CPU
  inference are slow.

**[unverified]** Tool-calling *and* vision in the same request is the weak
point. Some local models support one or the other but degrade badly with both.
Pull `qwen2.5vl:7b` to try it; if tool calls stop working when images are
attached, the fallback is a two-model split (vision model describes the
screen, tool-calling model acts on the description).

**Note:** screenshots are full-resolution 1280x800 PNGs, capped at 4MB. No
downscaling is done, so they eat a lot of context on a small model. Resizing
before attachment is an easy follow-up.

---

## Still outstanding

1. **No queue/worker.** Tasks still run via `asyncio.create_task` in a request
   handler, so they die with the API and nothing replays persisted state on
   restart. This is the next fix, and it's the last structural one.
2. **No tests, never built.** Zero automated coverage; a model swap could
   regress quality with nothing to catch it.
3. **No VM management UI.** `GET /sandboxes` exists; nothing renders it. No
   New/Destroy buttons.
4. **Phases 4–6** unstarted: memory/Qdrant, secret manager, MCP.
