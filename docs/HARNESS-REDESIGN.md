# Harness redesign

Status: proposal, October 2026. Phases 1 and 2 are implemented (see section 7). Internal Use Only. Drafted with AI assistance (Claude Code); review before acting on it.

Sources are listed at the end. Most search results were summaries of the original posts, so details marked
*(secondary)* should be checked against the original before they are quoted or relied on.

## 1. What the best harnesses have in common

| Principle | What it means | Source |
|---|---|---|
| **The log is the memory** | State is an append-only event log. The prompt is a view of that log. Summaries and drops are events in the log, not edits to it. | OpenHands event stream and condenser events |
| **Cache-stable context** | Keep the start of the prompt byte-stable. Append, don't rewrite earlier turns. A one-token change early in the prompt invalidates the cache after it. | Manus (KV-cache is the top production metric; about 100:1 input to output) |
| **Right tokens, not more tokens** | Context rots as it grows. Load code and data just in time (glob, grep), compact deliberately, keep notes outside the window, send sub-agents on side tasks that return a summary. | Anthropic, context engineering |
| **State outside the model** | A long task survives sessions through files: a feature list that starts failing and flips to passing, a progress note, an init script, git history. Tests can't be edited to pass. | Anthropic, harnesses for long-running agents *(secondary)* |
| **Verify with code, not words** | "Done" needs a check the harness ran and read. A deterministic verifier per task. | Goose recipes, Roo, Anthropic harness post, tau-bench state comparison |
| **Single writer, shared context** | Parallel agents that each decide things separately produce conflicts. Several agents can contribute thinking, but writes stay single-threaded and every agent sees the others' traces. | Cognition (original and the April 2026 follow-up) |
| **Parallelize only what splits** | An orchestrator with parallel workers beat a single agent on breadth-first research but cost about 15x the tokens, and is weak on tightly coupled work like code. | Anthropic multi-agent research system *(secondary)* |
| **Tools are designed for agents** | Few, well-named tools, forgiving input, actionable errors, compact results. | Anthropic, writing tools for agents; SWE-agent |
| **Measure consistency** | Score pass^k (all k tries succeed), grade final state, and check budget, tool use and invariants, not just the transcript. | tau-bench and eval-harness write-ups *(secondary)* |

## 2. Where Shellhouse stands

Strong already: guardrails and approvals, edit and read tools, syntax checks, stuck detection, grounded
evidence for goal steps, evidence digests in group reports, replay-style telemetry.

Structural gaps, from the code:

1. **No event log.** `AgentRuntime` (about 1,400 lines) keeps a mutable `messages` array and rewrites it in place
   (`collapseStale`, compaction, screenshot pruning, removing a narration reply). That breaks prompt caching,
   makes runs impossible to replay exactly, and mixes four jobs in one class: model I/O, tool execution, guards,
   and state.
2. **Guards are inline and unstructured.** Nine places append a user-role nudge, plus about ten loose counters
   (`narrationStreak`, `finishGuardUsed`, `verifyGuardUsed`, `staleStreak`, ...). Each new rule adds more.
   There is no common shape for "what triggers, what it says, how it escalates, how it is tested".
3. **"Done" is judged by the model.** The new "changed code, ran nothing" gate is a heuristic. Goal steps have no
   command the harness can run to verify them.
4. **State lives in chat.** A goal's progress is in `GroupGoal` (good), but a single bot's long run has only its
   transcript and one summary. Nothing like a progress file the next run reads first.
5. **Writes are not single-threaded.** Members can edit the same repo from separate VMs; the only protection is
   prompt text and the validator.
6. **One harness for every model.** A 4B model and a 35B model get the same tool set, nudges and schemas.
7. **Evaluation is thin.** `EngineABEval` and the replay tests cover a handful of cases, with no pass^k, no
   recorded real runs, and no gate in CI.

## 3. The design

### 3.1 Event-sourced run core

```
RunLog (append-only events)  ->  ContextView (deterministic prompt builder)  ->  Model
        ^                                                                          |
        +------------------ Executor (tools, gates) <---------- actions -----------+
```

- **Events:** `userMessage`, `modelReply`, `toolCall`, `toolResult`, `nudge(kind)`, `condensed(range, summary)`,
  `verification(command, exit, output)`, `approval`, `stateNote`. Each has an id and a timestamp.
- **`ContextView`** builds the prompt from the log: stable system prefix, then events in order, with condensed
  ranges replaced by their summary event. The log itself is never edited, so a run can be replayed and audited, and
  the prefix stays byte-identical between steps. Collapsing old output becomes "render this range as a stub", which
  happens in batches and only at a boundary.
- **Persisted per run** (JSONL beside the transcript), which also feeds the debug console, telemetry and evals.

### 3.2 Guard pipeline

One protocol, a list of guards, a fixed order:

```swift
protocol Guard {
    var id: String { get }
    func beforeModel(_ ctx: RunContext) -> [GuardAction]       // e.g. context budget, step warnings
    func afterReply(_ reply: Reply, _ ctx: RunContext) -> [GuardAction]   // narration, repetition, duplicate calls
    func beforeTool(_ call: ToolCall, _ ctx: RunContext) -> [GuardAction] // validation, lint, repeat
    func afterTool(_ call: ToolCall, _ result: Result, _ ctx: RunContext) -> [GuardAction] // same error, stale, trash
    func beforeFinish(_ ctx: RunContext) -> [GuardAction]      // open plan, unverified change, verifier
}
enum GuardAction { case nudge(String, escalation: Int), rewrite(Call), replaceResult(String), abort(String), none }
```

- Each existing rule moves into its own guard with its own state and tests: `Narration`, `RepeatedCalls`,
  `SameError`, `StaleResults`, `OpenPlan`, `UnverifiedChange`, `ContextBudget`, `ToolCallRecovery`, `Trash`.
- Escalation is declared (soft nudge, specific nudge, restrict tools, stop), not coded per rule.
- Every firing is a `nudge` event in the log and a `loopEvent` counter, so a change shows up as numbers.
- `AgentRuntime` shrinks to: build view, call model, run the pipeline, execute allowed calls, append events.

### 3.3 Verified completion

- A task or goal step can carry a **verifier**: a shell command (or a built-in check such as "file exists",
  "HTTP 200") with the expected result. The harness runs it, records a `verification` event, and `finish_task`
  with outcome `done` is refused until it passes (or the plan says it can't be run).
- For goals, the owner writes each step as `{text, assignee, verify}` at intake (the Anthropic feature-list
  pattern). A step flips to done only when its verifier passes in the validator's VM. Test files are
  write-protected for the assignee after the step starts (the "don't edit tests to pass" rule).
- Keeps today's evidence grounding; this replaces judging by prose.

### 3.4 Durable working state

- A small **progress note** per bot and per goal under `/workspace/.shellhouse/`: what is done, what is next,
  commands that work, blockers. Written by a `note_progress` tool (and by the harness at stops), read first by
  the next run. This is the artifact the long-running-agent posts describe.
- Compaction summaries become `condensed` events, and the progress note is the thing that survives them.

### 3.4a Memory and note hygiene (context poisoning)

Added after review. Built: provenance and trust class, data-block rendering, write gate, replay tests, labelled `recall_memory`, 30-day expiry of unreviewed untrusted notes, stale marking, review/filter UI. Verify-before-relying built (see below). A note or memory that is wrong, injected or stale is read as an instruction on every
later run, so it is the longest-lived way to poison a bot. Rules, in the order they would be built:

- **Provenance on every entry.** `MemoryEntry.source` already exists ("self", "user", "delegation", "goal", "import").
  Add the run and event id that produced it and a trust class: `user` > `harness` > `self` > `delegation` / `import`
  / anything derived from tool output or a friend's message. Notes written while the run was tainted (`ToolGate`
  taint) are stored as `untrusted` and never pinned.
- **Memory is data, not instructions.** `ContextView` renders recalled memories and progress notes in a delimited block
  that names the source and age ("note from delegation, 3 days ago, unverified"), after the task, never inside the
  system prefix. A standing instruction only enters the prefix when it is pinned by the user.
- **Write gate.** A `remember` / `note_progress` call is a guard (`beforeTool`): refuse text that looks like an
  instruction aimed at a future run when the run is tainted, cap size, and log a `stateNote` event with the source.
- **Verify before relying.** (Built.) `remember` takes an optional `check`: a read-only command (`test`, `grep -q`,
  `command -v`, `git rev-parse`, `ls`, joined with `&&`; `MemoryCheck.isAllowed`) that the run already ran and saw exit 0
  (`MemoryCheck.wasProven`, read from the prompt) in a clean run, else the note is saved without it and the model is
  nudged (`memory_check_rejected`). When a note is recalled (the recall block or `recall_memory`) its check is re-run
  in the VM, at most 3 per recall and not within 10 minutes of a pass: a pass refreshes it, a failure marks it stale
  (`memory_check_failed`), no verdict (VM down) changes nothing. A passing check never raises trust. A tool result
  that says a path does not exist flags notes naming it "possibly stale" (`MissingPathGuard`, clean runs only; a hint,
  the note stays in place).
- **Expiry and review.** Untrusted and unverified notes expire; the user can see, filter by source and delete them.
- **Test it.** Replay fixtures where a tainted tool result tries to plant a memory; the run must end with no new
  trusted entry. Owner for the policy: security (information.security@allegiantair.com) should review the trust classes.


### 3.5 Multi-agent rules

- **Single writer per repo and branch.** A step that writes to a repo takes a lock on `(repo, branch)`; others read
  and review but can't push to it. Conflicts become impossible by construction, not by prompt.
- **Shared traces:** keep the evidence digest; add the decisions made (files chosen, commands run) to what the
  validator and owner see.
- **Effort scaling:** the owner states a budget per step (tokens or iterations) and a bot reports against it;
  parallel work only where steps are independent.
- Peer status (working now / idle) stays in every member's prompt.

### 3.6 Model capability profiles

A profile per model family (probed once, cached): tool-call reliability, context window, thinking mode, vision,
speed. It sets: how early nudges fire, whether tools are offered as the full set or a phase-specific subset,
schema simplification, how much history to keep, and whether to use a draft or fast tier for housekeeping. A 4B
model gets fewer tools and earlier, more explicit nudges; a large model gets fewer interruptions.

### 3.7 Evaluation as part of the harness

- **Recorded runs:** every run's event log can be exported as a fixture. Replay drives the harness with a
  scripted model and asserts on events (nudges fired, calls made, final state).
- **Task suite:** goal, setup, verifier triples that run against a real sandbox, run k times, report pass^k, steps,
  tokens and wall time per task. Start with 15 to 20 tasks drawn from real failures in the logs (screenshot,
  stale checkout, repeated read, goal stall, duplicate delegation).
- **Gate:** the replay tests run on every change; the live suite runs before a release.

## 4. Phases

| Phase | Work | Why first | Size |
|---|---|---|---|
| 1 | Event log and `ContextView` behind the existing runtime; log persisted; no behavior change | Everything else builds on it; makes runs replayable | L |
| 2 | Guard pipeline: move the nine nudge sites and counters into guards, one at a time, each with tests | Cuts the runtime's size and the cost of each new rule | L |
| 3 | Verifiers on tasks and goal steps; write-protect tests during a step | The biggest accuracy gain: "done" means a check passed | M |
| 4 | Progress notes and the cache-stable prompt rules (batch collapse at boundaries only) | Long runs recover; cheaper cloud calls | M |
| 5 | Repo write locks; capability profiles | Fewer multi-bot conflicts; fewer nudges for strong models | M |
| 6 | Recorded-run fixtures and the live pass^k suite | Proves each phase helped | M |

Phases 1 and 2 change structure only and must keep the 600-test suite green. Phase 3 changes behavior and is
measured with the phase 6 suite, so start the fixtures (small, from existing logs) alongside phase 1.

## 5. Risks

- Event sourcing adds storage and a migration for saved transcripts: keep the old transcript readable and write the
  log alongside it first.
- A guard pipeline can hide ordering bugs: fix the order in one place and test it with recorded runs.
- Verifiers can be wrong or slow: allow "cannot be verified, say why", cap time, and show failures to the owner.
- Locks can stall goals: time out and reassign through the owner.

## 6. Sources

- Anthropic, [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- Anthropic, [Effective harnesses for long-running agents](https://anthropic.com/engineering/effective-harnesses-for-long-running-agents)
- Anthropic, [How we built our multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system)
- Anthropic, [Writing effective tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents)
- Manus, [Context engineering for AI agents: lessons from building Manus](https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus)
- Cognition, [Don't build multi-agents](https://cognition.com/blog/dont-build-multi-agents) and [Multi-agents: what's actually working](https://cognition.com/blog/multi-agents-working)
- OpenHands, [event stream and condenser docs](https://docs.openhands.dev/sdk/arch/events)
- Yang et al., [SWE-agent](https://arxiv.org/pdf/2405.15793)
- Cemri et al., [Why do multi-agent LLM systems fail?](https://arxiv.org/abs/2503.13657)
- tau-bench and pass^k: secondary write-ups only; check the original paper before citing numbers.
- Codex CLI (approvals, sandbox, instruction files): secondary write-ups only; see github.com/openai/codex.
- Existing repo docs: `docs/AGENT-CLI-COMPARISON.md`, `docs/RELIABILITY.md`, `docs/AGENT-LOOP-PLAN.md`.

## 7. Implementation status (phases 1 and 2)

- `RunLog` / `ContextView` (`macos/Sources/AgentCore/RunLoop/`): `AgentRuntime` appends events and never edits them.
  Collapsing old output, dropping old screenshots, leaving out an announcement and summaries are view rules or
  `condensed` events. Persisted as `<bot>.runlog.jsonl` beside the transcript (screenshots omitted); the old
  transcript file is untouched. A tool call is stored inside its `modelReply`, not as a separate row.
- `Guard` protocol with `beforeModel`, `afterReply`, `beforeTool`, `afterTool`, `afterTurn` and `beforeFinish`; guards
  in `RunLoop/Guards/`, order fixed in `GuardSet.standard`. Every firing is a `nudge` event and a `loopEvent` counter.
- Behavior differences, all small: the stale / same-result / failure aborts fire when their condition is met instead of
  through a flag that survived into the next message; the screenshot turn now follows the alternation nudge instead
  of preceding it; the trash warning now actually fires (the arguments were JSON-escaped, so `\/` hid the path);
  new counters appear for the guards that had none (`missing_tool`, `repeat_call`, `same_result`, ...).
