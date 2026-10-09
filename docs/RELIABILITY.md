# Agent-loop reliability

Drafted with AI assistance (Claude Code); review before circulating.

What the bots do to stay accurate, and the research each piece comes from. All of it is deterministic code in
`macos/Sources/AgentCore/Reliability/AgentReliability.swift` (plus wiring in `AgentRuntime.swift`,
`GroupChatSession.swift`, `Bot.swift`). No new service or dependency is involved.

| # | Technique | Failure it prevents | Source of the idea |
|---|---|---|---|
| 1 | Long tool output is cut in the middle (head + tail + "N lines omitted") | Context flooded by `apt`/log dumps; real error lost | SWE-agent ACI ablations: summarized search, bounded viewer |
| 2 | Grounded recovery hints after a failure ("command not found → check/install", "path missing → list parent") | Blind retries of the same broken command | Reflexion: feed real environment feedback into the retry |
| 3 | Warning when exit code is 0 but the output shows a failure (`cmd; echo exit=$?` chains) | Bots reporting success on a failed check | Seen in this app's own logs |
| 4 | Old bulky tool results collapse to a one-line stub (last 8 stay full) | Stale output drowning the task; slower prompts | SWE-agent: truncate history to the last observations |
| 5 | Ping-pong detector (A,B,A,B…): nudge at 6, stop at 8 | Two-step loops that exact-match detectors miss | OpenHands stuck detector (alternating pattern) |
| 6 | Monologue detector: nudge at 3 plain replies, stop at 5 | Models talking instead of acting | OpenHands stuck detector (monologue) |
| 7 | Tool-call validation: missing/wrong-typed arguments, unknown tool with "did you mean `run_shell`?" | Confusing failures, wasted approvals | SWE-agent: guardrails that help recovery from bad actions |
| 8 | Shell lint before approval (unterminated quote, markdown fences, empty command) | Asking a human to approve a command that cannot run | SWE-agent's lint-before-edit guardrail |
| 9 | Narration retry: "I'll check that now" is not a reply; one retry demands the actual result | Announcements posted as answers | Anthropic: evaluator-optimizer with clear criteria |
| 10 | Near-duplicate replies are dropped (own and others', last 8 messages) | Repeated posts | Multi-agent runaway/echo failure modes (AutoGen/CrewAI reports) |
| 11 | A goal step counts as done only if its evidence quotes something the tools actually returned this run | "Progress mirage": confident completion with nothing behind it | Research on self-graded loops: grounding in real world state is mandatory |
| 12 | Current date/time/timezone in every prompt | Guessed dates, wrong "yesterday" in stand-ups | General grounding practice |

## Round two (wider research)

| # | Technique | Failure it prevents | Source of the idea |
|---|---|---|---|
| 13 | The task is re-stated at the end of the context every 5 steps (only the latest reminder kept) | Drifting off the objective in long runs | Manus: recite the plan (todo.md) into the recency zone |
| 14 | Step-budget warnings at 75% and 90% of the iteration limit | Hitting the limit with nothing to show | Graceful degradation guidance for agent loops |
| 15 | On an early stop, a tool-less summary of what was verified, not a bare error | "(stopped early…)" posted with no information | Same; plus Magentic-One's recover-from-stall idea |
| 16 | Reply specifics (versions, paths, addresses, hashes) must appear in tool output, the chat or the bot's records; one retry, then those lines are dropped | Hallucinated "facts" in reports and stand-ups | CRITIC and Chain-of-Verification: check claims against tools |
| 17 | Yes/no gates use schema-constrained output | Free-text "YES, because…" misparsed by small models | Ollama structured outputs (constrained decoding) |
| 18 | Tool descriptions say what is returned, when to use it, and the pitfalls seen in logs | Misuse of `run_shell`, wrong paths | Anthropic, Writing effective tools for agents |
| 19 | "Match effort to the question; don't re-verify what the chat already shows" in group turns | Over-investigating a simple question | Anthropic multi-agent research system: effort scaling |
| 20 | Group-chat and goal playbooks are not loaded again each turn (rules are already in the prompt) | ~10 s per turn spent re-reading the same skill | Context-engineering guidance: don't pay for what is already in context |
| 21 | Tool calls written as text (`Action: {...}`, fenced JSON) are recovered and executed | Small models "calling" tools in prose | Small-model reliability practice |
| 22 | Harmless type slips are coerced ("30" → 30, lone string → list) instead of rejected | Wasted turns on trivial schema errors | Anthropic tool guidance: forgiving inputs, actionable errors |
| 23 | Identical tool calls in one assistant turn run once | Doubled side effects and noise | OpenHands: repeated action patterns |
| 24 | Each bot's report carries a bounded digest of what its own commands returned, visible to other members (not in the UI) | The owner validating a conclusion without seeing the trace | Cognition: share full agent traces, not only messages |

## Memory: ranked retrieval and consolidation

`macos/Sources/AgentCore/Memory/MemoryBook.swift`, used by `Bot`. Each note carries importance (1-5), last-used time,
use count, source and a pin flag.

* **Retrieval** (Generative Agents): relevance to the incoming message (BM25-style, light stemming) 0.5 + recency
  (3-week half-life) 0.25 + importance 0.25. Unrelated notes never appear just because they are recent.
* **Prompt**: only pinned and high-keep-score notes (12) go in the system prompt; the rest appear next to a message when
  relevant, or via `recall_memory`. Notes that get surfaced count as used and stay fresh.
* **Adding**: a near-copy updates the existing note (newest wording, stronger importance) instead of piling up.
  Importance is guessed from wording and source (standing instructions 5, delegation chatter 2). You can pin and re-rate
  notes in the bot's settings.
* **Consolidation** (Letta-style housekeeping, deterministic): merges near-duplicates, and archives notes that are old,
  low-importance and never used. Runs at launch and daily, or on "Tidy up". Archived and over-capacity notes go to
  `memories-archive/`, never silently deleted. Capacity is 200 (was a 60-note FIFO).
* Old plain-list memory files migrate automatically on first load.

### Semantic search (embeddings)

* Uses a local embedding model through Ollama (`/api/embed`); nothing leaves the machine. Settings › Fast model →
  "Memory embeddings" (auto-selects an installed embedding model such as `qwen3-embedding:8b`; "None" = keywords only).
* Each note stores a 1024-dimension vector (base64 Float32, ~5 KB) tagged with the model that made it; vectors from
  different models are never compared, and changing the model re-indexes in the background.
* Relevance = 0.65 meaning + 0.35 keywords where a vector exists, keywords alone otherwise. Cosine below 0.30 is
  treated as noise, 0.70+ as a clear match. The same signal merges notes that say the same thing in different words
  (cosine >= 0.92) on add and during consolidation.
* Safe failure: if Ollama or the model is unavailable, retrieval falls back to keywords, indexing retries after 5 minutes,
  and the embedding model unloads from memory 5 minutes after use.
* Measured live (qwen3-embedding:8b, 6 notes, paraphrased questions): meaning found 6/6, keywords alone 2/6, and an
  unrelated question returned nothing. Run it yourself: `SHELLHOUSE_LIVE_EMBED=qwen3-embedding:8b swift test --filter LiveSemanticMemoryTests`.

Not done: model-written summaries of note clusters (a summarizer can silently drop facts).

Earlier in this project (same motivation): owner-only validation of goal steps, deterministic who-must-reply
planning, same-result and repeat-call detection, quick tool-less replies for small talk and stand-ups, stand-up
reports built from the bot's own task list.

## Switches (Settings › Accuracy)

All on by default, read live, one per group: Keep tool output short (1, 4) · Explain failures (2, 3) · Stop loops (5, 6) ·
Check tool calls (7, 8, 21-23) · Keep bots on task (13-15) · Check replies (9-11, 16) · Share evidence (24) · Reliable
yes/no decisions (17) · Quick stand-ups and small talk. "Turn all on" restores the defaults. Safety rules, approvals and the
loop/approval-time bug fixes are not switchable. On first launch the app also selects an installed small chat model as the
fast tier and an installed embedding model for memory search (never overriding an existing choice; "None" sticks).

## What the research says not to expect

* Self-critique without outside information does not reliably help; the checks above use tool output and
  state, not a model grading itself.
* Most reliability comes from scaffolding and routing, not from a verification step; verification is placed only
  at decision points (goal completion).

## Sources

* SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering — https://arxiv.org/abs/2405.15793
* OpenHands agent stuck detector — https://docs.openhands.dev/sdk/guides/agent-stuck-detector
* Anthropic, Building effective agents — https://www.anthropic.com/research/building-effective-agents
* When Do Agent Loops Mistake Stagnation for Progress? — https://arxiv.org/abs/2607.25152
* Where Does Agent Reliability Come From? — https://arxiv.org/abs/2607.17044
* Manus, Context Engineering for AI Agents — https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus
* Magentic-One (task and progress ledgers) — https://www.microsoft.com/en-us/research/articles/magentic-one/
* Anthropic, Writing effective tools for agents — https://www.anthropic.com/engineering/writing-tools-for-agents
* Anthropic, How we built our multi-agent research system — https://www.anthropic.com/engineering/multi-agent-research-system
* τ-bench (pass^k reliability) — https://arxiv.org/abs/2406.12045
* CRITIC: tool-interactive critiquing — https://arxiv.org/abs/2305.11738
* Ollama structured outputs — https://ollama.com/blog/structured-outputs
* Generative Agents (memory stream, retrieval scoring) — https://arxiv.org/abs/2304.03442
* Letta / MemGPT memory management — https://www.letta.com/
* Cognition, Don't Build Multi-Agents — https://cognition.ai/blog/dont-build-multi-agents
