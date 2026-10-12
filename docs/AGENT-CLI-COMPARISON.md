# How Shellhouse compares to open-source agent CLIs

Status: research, October 2026. Drafted with AI assistance (Claude Code) from the projects' own repos and
docs; review before relying on it. Facts that could not be confirmed from a primary source are not used.

**Surveyed:**
- **Coding CLIs:** OpenAI Codex CLI, Google Gemini CLI, Qwen Code, OpenCode, Crush and Aider.
- **Agent runtimes:** OpenHands (and its SDK), SWE-agent / mini-swe-agent, Cline, Roo Code (archived May 2026), Goose,
  Open Interpreter (now a Codex fork) and Continue's `cn`.
- **Skill and instruction formats:** AGENTS.md and the Agent Skills format (SKILL.md).

The goal is reliability: which mechanisms these projects converged on, and which ones Shellhouse is missing.

## Where the ecosystem agrees

These show up in most of the 13 projects. "Shellhouse today" is from this repo's code.

| Mechanism | How the others do it | Shellhouse today |
|---|---|---|
| **Targeted file edits** | Exact search/replace that must match once (Gemini `replace`, OpenCode/Crush `edit`, OpenHands `str_replace`, Aider SEARCH/REPLACE), or `apply_patch` for GPT-style models | **Missing.** Only `write_file`, which replaces the whole file |
| **Edit recovery** | Fallback matching (OpenCode: 9 strategies incl. whitespace/indent-tolerant; Aider: whitespace + `...`), "did you mean" near-miss lines, reject omitted-code placeholders (Gemini) | **Missing** |
| **Read before edit** | Edit refused unless the file was read this session and is unchanged on disk (Qwen, Crush) | **Missing** |
| **Paged reads** | `offset`/`limit`, about 2,000 lines per page, line-length caps, "continue at offset N" hint (OpenCode, Gemini, Crush). SWE-agent: a 100-line window beat both a 30-line window and the whole file | **Partial.** `read_file` returns up to 200 KB, with no ranges or line numbers |
| **Search tools** | `grep` (ripgrep) and `glob` with capped, concise results; "narrow your search" past 100 hits (SWE-agent: summarized search 18.0% vs 12.0% for paging) | **Shell only** (`grep`/`find` via `run_shell`, which needs approval) |
| **Long-running commands** | A timeout leaves the process running and returns output so far, then the agent polls or kills it (Codex `exec_command`/`write_stdin`, OpenHands soft timeout, Crush auto-background at 60 s, Roo, `cn` background jobs) | **Missing.** A timeout ends the command; the skill suggests `nohup` |
| **Big output** | Head/tail truncation, or spill the full output to a file and return a preview plus the path (OpenCode, Roo, Goose) | **Partial.** Head + tail truncation, but the middle is lost |
| **Plan / todo tool** | `update_plan`, `write_todos`, `todowrite`, `task_tracker`; often one item in progress at a time | **Partial.** Group goals have a checklist; 1:1 runs have only `remember_task` (cross-chat tasks, not a run plan) |
| **Completion guard** | Refuse "done" while todos are open (Roo); `verified=true` only when tool output shows it (Cline); shell checks that must pass, else retry (Goose recipes); review the diff before submitting (SWE-agent) | **Partial.** Three-checks rule in the prompt, plus evidence grounding for goal steps |
| **Repeat / stuck detection** | Hash of tool and arguments: soft warning, then a stop (Cline 3/5, Roo 3, Crush 5 in 10, OpenCode 3). OpenHands also catches "same error 3×" and nudges once, naming the error | **Yes.** Repeats, ping-pong and monologue. No "same error N×" nudge |
| **Malformed-call handling** | Corrective message and a cap on consecutive mistakes (3–6) | **Yes.** Validation, coercion, text-call recovery |
| **Context compaction** | Summarize at a share of the window; prune old tool output first (OpenCode); re-load recently touched files afterwards (Qwen) | **Yes.** Compaction at 12k plus stale-output collapsing |
| **Model-call retries** | Exponential backoff with jitter on 429/5xx | **Yes** |
| **Approval tiers** | Plan/read-only → ask → auto-edit → yolo; per-tool allow/ask/deny | **Yes**, richer: effect classes, strict asks, taint |
| **Checkpoints / undo** | Shadow-git snapshot after every tool use, then restore files and/or conversation (Cline, Roo, Gemini `/restore` and `/rewind`); Aider auto-commits plus `/undo` | **Partial.** Copy-to-trash before deletes and overwrites only; no undo command |
| **Web fetch / search tools** | Built in nearly everywhere (`web_fetch`, `web_search`) | **Missing** in the Mac app; bots use `curl` or the browser |
| **Project instruction file** | AGENTS.md (nearest file wins; Codex caps at 32 KiB); also GEMINI.md, .goosehints, .clinerules | **Missing.** Only the bot's own custom prompt |
| **Skills** | Agent Skills format: `skills/<name>/SKILL.md`, name + "use when" description loaded up front, body loaded on demand (<500 lines), optional `scripts/` | **Close.** Same frontmatter idea, single `.md` file, lazy `use_skill` |
| **Sub-agents** | Isolated context that returns only its final reply (OpenHands `task`, Cline `spawn_agent`, Goose `summon`, Codex `spawn`) | **Partial.** `ask_helpers` (no tools) and `message_bot` (other bots) |

## Ideas worth borrowing that only a few have

1. **Lint-gated edits (SWE-agent).** Check the file before and after an edit. If the edit adds errors, reject it, show
   the errors with the proposed and original versions, and say not to repeat it unchanged. In the paper this was
   worth 3 points (18.0% vs 15.0%).
2. **One targeted nudge before giving up (OpenHands).** On the third identical error, name the tool and the error once.
3. **Escalating advice per failure type (Cline).** After 2 empty writes: write a skeleton, then fill it with edits.
   After 3: do not retry.
4. **Keep failed attempts out of history once recovered (SWE-agent).**
5. **Completion backed by real checks (Goose recipes, Roo).** Shell checks that must exit 0, or no "done" while plan
   items are open.
6. **Small-model fallbacks.**
   - Goose: a second model turns text tool calls into real ones.
   - OpenHands: in-context examples for models without native tool calling.
   - Open Interpreter: emulate the agent setup a model was tuned for.
   - mini-swe-agent: a bash-only baseline with one command per reply.
7. **Spill long output to a file (OpenCode, Roo).** Return a preview plus the path, so nothing is lost and it can be
   grepped.

## Recommendations for Shellhouse, in order

| # | Change | Why | Effort |
|---|---|---|---|
| 1 | **`edit_file` tool:** exact search/replace that must match once, whitespace-tolerant fallback, near-miss hint on failure, refused unless the file was read and is unchanged since | Consensus feature. Today a local model rewrites whole files to change one line, which truncates or corrupts them | M |
| 2 | **Paged `read_file` plus search tools:** `offset`/`limit` with line numbers and a "continue" hint; `search_files` (grep) and `find_files` (glob) with capped results, allowed without approval like `read_file` | Smaller, exact context. Searching no longer needs a shell approval | S–M |
| 3 | **Validate on write:** after `write_file`/`edit_file` on `.py`, `.json`, `.sh`, `.yaml`, run a syntax check; if the change breaks a file that parsed before, reject it with the error and keep the original | SWE-agent's biggest single guardrail | S |
| 4 | **Background shell:** a timeout leaves the command running and returns output so far plus a job id; `check_job` / `stop_job`; long output saved to a file with its path | Builds, installs and servers stop failing at 120 s | M |
| 5 | **Run plan plus completion guard:** an `update_plan` tool for 1:1 runs (one item in progress); `finish_task` refused while items are open unless marked blocked | Consensus; turns the "3 checks" rule into structure | S–M |
| 6 | **Same-error nudge:** on the third identical error from one tool, one message naming the tool and the error, then the existing stop | Cheap; reduces "keeps retrying the same broken command" | S |
| 7 | **Undo:** snapshot the workspace before every write (not only deletes), plus "undo the bot's last change" in the bot's settings | Makes approvals cheaper to grant | M |
| 8 | **Workspace instructions:** load a short `/workspace/AGENTS.md` (capped, e.g. 8 KB) into the bot's prompt | Per-project conventions without editing each bot | S |
| 9 | **Skills in the Agent Skills layout:** `skills/<name>/SKILL.md` (still reading single files), "Use when…" first in every description, optional `scripts/`; then add skills for documents (PDF/DOCX/XLSX via Python), a research brief with citations, and verify-before-finish | Interoperable with other agents' skills; fills the common skill topics we lack | M |
| 10 | **Built-in `fetch_url`:** returns page text (tags stripped, truncated) | Removes the most error-prone research step | S |

**Items 1–6 are implemented** (October 2026): `edit_file`, paged `read_file`, `search_files`/`find_files`, validate-on-write, background `run_shell` with `check_job`/`stop_job` (built-in engine only), `update_plan` with the completion guard, and the same-error nudge. `EngineABEval` gained `files.edit`, `files.search` and `shell.background`. Final run on a real sandbox: built-in 15/15 in 273 s, smolagents 15/15 in 410 s (after also fixing request encoding so Ollama's prompt cache works; see the commit history). Items 1–6 are the reliability core and touch `ToolRegistry`, `Policy`, `ActionClassifier` and the runtime. Each one
needs its skill updated (`shell-and-files`, `desktop-control`, `code-projects`) and a task added to
`EngineABEval` to measure it.

## Sources

**Coding CLIs**
- Codex tools: https://github.com/openai/codex/tree/main/codex-rs/core/src/tools/handlers
- Codex sandboxing: https://learn.chatgpt.com/docs/sandboxing
- Gemini CLI tool docs: https://github.com/google-gemini/gemini-cli/tree/main/docs/tools
- Gemini CLI loop detection: `packages/core/src/services/loopDetectionService.ts`
- Gemini CLI checkpointing: `docs/cli/checkpointing.md`
- Qwen Code: https://github.com/QwenLM/qwen-code (`packages/core/src/tools`; `docs/users/features/approval-mode.md`)
- OpenCode tools: https://github.com/anomalyco/opencode/tree/v1.19.0/packages/opencode/src/tool
- OpenCode docs: https://opencode.ai/docs/tools/
- Crush tools: https://github.com/charmbracelet/crush/tree/main/internal/agent/tools
- Crush loop detection: `internal/agent/loop_detection.go`
- Aider edit formats: https://aider.chat/docs/more/edit-formats.html
- Aider lint and test: https://aider.chat/docs/usage/lint-test.html
- Aider repo map: https://aider.chat/docs/repomap.html

**Agent runtimes**
- OpenHands tools: https://github.com/OpenHands/software-agent-sdk/tree/main/openhands-tools/openhands/tools
- OpenHands stuck detector: `openhands-sdk/openhands/sdk/conversation/stuck_detector.py`
- OpenHands security: https://docs.openhands.dev/sdk/guides/security.md
- SWE-agent tools: https://github.com/SWE-agent/SWE-agent/tree/main/tools
- SWE-agent ACI paper: https://arxiv.org/abs/2405.15793
- mini-swe-agent: https://github.com/SWE-agent/mini-swe-agent
- Cline: https://github.com/cline/cline (`docs/core-workflows/checkpoints.mdx`, `sdk/packages/core/src/runtime/safety/loop-detection.ts`)
- Roo Code: https://github.com/RooCodeInc/Roo-Code (`src/core/tools/ToolRepetitionDetector.ts`, `AttemptCompletionTool.ts`)
- Goose recipes: https://github.com/aaif-goose/goose (`documentation/docs/guides/recipes/recipe-reference.md`)
- Goose tool shim: `documentation/docs/guides/tool-shim.md`
- Open Interpreter harness emulation: https://github.com/OpenInterpreter/open-interpreter (`docs/harness.md`)
- Continue CLI tools: https://github.com/continuedev/continue (`extensions/cli/src/tools`)

**Skill and instruction formats**
- AGENTS.md: https://agents.md/
- Agent Skills specification: https://agentskills.io/specification
- Example skills: https://github.com/anthropics/skills
- Skill-writing best practices: https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices

**Research**
- Writing effective tools for agents: https://www.anthropic.com/engineering/writing-tools-for-agents
- Effective context engineering: https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- Manus, context engineering lessons: https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus
