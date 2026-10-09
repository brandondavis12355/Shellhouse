# Guardrails: no destructive or malicious action runs automatically

Status: **implemented in part** (see "Implementation status" at the end). Drafted and built with AI assistance (Claude Code); needs human review, and review by your Information Security team before it is treated as a control. Nothing here has been verified against a real Docker host or an adversary other than the automated red-team tests.

## The promise, stated honestly

No system can *guarantee* an LLM agent never does something harmful: "destructive" is undecidable for arbitrary shell, and classifiers miss things (Anthropic reports a 17% false-negative rate on real overeager actions for its own auto-mode classifier). So the guarantee is built from things that **can** be made deterministic:

1. **Containment:** what a compromised agent can *reach* is small (workspace, an egress allowlist, a token-gated model proxy). Even a fully hijacked agent hits a wall.
2. **Fail-closed policy:** every action is classified by *effect*. Anything destructive, security-sensitive or externally visible needs a **fresh human approval bound to that exact action**; unknown means ask; a flagged action in an untrusted run means deny.
3. **Reversibility:** in-sandbox deletes/overwrites are checkpointed, so a wrong approval is recoverable.
4. **Monotonic layers:** classifiers and reviewers may only *raise* severity, never lower it.
5. **Evidence:** a tamper-evident audit log kept outside the container, plus tests that try to break every rule.

What we **cannot** promise: that a determined attacker never finds a bypass of a pattern rule, or that a human never approves something bad. The design limits blast radius so those failures are survivable.

## Research this is based on

| Source | What we take from it |
|---|---|
| OWASP Top 10 for LLM Apps / Agentic Applications (2026): Excessive Agency, Tool Misuse, Memory Poisoning, Goal Hijack | Least privilege, tool RBAC + schema validation, human approval on destructive operations, scoped time-limited credentials, audit logging |
| Simon Willison, "lethal trifecta" | Private data + untrusted content + external communication in one agent = exfiltration. Remove a leg |
| Meta, "Agents Rule of Two" | An agent may combine at most two of: processes untrusted input, accesses sensitive systems, changes state/communicates externally. All three requires human-in-the-loop. Session isolation breaks exploit chains |
| Anthropic, Claude Code sandboxing | Filesystem **and** network isolation are both required; egress via a proxy outside the sandbox with a domain allowlist; credentials stay outside the sandbox; sandboxing cut permission prompts 84% |
| Anthropic, Claude Code auto mode | Users approved 93% of prompts (approval fatigue); two-stage classifier; classifier sees the action but not the agent's own reasoning or tool output; 20+ default blocks (force-push, mass delete, disabling logs, persistence, credential harvesting, cloning external code); screens tool results for injected instructions |
| smolagents secure-execution guide | Local interpreter is not a security boundary; use real isolation for model-written code |

## Where the current code stands (as I read it)

Good: policy engine fails to `requireApproval` for unknown tools; `run_shell` asks by default; `neverAutoApprove` blocks standing grants for interpreters/wrappers; shell metacharacters and chaining are excluded from grants; untrusted-run mode for friend messages; no Docker socket in the agent path; `cap_drop: ALL`; sandbox inter-container traffic disabled.

Gaps to close (risk-ranked):

1. **Only friend messages count as untrusted.** Web pages, fetched files, MCP output, other bots' replies and third-party skills are equally attacker-controlled (`docs/SECURITY.md` itself names web injection as the most likely failure) but don't tighten policy.
2. **Blanket grants.** "Allow all shell commands" including "every bot, always" removes the approval for the one tool that can do anything.
3. **No egress control.** Sandboxes can reach the whole internet: the exfiltration leg of the trifecta is open.
4. **Auto-allowed persistence/exfil channels:** `create_routine`, `remember` (memory poisoning), `post_to_group` (relay to friends), `message_bot` (trust laundering), `add_bot_to_group`.
5. **Destructive ≠ distinguished.** `rm -rf` and `ls` are the same tier (both "ask"), so users learn to click through.
6. **Writes are not reversible** and there is no budget/rate limit on deletions, writes or egress.
7. **Third-party skills** (`npx skills`) load instructions straight into context.
8. Sandbox runs `seccomp=unconfined` (needed by Chromium); acknowledged in SECURITY.md, but it raises the value of the egress and credential controls below.

## Design

### L0: Containment (assume the agent is compromised)
- **Egress allowlist proxy** outside the container (Linux host): default-deny; allowlisted domains (package registries, docs) pass; a new domain raises an approval; no direct container internet. Credentials/tokens never inside the container.
- **Filesystem:** writes only under `/workspace` and `$HOME`; everything else read-only; `tmpfs` scratch; read-only rootfs where Chromium allows.
- **Resource limits** on every sandbox (memory, pids, CPU, disk quota), not just ephemeral ones.
- **Workspace checkpoints:** snapshot before any delete/overwrite-class action (copy-to-trash or volume snapshot) so recovery is one click.
- **Canaries:** decoy credential files/env names in the sandbox; touching one freezes the run and alerts.
- **Model proxy** (see `SMOLAGENTS.md`): per-run token, model allow-list, token/request caps, no admin routes.

### L1: Action taxonomy (policy by effect, not by tool name)

| Class | Examples | Default | Standing grant allowed? | In an untrusted/tainted run |
|---|---|---|---|---|
| **R0 observe** | list/read in workspace, screenshot; shell: `ls`, `cat`, `grep`, `git status/diff/log` | allow (shell only if the opt-in "read-only fast path" is on, otherwise ask) | n/a | allow for tools; shell asks |
| **W1 reversible write** | write/edit workspace file (checkpointed) | allow | n/a | allow, checkpointed |
| **N2 network** | GET to allowlisted domain | allow | n/a | allow |
| | any other domain, POST/upload, new domain | ask | per domain, per bot | ask each time |
| **X3 arbitrary exec** | shell not provably R0, interpreters, installers | ask | only exact-command, never interpreters/wrappers | ask each time |
| **D4 destructive / irreversible** | `rm -r`, `find -delete`, `dd`, `mkfs`, `git push -f`, `reset --hard`, `clean -fd`, `chmod/chown -R`, truncating redirects, DB drops, `kill -9` broad, disabling logs | **ask, strict** | **never** | **deny** |
| **S5 credential / security** | read key/token/cookie files, `env`/`printenv` dumps, browser profile, SSH/cloud config, adding persistence (cron, systemd, shell rc), disabling controls | **deny** | never | deny |
| **E6 external side effect** | git push, email/chat/post, payments, deploys, MCP write tools, `create_bot`, `post_to_group` to shared groups | ask | never | ask each time |
| **M7 Mac-side state** | `remember`, `create_routine`, `edit_routine`, `message_bot`, secrets | allow when trusted | n/a | **quarantine**: held for user review (see L2) |

Unknown tool or unparseable command: **ask**; in a tainted run **ask strictly** (every time, no grants) so a human still sees it. Never allow.

### L2: Provenance and taint (enforces Rule of Two)
Label every piece of context: **trusted** (user-typed, system), **own** (this bot's memory), **untrusted** (web pages, downloaded/repo files, MCP results, friend messages, other bots' output, third-party skills). A run becomes **tainted** the first time untrusted content enters context and stays tainted.

Tainted run rules:
- All E6/X3/N2-non-allowlisted actions ask every time; **standing grants are ignored and can't be created** (generalizes today's friend-message rule).
- D4 → deny. S5 → deny.
- `remember`, `create_routine`, `edit_routine` are written to a **pending inbox** with provenance, activated only after the user confirms (blocks memory poisoning and persistence).
- `message_bot` / group posts pass taint to the recipient's run.
- Prefer **quarantined reading**: a tool-less model call summarizes untrusted pages and the acting agent sees only the summary, so injected instructions never sit next to tool access. (Dual-model/capability-style patterns are a known mitigation; evaluate effectiveness before relying on it.)
- Session isolation: after untrusted browsing, the next sensitive step starts a fresh run with no untrusted text in context.

### L3: Policy engine v2 (Swift, authoritative)
- Input: tool, **parsed** arguments, effect class, run context (taint, bot, group, trust), budgets so far.
- **Real shell parsing** (AST, not regexes): split lists/pipelines, flag command substitution, redirects, here-docs, `eval`, aliases, env-var expansion, encoded payloads (`base64 -d | sh`), obfuscated tokens; canonicalize every path argument and resolve symlinks against allowed roots. Anything that can't be fully understood is X3.
- **Signature rules** per class (D4/S5 lists above) with flag-level matching, kept as data with a test per entry.
- **Decision lattice** `ALLOW < ASK < ASK_STRICT < DENY`; layers can only move right. An optional LLM reviewer (given the action only, never the agent's reasoning or tool output, like Anthropic's design) can raise to ASK/ASK_STRICT, **never** lower. It is advisory friction, not a gate.
- **Approvals** are bound to `{run_id, tool, args hash, class}` with a short TTL (no replay), show the literal command, the class and *why*, the affected paths (dry run where possible), and the taint source. Default button is Deny. D4 asks require typing or a distinct confirm.
- **Remove or narrow blanket grants:** drop "every bot, always"; a bot-scoped "allow shell" may cover R0/X3-safe only and never D4/S5/E6.
- Fatigue controls: containment removes most prompts (Anthropic measured 84%); batch similar asks; rank by risk; show a counter so a flood of prompts is itself a signal.

### L4: Budgets and circuit breakers
Per run: max steps (exists), max commands/min, max files deleted/modified, max bytes written, max egress bytes/domains, wall clock (exists), token cap (exists, plus proxy-enforced). **Trip rules:** 3 denied/flagged actions, any canary touch, or egress to a never-seen domain → freeze the run and notify. Global **kill switch** stops every bot and revokes proxy tokens.

### L5: Audit and detection
Append-only, hash-chained log stored on the Mac (never in the container): who/what/args/class/decision/approver/taint/result. Debug Console reads from it. Alerts on canary hits, circuit-breaker trips and new egress domains.

### L6: Supply chain
Pin and hash-lock `smolagents` and its dependencies in the sandbox image; no runtime installs without an ask (already in `neverAutoApprove`); MCP servers allowlisted and pinned, tools default to ask; third-party skills marked **untrusted** and shown for review before install; no E2B/Modal/Blaxel executors.

### L7: Verification (a guardrail you haven't attacked is a guess)
- Unit tests for the policy engine: a corpus of destructive and obfuscated commands (`r""m -rf`, `$(…)`, backticks, `base64|sh`, `${IFS}`, env expansion, symlink and `..` escapes, TOCTOU swaps, flag permutations) that must classify D4/S5/X3, plus benign commands that must stay R0.
- Fuzz the shell parser; require a test per signature.
- Agent-level red-team evals: pages and files with embedded instructions; assert no D4/S5/E6 action executes without an approval record.
- Regression gate in CI on every policy change.

## How this fits the smolagents pilot
- The runner is **untrusted**. Hard guarantees come from L0 (what the container can reach) and from Swift-side enforcement of everything touching Mac state: bridge tools, secrets, model proxy, egress approvals, memory/routine inbox.
- In-container approval of in-sandbox commands is a UX and checkpoint control, **not** a security boundary against a compromised runner. This gets weaker, not stronger, with `CodeAgent` (model-written Python can call `subprocess`): keep `ToolCallingAgent` until L0 and L3 are in place.
- smolagents `max_steps` and callbacks map to L4 budgets and L5 events; they don't replace them.

## Suggested build order
1. **L3 + L1 + L7 for the existing Swift engine** (shell parser, effect classes, D4/S5 rules, tests). Pure Swift, no infrastructure, immediate benefit.
2. **L2 taint** (generalize the friend-message flag; memory/routine inbox).
3. **Remove blanket grants; add checkpoints and budgets (L4).**
4. **L0 egress proxy + canaries + audit log (L5).**
5. Then the smolagents phases in `SMOLAGENTS.md`.

## Implementation status

Built (Swift, `macos/Sources/AgentCore/Guardrails/`, all under test):
- **ShellAnalyzer**: lexer/parser that resolves quoting, `$'\x72\x6d'`, `$(…)`, backticks, `sh -c`, `eval`, `sudo/env/nohup/timeout/xargs/find -exec` wrappers, and flags anything it cannot resolve.
- **ActionClassifier**: effect classes with ~80 rules (rm/dd/mkfs/git/docker/cloud/SQL/kill/systemctl/cron/firewall, credential and persistence paths, canary tripwires, remote-code-execution and reverse-shell patterns, curl uploads, installers, interpreters, SSRF URLs).
- **GuardrailPolicy + TaintState**: monotonic combination of baseline policy, class and run taint; friend-message mode preserved; quarantine of memory/routine writes in tainted runs; grants only for plain clean-run asks.
- **ToolGate**: one shared gate used by both engines (approvals bound to an args digest, strict approvals expire after 15 min, audit, checkpoint, rate/blocked/write circuit breaker, tripwire freeze).
- **AuditLog** (hash-chained, secrets redacted, verify in Settings), **PendingInbox** (+ review card in chat), **Checkpoint** (workspace snapshot before overwrites/deletes).
- The global "allow all shell, every bot" grant is retired; strict approvals can never create a standing grant.
- Opt-in Settings toggle for the read-only shell fast path (off by default).
- Delegation: a reply from a run that read untrusted content is no longer auto-written into either bot's memory.

Built but **not run against real infrastructure**: egress allowlist proxy + manager endpoints + canary seeding (`egress-proxy/`, `docs/EGRESS.md`, `sandbox/bin/seed-canaries.sh`), reverse SSH forward for the model proxy.

Not done: quarantined (tool-less) reading of untrusted pages; automatic session isolation; an LLM reviewer (advisory only, by design); typed confirmation for destructive approvals (the card marks them strict but a click still approves); a Mac UI for approving new egress domains (the manager endpoints exist); screenshot-based prompt-injection detection; MCP server pinning; a review UI for third-party skills; group turns/delegations still use the built-in engine only. Known limit: symlinks inside the workspace are not resolved statically, so containment (L0) has to cover them.

### Red-team results (automated, string classification only)
About 450 attack strings were tried against the classifier; the bypasses found were fixed and each has a regression test (`GuardrailBypassTests`, `GuardrailTests`, `GuardrailRuntimeTests`): grapheme-cluster/CRLF lexing, hidden function bodies and wrapper options (`env -S`, `exec -a`, `time -p`, `strace -o`, `trap`), `/bin/../bin/rm`, `/proc/self/root` and `cwd` path tricks, credentials reached through option values (`curl -d@…`, `--out=`), `cd` into credential directories, fetch-and-execute forms, environment injection (`LD_*`, `BASH_ENV`, `PATH=`, `GIT_*`), git `-c`/alias/exec-path tricks, odd IPv4/IPv6 spellings of metadata addresses, and read-only fast-path look-alikes (`watch`, `sleep inf`, `tail -F`).

**Known gaps (design-level, not fixed):**
- Two-step attacks: `write_file` a script, then `python3 script.py`. The human sees the command, not the script. Mitigation today: interpreters always ask and are never granted in a tainted run; nothing shows the script contents.
- Symlinks already inside the workspace are not resolved statically.
- `fetch_url` redirects and DNS rebinding are only covered when the egress proxy is on.
- A per-bot "allow all shell" grant (still available) auto-runs plain `ask`-level commands such as interpreters in a clean run. Strict, destructive and credential classes are never covered by it.
- `click` and `press_key` are unconstrained; they rely on sandbox containment.
- Content downloaded in an earlier run carries no taint into a later one.
- In the smolagents engine, in-container tool approvals are advisory against a compromised runner (see below).
