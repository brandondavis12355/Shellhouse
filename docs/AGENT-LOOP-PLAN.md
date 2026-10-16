# Agent loop: robustness, accuracy, speed plan

Internal Use Only. Drafted with AI assistance (Claude); review before acting on it.

## What the research says

Sources are mostly secondary write-ups; confirm details against the originals before quoting them.

| Finding | Source |
|---|---|
| Most multi-agent failures come from system design and inter-agent misalignment (14 failure modes in 3 groups: specification, misalignment, verification), not raw model weakness | [Why Do Multi-Agent LLM Systems Fail? (MAST)](https://arxiv.org/abs/2503.13657) |
| An edit tool that lints and reverts a bad edit, and shows the error, the attempted edit and the original, helps agents recover; compact search and editing matter most | [SWE-agent](https://arxiv.org/pdf/2405.15793) |
| Design tools for agents (few, clear, well-described, token-efficient results) rather than wrapping APIs | [Anthropic: Writing tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents) |
| Stuck-loop detection works best as exact repeats, near-repeat arguments and cycles, escalating hint, then block, then stop | [loop-guard](https://cdn.jsdelivr.net/gh/isr4el-silv4/loop-guard@master/README.md), [stuck-loop detection](https://cdn.jsdelivr.net/gh/vstorm-co/pydantic-deepagents@main/docs/advanced/stuck-loop-detection.md) |
| Separate tool-call errors into model botched the call, the tool failed, or the model mishandled the error | [Latitude](https://latitude.so/blog/how-to-detect-tool-call-errors-in-an-agentic-workflow) |
| Long runs need external state (task list, progress file, git), bounded steps, verification each step, and a writer that is not its own reviewer | [Harness engineering summary](https://pinyulabs.substack.com/p/agent-harness-engineering-the-missing), [Anthropic harness summary](https://metavert.io/agent-harness) |

## What we already do (keep)

Syntax-checked edits that refuse breakage; bounded and collapsed tool results; identical-result dedupe; stuck detector (repeats, alternation, plain replies); narration nudges (escalating); tool-call recovery from text; budgets and compaction sized to the window; plan and finish guards; goal steps with a validator who is not the worker; idle probe; degeneration cut-off (`RepetitionGuard`); duplicate-delegation return.

## Failures we have seen, and the gap behind each

| Seen in logs | Gap | Fix (below) |
|---|---|---|
| Hundreds of repeated chunks in one reply | Guard only ran after a reply finished | Done (`RepetitionGuard`) |
| Bot narrates "let me take a screenshot", no call | Nudge only after 2 misses | A1 |
| Screenshot request sent to the small quick-reply model | Routing by word list | B2 |
| Same `message_bot` re-sent; "teammate is stuck" while they work | No view of peer state | Partly done; B1 |
| Judging teammates' work from a stale checkout (own VM per bot) | Prompt-only rule | B3 |
| Owner flipped step assignee | Fixed | Done |
| Slow file work (4 reads per file, 3 round trips per syntax check) | Per-step latency | Done; C1, C2 |
| Cloud spend: history re-sent every step | Big old results rode along | Done (budgeted collapse); A4 |
| Bot says "done/shipped" without evidence | Checked only in group goals | A2 |

## Plan, in priority order

### A. Robustness and accuracy of the single-bot loop
1. **Narration on the first miss, not the second.** A reply that ends in "I'll/Let me X" with no tool call: strip it and re-ask for the call at once; reserve the escalated nudge (tool list, concrete command) for the second miss. Measure: narration-miss count per run in telemetry.
2. **Evidence gate on `finish_task` outcome "done".** If the run changed files or ran commands, require that the last verification-type call (test, curl, git status) happened after the last write; otherwise bounce once with "run the check, then finish". Same shape as the open-plan-items guard already there.
3. **Failure classification (MAST/Latitude split).** Tag each failed step as bad-call (schema/validation), tool-failure (exit code, timeout) or mishandled (model ignored the error: next call identical). Use the tag to pick the nudge: bad-call gets the schema; tool-failure gets "try a different route"; mishandled escalates to the stuck path sooner.
4. **Near-repeat detection.** Today fingerprints are exact. Normalize (strip whitespace, numbers in paths like `log3.txt`, `head -n` variants) so "cat a | head -20" then "head -50 a" counts as a repeat of one look.
5. **Edit recovery shows the attempt.** When `edit_file` fails to match, return the closest region (already done) plus the model's `old_text` side by side, as SWE-agent does; when a syntax check rejects, include the offending lines.

### B. Group and multi-bot accuracy
1. **Peer-state surface.** Give every member a one-line live status of each peer (idle / running N min on step X / waiting) in the group prompt, refreshed per turn. Replaces guessing "stuck".
2. **Route by intent, not words.** Quick-reply model only for pure chat; anything asking for an artifact, status of work, or an action goes to a full turn. Add a classifier fallback: if the quick model's answer contains a promise ("I'll", "let me") escalate to a full turn.
3. **Evidence-carrying handoffs.** Require reports about another member's work to include commit hash and branch; the harness (not the model) runs `git fetch` in the reviewer's checkout before a review turn starts.
4. **Validator independence check.** Confirm the validator never validates a step it worked on (MAST: weak verification is a top failure group).
5. **Goal closure is state, not chat.** Persist goal/step state as the source of truth shown at the top of every member prompt (already partly true); drop restated history to save tokens.

### C. Speed
1. **Parallel read-only tool calls.** The runtime executes calls from one reply sequentially. Run consecutive observe-only calls (`read_file`, `list_files`, `search_files`, `find_files`) concurrently; keep writes and shell serial. Biggest win when models batch reads.
2. **Prefetch after `list_files`/`search_files` hits.** Cheap and optional: not planned unless A/B data shows it helps.
3. **Fast tier for housekeeping.** Compaction summaries, group addressing and quick replies already can use the fast model; verify compaction actually uses it and falls back cleanly.
4. **Prefix stability for cached pricing.** Keep system prompt, tool order and skill list byte-stable across steps and group turns so provider prefix caches hit; add a test that the prefix is identical across two consecutive requests.
5. **Stream cut-off tuning.** Make the `RepetitionGuard` thresholds configurable and log trips to the debug console (already logged as "reply cut off").

### D. Measure before and after
Add a small replay harness: take the pasted logs we already have (TicTacToe run, screenshot run) as fixtures and assert on step count, narration misses, repeated calls and tokens. Track per-run: steps, tokens, wall time, nudges fired, aborts. Without this each change is a guess.

## Status

Implemented: D (`loopEvent` counters in telemetry, replay tests), C1 (parallel read-only calls), C4/C5 partly (tunable `RepetitionGuard`; prefix stability left as is), A1 (first nudge carries the screenshot route), A2 (unverified-change finish gate), A3 (time-limit hint), A4 (head/tail/cat of one file is one look), A5 (parser error shows the lines as written), B1 (teammate status lines), B2 (quick replies that promise work escalate), B3 (`git fetch` in every repo before a review turn), B4 (validator's own steps go to the owner).
Deliberately not done: C3 (summaries on the fast model): a small model writes worse summaries, and summary quality is what keeps long runs accurate; C2 (prefetch).

## Suggested order

1. D (harness) so the rest is measurable.
2. C1 (parallel reads), A1, A2: biggest speed and accuracy gain per line changed.
3. B1, B2, B3: remove the group-chat failures seen in logs.
4. A3, A4, A5, B4, C4: refinements once D shows where time and tokens still go.

## Risks

- Parallel reads must keep result order and the dedupe/trash warnings intact.
- The evidence gate can annoy on read-only tasks: apply it only when the run wrote or executed something.
- Peer-status text adds prompt tokens in every group turn: keep it to one short line per member.
