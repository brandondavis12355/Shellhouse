import Foundation

/// Swift port of `api/agent/runtime.py`'s state machine: call the model,
/// dispatch any tool calls, repeat until the model stops calling tools.
///
/// Deliberately smaller than the Python original:
/// - No `TaskEvent`/DB persistence — this runtime is in-memory only, scoped
///   to one chat session's lifetime; the app persists transcripts itself.
/// - No MCP tool discovery — only the built-in `ToolRegistry`.
/// Everything else (budgets, approval-pause, loop/repeat detection,
/// screenshot vision-attach) mirrors the Python runtime's behavior.
public actor AgentRuntime {
    public enum Status: Sendable, Equatable {
        case idle, planning, waitingForApproval, completed
        /// Carries loop progress — cheap to compute (already tracked for
        /// `checkBudgets`) and useful enough (mainly for the debug
        /// console, but also the ordinary "Working…" status line) to be
        /// worth the associated values, without going as far as also
        /// including token usage/wall-clock time here too.
        case executing(iteration: Int, maxIterations: Int)
        case failed(String)
        case aborted(String)
    }

    public struct Budgets: Sendable {
        public var maxIterations: Int
        public var maxWallSeconds: TimeInterval
        public var maxTokens: Int
        /// Estimated-token threshold (see `estimatedTokens`) at which
        /// `compactContextIfNeeded` summarizes the older half of the
        /// conversation into one message — independent of `maxTokens`
        /// (a run-wide SPEND cap that aborts the run once exceeded):
        /// even a generous spend budget doesn't mean the active model's
        /// own context WINDOW can hold that much at once. Local models
        /// especially often run with a much smaller window than that
        /// budget implies, and usually truncate silently rather than
        /// erroring — there's no clean failure to react to, so this has
        /// to be proactive. Conservative by default since there's no way
        /// to introspect a given model's actual context length here.
        /// 0 (the default) means automatic: about 65% of the model's context window, after the tool
        /// definitions and room for the reply (see `ContextBudget`).
        public var compactionThresholdTokens: Int

        public init(
            maxIterations: Int = 40, maxWallSeconds: TimeInterval = 1800, maxTokens: Int = 200_000,
            compactionThresholdTokens: Int = 0
        ) {
            self.maxIterations = maxIterations
            self.maxWallSeconds = maxWallSeconds
            self.maxTokens = maxTokens
            self.compactionThresholdTokens = compactionThresholdTokens
        }
    }

    public enum Event: Sendable {
        case status(Status)
        case message(ChatMessage)
        /// One incremental chunk of the assistant's reply, fired as the
        /// model streams it — see `ModelBackend.chatStream`. Always
        /// followed by a `.message` carrying the same turn's complete,
        /// final content once the model finishes; consumers that want the
        /// "typing" effect use this one, consumers that only care about the
        /// finished turn (persistence, `hasUnread`, …) use `.message`.
        case messageDelta(String)
        case toolStarted(name: String, argumentsJSON: String)
        case toolCompleted(name: String, resultJSON: String)
        case approvalNeeded(Approval)
        /// How the guardrails settled a call that wasn't a plain automatic allow (for the debug console).
        case guardrailDecision(tool: String, outcome: String, detail: String)
        /// Fired once per `compact()` — the summary text that just
        /// replaced the older stretch of `messages`. A caller seeding
        /// this same conversation again later (`Bot`, specifically —
        /// see `ContextSummaryStore`) can cache this instead of paying
        /// for the same summarization round trip on every reseed.
        case contextCompacted(summary: String)
    }

    private enum RuntimeError: Error, CustomStringConvertible {
        case budgetExceeded(String)
        case repeated(String)
        case cancelled
        case frozen(String)

        var description: String {
            switch self {
            case .frozen(let message): return "guardrails froze this run: \(message)"
            case .budgetExceeded(let message): return message
            case .repeated(let message): return message
            case .cancelled: return "Stopped by user"
            }
        }
    }

    /// What the human decided about a pending approval — `.approve*` cases
    /// both let this one call through; the "Always" ones additionally record
    /// the decision in `permissions` so future matching `run_shell` calls
    /// skip approval entirely. See `RunShellPermissions`.
    public enum ApprovalDecision: Sendable, Equatable {
        case approve
        case approveAlwaysSession
        case approveAlwaysGlobal
        /// Blanket `run_shell` grants (every command, not one binary).
        case approveAllShellThisBotSession
        case approveAllShellThisBotAlways
        case approveAllShellEveryBot
        case deny
    }

    private let model: any ModelBackend
    private let sandbox: any SandboxProvider
    private let sandboxID: String
    private let tools: ToolRegistry
    private let secretStore: SecretStore
    private let permissions: RunShellPermissions
    private let budgets: Budgets
    private let modelName: String?
    private let onEvent: @Sendable (Event) -> Void
    /// Suspends until the user decides. Called on the main actor in practice
    /// (SwiftUI presents a card), but this actor only needs it to be some
    /// async closure — it doesn't care who answers it.
    private let requestApproval: @Sendable (Approval) async -> ApprovalDecision
    /// Set for a run that has untrusted (friend-authored) text in its context:
    /// every approval-tier call asks the human, standing grants are ignored,
    /// and "always allow" answers are not recorded.
    private let alwaysRequireApproval: Bool
    /// Every tool call is judged by the shared gate (docs/GUARDRAILS.md).
    /// `audit` and `inbox` are nil unless the owner supplies them, so tests
    /// and CLI runs never write to the user's real audit log or review inbox.
    private let gate: ToolGate

    private var messages: [ChatMessage] = []
    private var iterations = 0
    private var tokensUsed = 0
    /// For local models, `maxTokens` counts new work: replies plus what was added to the conversation since
    /// the last call. Resending the same history costs nothing extra (the server reuses its prompt cache).
    private var chargedThrough = 0
    private var lastPromptTokens = 0
    private var schemaTokens = 0
    /// The local model (also when wrapped by `ModelScheduler`): it keeps the prompt cached, so only new tokens count.
    private var isLocalModel: Bool { ((model as? ScheduledBackend)?.inner ?? model) is OllamaBackend }
    private var countsResentContext: Bool { !isLocalModel }
    /// Why the current turn stopped early, for telemetry (nil = it finished).
    private var stopReason: String?
    private var startedAt = Date()
    /// Time spent waiting for a person to answer an approval card: it does not count against the wall-clock budget.
    private var secondsWaitingForHuman: TimeInterval = 0
    private var callFingerprints: [String: Int] = [:]
    /// Chat-style turns (a group reply with no goal work): a substantial plain-text answer IS the
    /// answer, so skip the "you did not call a tool" nudge round trip that makes models repeat themselves.
    private let plainReplyEndsTurn: Bool
    /// A plain-text reply also ends the turn once tools have already run in it and the reply is a
    /// real answer, not an announcement ("I'll check that now"). Saves the extra model call that
    /// re-sending the same answer through finish_task costs. Off for goal work, where the bot must
    /// still record steps.
    private let answerEndsTurnAfterTools: Bool
    private var toolCallsThisTurn = 0

    /// The run's own checklist (`update_plan`). `finish_task` with outcome "done" is refused once
    /// while items are still open (Roo Code's completion guard), so "done" means done.
    public struct PlanItem: Sendable, Equatable {
        public enum Status: String, Sendable { case pending, in_progress, done, blocked }
        public let text: String
        public let status: Status
    }
    private(set) var plan: [PlanItem] = []
    private var finishGuardUsed = false
    /// Identical errors per tool this turn; the third gets one message naming it (OpenHands).
    private var errorCounts: [String: Int] = [:]
    static let sameErrorNudgeAt = 3
    var openPlanItems: [PlanItem] { plan.filter { $0.status == .pending || $0.status == .in_progress } }
    static let plainReplyMinLength = 25
    private static let loopRepeatThreshold = 3
    private var lastResultKey = ""
    private var sameResultStreak = 0
    /// Same tool, same result this many times in a row ends the run (nudged at `sameResultNudgeAt`).
    static let sameResultNudgeAt = 3
    static let sameResultAbortAt = 5
    private var abortForSameResults = false
    /// Failed actions in a row (see `FailureCheck`); any success resets it.
    private var failureStreak = 0
    private var abortForFailures = false
    /// The same failure (same error text) repeating: no new information, unlike a test that fails differently.
    private var sameFailureStreak = 0
    private var lastFailureKey = ""
    private var githubTokenSaved: Bool?

    private func hasSavedGitHubToken() async -> Bool {
        if let known = githubTokenSaved { return known }
        let saved = ((try? await secretStore.list()) ?? []).contains { $0.name == "GITHUB_TOKEN" }
        githubTokenSaved = saved
        return saved
    }
    private var stuck = StuckDetector()
    private var currentGoal = ""
    private var budgetWarningsSent: Set<Int> = []
    private var abortForStuck: String?
    /// The text of a reply that announced a step without taking it (see the loop's narration nudge).
    private var lastNarration: String?
    /// Results this bot already saw, in this run or a recent one (shared across its runs). A run getting back
    /// nothing but already-seen results is waiting or polling, whatever the commands look like, and side
    /// effects (a `git fetch`, a checkout) don't reset it the way they reset the other loop guards.
    private let seenResults: SeenResults
    private var staleStreak = 0
    private var abortForStale = false
    static let staleNudgeAt = 4
    static let staleAbortAt = 7

    /// Tools that may still run without approval during an untrusted run:
    /// they only read this bot's own state or update shared bookkeeping.
    static let untrustedSafeTools: Set<String> = [
        "list_files", "read_file", "search_files", "find_files", "check_job", "update_plan",
        "screenshot", "list_windows", "use_skill", "search_memory", "recall_memory",
        "list_routines", "get_profile", "list_tasks", "list_secrets", "list_bots", "complete_task", "update_user",
        "get_goal", "update_goal_step", "propose_goal", "add_goal_step", "edit_goal_step", "propose_goal_complete", "ask_helpers",
    ]

    /// Screenshots dominate token cost once skills are lazy-loaded (see
    /// ToolRegistry/ContentView) rather than dumped into the system prompt.
    /// Keeping every screenshot in a long run burns the token budget on
    /// stale images the model no longer needs — see Anthropic's
    /// computer-use reference implementation, which prunes to the N most
    /// recent images for the same reason. Older ones are replaced with a
    /// text placeholder rather than dropped silently, so the model knows
    /// why that context disappeared instead of being confused by a gap.
    private static let maxRetainedImages = 3

    /// The only way `loop()` will ever end a run — see `finishTaskSchema`.
    /// "The model returned no tool_calls" is deliberately NOT treated as
    /// completion (see `loop()`): that's exactly the failure mode observed
    /// in practice, where the model narrates an intent ("let me check X")
    /// and stops without ever doing it. Requiring an explicit tool call to
    /// finish is the documented fix (Inspect AI's ReAct agent and
    /// LangGraph's structured-response mode both require the same thing),
    /// not just a nudge that hopes the model self-corrects.
    private static let finishTaskName = "finish_task"
    static let updatePlanName = "update_plan"
    private static var updatePlanSchema: ToolSchema {
        ToolSchema(
            name: updatePlanName,
            description: "Write or update your plan for this task: a short checklist (at most 12 steps) with one "
                + "status each. Send the whole list every time. Use it for anything with several steps; skip it for "
                + "a one-step answer. At most one step may be in_progress. finish_task with outcome \"done\" is "
                + "refused while steps are pending or in_progress: finish them, or mark them blocked with the reason.",
            parameters: [
                "type": "object",
                "properties": [
                    "steps": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "text": ["type": "string"],
                                "status": ["type": "string", "enum": ["pending", "in_progress", "done", "blocked"]],
                            ],
                            "required": ["text", "status"],
                        ],
                    ],
                ],
                "required": ["steps"],
            ]
        )
    }

    /// The plan as the model and the reminder show it.
    var planText: String {
        plan.map { item in
            let mark: String
            switch item.status {
            case .done: mark = "[x]"
            case .in_progress: mark = "[~]"
            case .blocked: mark = "[!]"
            case .pending: mark = "[ ]"
            }
            return "\(mark) \(item.text)"
        }.joined(separator: "\n")
    }

    private func updatePlan(_ call: ToolCall) -> [String: Any] {
        guard let raw = call.arguments["steps"]?.value as? [Any], !raw.isEmpty else {
            return ["error": "update_plan needs 'steps': a list of {text, status}."]
        }
        var items: [PlanItem] = []
        for entry in raw.prefix(12) {
            guard let dict = entry as? [String: Any], let text = (dict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return ["error": "Every step needs a non-empty 'text'."] }
            let status = PlanItem.Status(rawValue: (dict["status"] as? String ?? "pending").replacingOccurrences(of: "-", with: "_")) ?? .pending
            items.append(PlanItem(text: String(text.prefix(200)), status: status))
        }
        if items.filter({ $0.status == .in_progress }).count > 1 {
            return ["error": "Only one step can be in_progress at a time; mark the others pending or done."]
        }
        plan = items
        var out: [String: Any] = ["ok": true, "plan": planText]
        if raw.count > 12 { out["note"] = "Kept the first 12 steps." }
        return out
    }
    private static var finishTaskSchema: ToolSchema {
        ToolSchema(
            name: finishTaskName,
            description: "Call this — and only this — the moment you have the complete, concrete result "
                + "for what was asked, or the moment you are genuinely blocked and cannot proceed further. "
                + "Plain text alone never ends the task; you must call this to stop. Do not call it just to "
                + "state an intent, a partial result, or a plan for what you're about to do.",
            parameters: [
                "type": "object",
                "properties": [
                    "summary": [
                        "type": "string",
                        "description": "The complete result to report back, or a clear explanation of why "
                            + "you're blocked. If outcome is \"silent\", this is never shown to anyone — a "
                            + "short internal note is fine.",
                    ],
                    "outcome": ["type": "string", "enum": ["done", "blocked", "needs_user_input", "silent"]],
                ],
                "required": ["summary", "outcome"],
            ]
        )
    }

    public init(
        model: any ModelBackend,
        sandbox: any SandboxProvider,
        sandboxID: String,
        tools: ToolRegistry = ToolRegistry(),
        secretStore: SecretStore = SecretStore(),
        permissions: RunShellPermissions = RunShellPermissions(),
        budgets: Budgets = Budgets(),
        modelName: String? = nil,
        onEvent: @escaping @Sendable (Event) -> Void = { _ in },
        requestApproval: @escaping @Sendable (Approval) async -> ApprovalDecision = { _ in .deny },
        alwaysRequireApproval: Bool = false,
        actionReviewer: ActionReviewer? = nil,
        excludedTools: Set<String> = [],
        guardrails: GuardrailConfig = .standard,
        limits: RunLimits = RunLimits(),
        audit: AuditLog? = nil,
        inbox: PendingInboxStore? = nil,
        initialTaint: [TaintSource] = [],
        plainReplyEndsTurn: Bool = false,
        answerEndsTurnAfterTools: Bool = false,
        seenResults: SeenResults = SeenResults()
    ) {
        self.seenResults = seenResults
        self.plainReplyEndsTurn = plainReplyEndsTurn
        self.answerEndsTurnAfterTools = answerEndsTurnAfterTools
        self.alwaysRequireApproval = alwaysRequireApproval
        // A friend's message in context is the strongest taint (a live human).
        var sources = initialTaint
        if alwaysRequireApproval, !sources.contains(.friendMessage) { sources.append(.friendMessage) }
        self.gate = ToolGate(
            sandboxID: sandboxID, sandbox: sandbox, permissions: permissions, config: guardrails, limits: limits,
            audit: audit, inbox: inbox, initialTaint: sources, friendSafeTools: Self.untrustedSafeTools,
            reviewer: actionReviewer,
            requestApproval: requestApproval, onEvent: onEvent
        )
        self.model = model
        self.sandbox = sandbox
        self.sandboxID = sandboxID
        self.tools = excludedTools.isEmpty ? tools : tools.removing(excludedTools)
        self.secretStore = secretStore
        self.permissions = permissions
        self.budgets = budgets
        self.modelName = modelName
        self.onEvent = onEvent
        self.requestApproval = requestApproval
    }

    /// Restores prior conversation turns into a freshly-created runtime
    /// without triggering a model call — for resuming a chat the user closed
    /// and reopened. `history` is plain `role`/`content` (see
    /// `TranscriptStore`): no `images` or `toolCalls`,
    /// since those aren't persisted (screenshots are large and this app
    /// already prunes older ones from a *live* run for the same reason — see
    /// `pruneOldScreenshots` — and a `toolCalls` entry with no matching tool
    /// response would confuse the next model call). The model loses the
    /// pixel data and exact tool-call structure of the earlier turns but
    /// keeps their text, which is what actually carries the context forward.
    /// Follow with `send(_:)`, not `start`, to continue from here.
    public func seed(systemPrompt: String, history: [ChatMessage]) {
        startedAt = Date()
        secondsWaitingForHuman = 0
        stuck = StuckDetector(); abortForStuck = nil
        staleStreak = 0; abortForStale = false
        iterations = 0
        tokensUsed = 0
        chargedThrough = 0
        callFingerprints = [:]
        messages = [ChatMessage(role: .system, content: systemPrompt)] + history
        chargedThrough = messages.count
    }

    /// Begin a brand new conversation.
    public func start(systemPrompt: String, goal: String) async {
        startedAt = Date()
        secondsWaitingForHuman = 0
        stuck = StuckDetector(); abortForStuck = nil
        staleStreak = 0; abortForStale = false
        iterations = 0
        tokensUsed = 0
        chargedThrough = 0
        callFingerprints = [:]
        messages = [
            ChatMessage(role: .system, content: systemPrompt),
            ChatMessage(role: .user, content: goal),
        ]
        currentGoal = goal
        await gate.setTask(goal)
        toolCallsThisTurn = 0
        plan = []
        finishGuardUsed = false
        errorCounts = [:]
        failureStreak = 0; abortForFailures = false; abortForSameResults = false; sameResultStreak = 0
        sameFailureStreak = 0; lastFailureKey = ""
        budgetWarningsSent = []
        stopReason = nil
        await loop()
        Telemetry.recorder.runEnded(stoppedBecause: stopReason)
    }

    /// Continue an existing conversation with a follow-up message.
    /// `images` are base64 PNGs/JPEGs the user attached alongside this
    /// message (see `Bot.queueMessage`) — the same vision channel a
    /// `screenshot` tool result uses, just supplied by the user instead of
    /// the agent's own eyes.
    public func send(_ userMessage: String, images: [String] = []) async {
        messages.append(ChatMessage(role: .user, content: userMessage, images: images.isEmpty ? nil : images))
        currentGoal = userMessage
        await gate.setTask(userMessage)
        toolCallsThisTurn = 0
        plan = []
        finishGuardUsed = false
        errorCounts = [:]
        failureStreak = 0; abortForFailures = false; abortForSameResults = false; sameResultStreak = 0
        sameFailureStreak = 0; lastFailureKey = ""
        // Loop-detection is meant to catch a model stuck repeating the
        // SAME call within one reasoning task, not across entirely
        // separate turns — without this reset, `callFingerprints`
        // accumulated for the whole lifetime of this `AgentRuntime`
        // (one bot's own chat can now live for a long time, across
        // relaunches, thanks to context compaction/the summary cache).
        // A tool like `list_routines()` — no arguments, so an identical
        // fingerprint every time — legitimately called a few times
        // across separate days would eventually cross
        // `loopRepeatThreshold` and get permanently refused for the
        // rest of this runtime's life, even though nothing was actually
        // looping.
        callFingerprints = [:]
        stopReason = nil
        await loop()
        Telemetry.recorder.runEnded(stoppedBecause: stopReason)
    }

    public func transcript() -> [ChatMessage] { messages }

    /// Whether untrusted content has entered this run, and from where.
    public var isTainted: Bool { get async { await gate.isTainted } }
    public var taintSources: [String] { get async { await gate.taintSources } }

    /// The user vouches that this conversation is trustworthy again (e.g.
    /// after reviewing it). Friend-message taint can't be cleared this way.
    public func clearTaint() async { await gate.clearTaint() }

    // MARK: - The loop

    private func loop() async {
        onEvent(.status(.planning))
        // Group goal turns already have the goal's checklist; a second plan would compete with it.
        let offersPlan = !tools.names().contains("update_goal_step")
        let toolSchemas = tools.schemas + [Self.finishTaskSchema] + (offersPlan ? [Self.updatePlanSchema] : [])
        schemaTokens = ContextBudget.estimatedTokens(ofSchemas: toolSchemas)
        while true {
            do {
                try checkBudgets()
            } catch {
                emitAbortMessage(for: error)
                onEvent(.status(.aborted("\(error)")))
                return
            }
            await compactContextIfNeeded()
            if Reliability.isOn(.outputLimits) { messages = ObservationPolicy.collapseStale(messages) }
            iterations += 1
            if Reliability.isOn(.taskFocus), let warning = StepBudget.warning(iteration: iterations, max: budgets.maxIterations), budgetWarningsSent.insert(warning.id).inserted {
                messages.append(ChatMessage(role: .user, content: "[budget] " + warning.text))
            }
            // Manus-style recitation: re-state the objective at the END of the context every few steps, where
            // the model pays the most attention, instead of trusting it to remember step 0.
            // Earlier reminders stay where they are: removing one shifts everything after it, which
            // makes the model server re-read the conversation from that point instead of reusing its cache.
            if Reliability.isOn(.taskFocus), iterations > 1, iterations % 5 == 0, !currentGoal.isEmpty {
                messages.append(ChatMessage(role: .user, content: "[reminder] Your task: \(String(currentGoal.prefix(400))). "
                    + "Step \(iterations) of \(budgets.maxIterations). Stay on this task; when it is answered, call finish_task."
                    + (plan.isEmpty ? "" : "\nYour plan:\n" + planText)))
            }
            onEvent(.status(.executing(iteration: iterations, maxIterations: budgets.maxIterations)))

            var reply: ModelReply
            var attempt = 0
            while true {
                do {
                    reply = try await model.chatStream(
                        messages: messages, tools: toolSchemas, model: modelName, temperature: 0.2,
                        onDelta: { [onEvent] delta in onEvent(.messageDelta(delta)) }
                    )
                    break
                } catch {
                    // The model server restarting or briefly unreachable: wait for it and try the same step again
                    // before giving up (up to ~14 s), instead of failing a whole run over a hiccup.
                    if ModelConnection.isConnectionProblem(error), attempt < ModelConnection.retryDelays.count, !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: UInt64(ModelConnection.retryDelays[attempt] * 1_000_000_000))
                        attempt += 1
                        continue
                    }
                    emitAbortMessage(for: error)
                    onEvent(.status(.failed(ModelConnection.isConnectionProblem(error) ? "the model server is unreachable" : error.localizedDescription)))
                    return
                }
            }
            chargeUsage(reply.usage)
            if Reliability.isOn(.callChecks), (reply.message.toolCalls ?? []).isEmpty,
               let recovered = ToolCallRecovery.extract(from: reply.message.content, toolNames: Set(tools.names())) {
                // The model wrote its tool call as text. Treat it as the call it meant to make.
                reply = ModelReply(message: ChatMessage(role: .assistant, content: "", toolCalls: [recovered]), usage: reply.usage)
            }
            messages.append(reply.message)
            // After "I'll do X" with no tool call, the model usually repeats that sentence alongside the call:
            // show it once, not twice.
            let replyText = reply.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let narrated = lastNarration, !replyText.isEmpty, replyText == narrated, !(reply.message.toolCalls ?? []).isEmpty {
                var shown = reply.message; shown.content = ""
                onEvent(.message(shown))
            } else {
                onEvent(.message(reply.message))
            }
            lastNarration = nil

            guard let calls = reply.message.toolCalls, !calls.isEmpty else {
                let plain = reply.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let isAnswer = plain.count >= Self.plainReplyMinLength && !plain.hasSuffix(":")
                let answeredAfterWork = answerEndsTurnAfterTools && toolCallsThisTurn > 0
                    && !ReplyQuality.looksLikeNarration(plain) && !ReplyQuality.endsWithIntent(plain)
                if isAnswer, plainReplyEndsTurn || answeredAfterWork, openPlanItems.isEmpty {
                    onEvent(.message(ChatMessage(role: .assistant, content: plain, isTaskSummary: true)))
                    onEvent(.status(.completed))
                    return
                }
                // Deliberately NOT treated as completion — see
                // `finishTaskSchema`'s doc comment. A plain-text reply with
                // no tool call just means "keep going," bounded by the same
                // budgets as everything else, not "the task is done."
                switch Reliability.isOn(.loopGuards) ? stuck.recordPlainReply() : .fine {
                case .abort(let why):
                    let error = RuntimeError.repeated(why)
                    emitAbortMessage(for: error)
                    onEvent(.status(.aborted("\(error)")))
                    return
                case .nudge(let text):
                    messages.append(ChatMessage(role: .user, content: text))
                case .fine:
                    break
                }
                if ReplyQuality.looksLikeNarration(plain) || ReplyQuality.endsWithIntent(plain) {
                    // It announced a step without taking it. Left in the context, that sentence is what a local
                    // model copies on the next try ("I'll verify the server runs." again and again), so take it
                    // out and ask only for the action.
                    lastNarration = plain
                    messages.removeLast()
                    let nudge = "Make the tool call for your next step now. No sentence about it first: just the call."
                    if messages.last?.content != nudge { messages.append(ChatMessage(role: .user, content: nudge)) }
                    continue
                }
                messages.append(ChatMessage(
                    role: .user,
                    content: "You did not call a tool. Plain text alone never ends the task — if you are "
                        + "not finished, call the next tool you need right now. If the message you just "
                        + "wrote already WAS your complete answer, call finish_task right now with that "
                        + "SAME content as the summary — do not write a different, shorter, or more "
                        + "hesitant response instead of it. Only report being blocked if you genuinely "
                        + "are; don't downgrade a complete answer into a \"blocked\" one just because you "
                        + "forgot to call finish_task the first time."
                ))
                continue
            }

            if let finishCall = calls.first(where: { $0.name == Self.finishTaskName }) {
                let summary = finishCall.arguments["summary"]?.asString ?? reply.message.content
                let outcome = finishCall.arguments["outcome"]?.asString ?? "done"
                // `summary` is `required` in the schema, but some models
                // hand back tool calls that skip required fields anyway —
                // completing with nothing here is worse than a retry: it
                // silently ends the whole task with no result at all (the
                // caller — e.g. `Bot.runIsolatedTask` — falls back to a
                // "didn't produce a response" placeholder with no way to
                // tell whether the bot actually finished the work).
                guard !summary.isEmpty else {
                    messages.append(ChatMessage(
                        role: .user,
                        content: "finish_task needs a non-empty `summary` — the actual result, or a clear "
                            + "explanation of why you're blocked. Call it again with that filled in."
                    ))
                    continue
                }
                // "Done" with plan steps still open: refuse once (only when finish_task is the sole call,
                // so every call in the turn still gets an answer). A second attempt goes through.
                if outcome == "done", calls.count == 1, !openPlanItems.isEmpty, !finishGuardUsed {
                    finishGuardUsed = true
                    appendToolResult(name: Self.finishTaskName, observation: [
                        "error": "Not finished: your plan still has open steps:\n"
                            + openPlanItems.map { "- \($0.text) (\($0.status.rawValue))" }.joined(separator: "\n")
                            + "\nDo them, or call update_plan marking each done or blocked (with the reason), then finish.",
                    ])
                    continue
                }
                onEvent(.message(ChatMessage(role: .assistant, content: summary, isTaskSummary: true)))
                onEvent(.status(outcome == "done" ? .completed : .aborted(outcome)))
                return
            }

            var seenThisTurn = Set<String>()
            toolCallsThisTurn += calls.count
            for call in calls {
                if call.name == Self.updatePlanName {
                    onEvent(.toolStarted(name: call.name, argumentsJSON: jsonString(call.arguments.mapValues(\.value))))
                    let result = updatePlan(call)
                    appendToolResult(name: call.name, observation: result)
                    onEvent(.toolCompleted(name: call.name, resultJSON: jsonString(result)))
                    continue
                }
                // The same call twice in one assistant turn runs once; the second still gets an answer.
                let key = Self.repeatFingerprint(for: call)
                if Reliability.isOn(.callChecks), !seenThisTurn.insert(key).inserted {
                    appendToolResult(name: call.name, observation: ["note": "Duplicate of an identical call in this same turn; it was run once, see the result above."])
                    continue
                }
                let shouldContinue = await handle(Reliability.isOn(.callChecks) ? ToolCallValidator.coerced(call, schemas: tools.schemas) : call)
                if !shouldContinue { return }
            }
        }
    }

    /// Runs one tool call to completion. Returns `false` if the runtime
    /// should stop entirely (budget exceeded, repeat loop detected, or the
    /// guardrail circuit breaker tripped).
    private func handle(_ call: ToolCall) async -> Bool {
        let repeatCount: Int
        do {
            try checkBudgets()
            repeatCount = try checkRepeat(call)
        } catch {
            emitAbortMessage(for: error)
            onEvent(.status(.aborted("\(error)")))
            return false
        }

        // A malformed call gets a precise correction (missing field, wrong type, "did you mean run_shell?")
        // instead of a confusing failure or an approval prompt for something that cannot work.
        // An unknown tool is never run. With the call checks on, the model also gets "did you mean run_shell?".
        guard tools.names().contains(call.name) else {
            let message = Reliability.isOn(.callChecks)
                ? (ToolCallValidator.problem(with: call, schemas: tools.schemas + [Self.finishTaskSchema]) ?? "unknown tool '\(call.name)'")
                : "unknown tool '\(call.name)'"
            appendToolResult(name: call.name, observation: ["error": message])
            return true
        }
        if Reliability.isOn(.callChecks), let problem = ToolCallValidator.problem(with: call, schemas: tools.schemas + [Self.finishTaskSchema]) {
            appendToolResult(name: call.name, observation: ["error": problem])
            return true
        }
        if Reliability.isOn(.callChecks), call.name == "run_shell", let command = call.arguments["command"]?.asString, let problem = ShellLint.problem(in: command) {
            appendToolResult(name: call.name, observation: ["error": problem])
            return true
        }

        // A plain GitHub git/gh network command with no secret attached: bots often forget use_secrets and get
        // "could not read Username". When a GITHUB_TOKEN is saved, attach it (it only ever reaches github.com
        // through gh's credential helper, and the guardrails still judge the call with it attached).
        var call = call
        if call.name == "run_shell", (call.arguments["use_secrets"]?.asStringArray ?? []).isEmpty,
           let command = call.arguments["command"]?.asString, ActionClassifier.isGitHubNetworkCommand(command),
           await hasSavedGitHubToken() {
            call = ToolCall(name: call.name, arguments: call.arguments.merging(["use_secrets": AnyCodable(["GITHUB_TOKEN"])]) { _, new in new })
        }

        let evaluationStarted = Date()
        let outcome = await gate.evaluate(call)
        // Judging a call is instant; anything longer was a person deciding.
        let waited = Date().timeIntervalSince(evaluationStarted)
        if waited > 1 { secondsWaitingForHuman += waited }
        switch outcome {
        case .freeze(let why):
            // Keep the transcript well-formed: the assistant's tool call gets an answer.
            appendToolResult(name: call.name, observation: ["error": "run frozen by guardrails: \(why)"])
            let error = RuntimeError.frozen(why)
            emitAbortMessage(for: error)
            onEvent(.status(.aborted("\(error)")))
            return false
        case .refuse(let message):
            appendToolResult(name: call.name, observation: ["error": message])
            noteFailure(FailureCheck.kind(["error": message]), key: call.name + message)
            if abortForFailures { return stopForFailures() }
            return true
        case .held(let note, let stored):
            onEvent(.toolStarted(name: call.name, argumentsJSON: jsonString(call.arguments.mapValues(\.value))))
            appendToolResult(name: call.name, observation: ["ok": stored, "held_for_review": stored, "note": note])
            onEvent(.toolCompleted(name: call.name, resultJSON: jsonString(["held_for_review": stored])))
            return true
        case .run(let decision, let askedHuman):
            if askedHuman {
                onEvent(.status(.executing(iteration: iterations, maxIterations: budgets.maxIterations)))
            }
            await execute(call, repeatCount: repeatCount, decision: decision)
            switch Reliability.isOn(.loopGuards) ? stuck.recordAction(Self.repeatFingerprint(for: call)) : .fine {
            case .abort(let why): abortForStuck = why
            case .nudge(let text): messages.append(ChatMessage(role: .user, content: text))
            case .fine: break
            }
            if let why = abortForStuck {
                let error = RuntimeError.repeated(why)
                emitAbortMessage(for: error)
                onEvent(.status(.aborted("\(error)")))
                return false
            }
            if abortForFailures { return stopForFailures() }
            if abortForStale {
                let error = RuntimeError.repeated("nothing new came back for \(staleStreak) calls in a row: it was waiting, not working")
                emitAbortMessage(for: error)
                onEvent(.status(.aborted("\(error)")))
                return false
            }
            if abortForSameResults {
                let error = RuntimeError.repeated("'\(call.name)' kept returning the same result; the run was going in circles")
                emitAbortMessage(for: error)
                onEvent(.status(.aborted("\(error)")))
                return false
            }
            return true
        }
    }

    private func execute(_ call: ToolCall, repeatCount: Int, decision: GuardrailDecision) async {
        onEvent(.toolStarted(name: call.name, argumentsJSON: jsonString(call.arguments.mapValues(\.value))))
        let toolStarted = Date()
        var observation = await tools.execute(
            name: call.name, arguments: call.arguments, sandboxID: sandboxID, sandbox: sandbox, secretStore: secretStore
        )
        let screenshotBase64 = observation.removeValue(forKey: "_base64") as? String
        // What the model reads (and the console shows): bounded, with grounded warnings/hints added.
        var shown = observation
        if Reliability.isOn(.outputLimits) { shown = ObservationPolicy.bounded(shown) }
        if Reliability.isOn(.failureHints) { shown = ObservationPolicy.annotate(tool: call.name, observation: shown) }
        appendToolResult(name: call.name, observation: shown)
        onEvent(.toolCompleted(name: call.name, resultJSON: jsonString(shown)))
        // Something changed on the machine (an install, a write, a command with side effects): checking again
        // is now a different question, so earlier identical checks no longer count as a loop.
        if !ObservationPolicy.isObservation(decision) {
            callFingerprints.removeAll()
            lastResultKey = ""
            sameResultStreak = 0
            stuck.reset()
        }
        noteError(call, observation: observation)
        noteFailure(FailureCheck.kind(shown), key: call.name + FailureCheck.key(shown))
        Telemetry.recorder.toolRun(call.name, seconds: Date().timeIntervalSince(toolStarted), failed: FailureCheck.kind(shown) != .ok)
        let streak = noteResult(call, observation: observation)
        if Reliability.isOn(.loopGuards), let key = staleKey(call, observation: observation) {
            staleStreak = seenResults.saw(key) ? staleStreak + 1 : 0
            if staleStreak == Self.staleNudgeAt {
                messages.append(ChatMessage(
                    role: .user,
                    content: "Your last \(staleStreak) results were all ones you had already seen (this turn or an earlier one): "
                        + "nothing has changed. Checking again won't change it. If you're waiting on someone (a push, a review, a "
                        + "decision), say in one line what you're waiting for and end your turn now; you'll be woken when they post. "
                        + "If you're the one who should act, act on what you already know."
                ))
            } else if staleStreak >= Self.staleAbortAt {
                abortForStale = true
            }
        }
        if !Reliability.isOn(.loopGuards) {
            // same-result guard switched off
        } else if streak == Self.sameResultNudgeAt {
            messages.append(ChatMessage(
                role: .user,
                content: "\(call.name) has now returned the identical result \(streak) times in a row. Running it again, even "
                    + "reworded, will not change the answer. An empty or negative result is information: change your approach "
                    + "(for example, a package lookup that prints nothing usually means the package lists are not loaded: run "
                    + "`sudo apt-get update` first), do what the result implies, or say plainly that you are blocked and what you need."
            ))
        } else if streak >= Self.sameResultAbortAt {
            abortForSameResults = true
        }

        // Whatever this call brought into context may be attacker-controlled.
        if let notice = await gate.didExecute(call, decision: decision, observation: observation) {
            onEvent(.message(ChatMessage(role: .system, content: notice)))
        }

        // Escalating nudges before `checkRepeat`'s own hard abort at
        // `loopRepeatThreshold` — that only ever fires silently-until-
        // aborted with no chance for the model to course-correct first.
        // A soft one at the SECOND identical call; observed in practice
        // (a local model re-querying `list_routines`/`recall_memory`
        // instead of acting on what it already has) to sometimes not be
        // enough on its own, so the LAST allowed repeat before the hard
        // cutoff gets a much more insistent one — spelling out that an
        // empty/negative result IS the answer, not a reason to check
        // again, since that's specifically the case observed getting
        // stuck: checking whether something exists, finding it doesn't,
        // and re-checking instead of creating it.
        if repeatCount == 2 {
            messages.append(ChatMessage(
                role: .user,
                content: "You just called \(call.name) again with the exact same arguments — you already "
                    + "have that result above, calling it again won't produce a different answer. If "
                    + "you're trying to verify something, act on what you already learned now instead of "
                    + "re-checking; repeating this same call much more will end the run early with no result."
            ))
        } else if repeatCount == Self.loopRepeatThreshold {
            messages.append(ChatMessage(
                role: .user,
                content: "This is the SAME '\(call.name)' call for the \(repeatCount)rd time in a row, "
                    + "with no different action taken in between — ONE more repeat of it will end this "
                    + "run early with nothing accomplished. If you were checking whether something exists "
                    + "and the result says it doesn't, that IS your answer — take whatever action follows "
                    + "from that now (e.g. create it) instead of checking a fourth time."
            ))
        }

        // Not just the `screenshot` tool: `click` and `type_text` now attach
        // their own verification screenshot too (see ToolRegistry), so the
        // model sees the result of an action whether or not it thought to
        // ask for it — that used to be optional and was reliably skipped.
        guard let base64 = screenshotBase64 else { return }
        if await model.supportsVision(model: modelName) {
            messages.append(ChatMessage(
                role: .user,
                content: "Here is the current screenshot. Compare it against what you expected to happen — "
                    + "does it actually show the intended effect? Don't assume the previous action worked "
                    + "just because it returned ok:true.",
                images: [base64]
            ))
            pruneOldScreenshots()
        } else {
            messages.append(ChatMessage(
                role: .user,
                content: "(a screenshot was taken, but the active model has no vision support and cannot see it)"
            ))
        }
    }

    /// Keeps only the most recent `maxRetainedImages` screenshots in
    /// context, replacing older ones with a text placeholder. Screenshots
    /// are the dominant token cost in a long GUI-driving run — this is the
    /// same image-pruning Anthropic's own computer-use reference
    /// implementation does, for the same reason: a screenshot from 10 turns
    /// ago that the model no longer needs still costs the same tokens as a
    /// current one if left in context.
    private func pruneOldScreenshots() {
        let imageIndices = messages.indices.filter { !(messages[$0].images ?? []).isEmpty }
        guard imageIndices.count > Self.maxRetainedImages else { return }
        for index in imageIndices.dropLast(Self.maxRetainedImages) {
            messages[index].images = nil
            messages[index].content = "(an older screenshot was here; it's been removed to save context — "
                + "take a fresh one if you need to see current state)"
        }
    }

    // MARK: - Budgets and loop detection

    /// Surfaces *why* a run stopped short of `finish_task` as a real
    /// `.message` event — a budget/repeat-loop abort or a model-call
    /// failure used to only ever set `.status(...)`, which a live 1:1
    /// chat reflects via its own status line, but a caller that only
    /// looks at `.message` events (`Bot.runIsolatedTask`, behind every
    /// group-turn reply and delegation) had nothing to go on and fell
    /// back to a silent "didn't produce a response" placeholder no
    /// matter what actually happened. Skipped for a user-initiated
    /// `.cancelled` (`Bot.stop()`) — that's an intentional interrupt,
    /// not a failure worth narrating.
    private func emitAbortMessage(for error: Error) {
        stopReason = ModelConnection.isConnectionProblem(error) ? "model server unreachable" : "\(error)"
        if case RuntimeError.cancelled = error { stopReason = "stopped by the user"; return }
        // A dead model server is not something the bot said or did: one plain sentence, not the raw URL error.
        if ModelConnection.isConnectionProblem(error) {
            onEvent(.message(ChatMessage(role: .assistant, content: ModelConnection.friendlyMessage(for: error), isTaskSummary: true)))
            return
        }
        onEvent(.message(ChatMessage(role: .assistant, content: "(stopped early: \(error))", isTaskSummary: true)))
    }

    // MARK: - Context compaction

    /// No real tokenizer available client-side for an arbitrary backend
    /// (Ollama, an OpenAI-compatible endpoint, whatever model a bot is
    /// configured with) — this is the same rough ~4-characters-per-token
    /// heuristic most context-management guidance uses. Not meant to be
    /// exact, just enough to catch "getting close to a model's context
    /// window" before that window gets hit for real.
    private func estimatedTokens(for message: ChatMessage) -> Int {
        // utf8.count is O(1) for native strings; .count walks every character.
        var characters = message.content.utf8.count
        if let toolCalls = message.toolCalls {
            for call in toolCalls {
                characters += call.name.count + jsonString(call.arguments.mapValues(\.value)).count
            }
        }
        // Images cost far more than their small base64 byte count would
        // suggest under this character heuristic — a single screenshot
        // can be worth thousands of real tokens — so they get their own
        // flat per-image estimate instead of falling through the /4 math
        // above, which would badly undercount them.
        let imageTokens = (message.images?.count ?? 0) * 1_100
        return characters / 4 + imageTokens
    }

    /// Checked once per loop iteration, same cadence as `checkBudgets`.
    /// A no-op unless the running estimate crosses
    /// `budgets.compactionThresholdTokens`.
    private func compactContextIfNeeded() async {
        let threshold = budgets.compactionThresholdTokens > 0 ? budgets.compactionThresholdTokens
            : ContextBudget.compactionThreshold(window: contextWindow, schemaTokens: schemaTokens)
        let estimatedTotal = messages.reduce(0) { $0 + estimatedTokens(for: $1) }
        // The server's own count of the last prompt catches what the estimate misses (tool definitions,
        // formatting); it includes the schemas, so compare it against the whole usable window.
        let reported = lastPromptTokens - schemaTokens
        guard max(estimatedTotal, reported) > threshold else { return }
        // Old tool output is usually most of it: dropping that first is free, a summary costs a model call.
        let collapsed = ObservationPolicy.collapseStale(messages, keepLast: 4, minCharacters: 400, batch: 1)
        if collapsed.reduce(0, { $0 + estimatedTokens(for: $1) }) < Int(Double(threshold) * 0.7) {
            messages = collapsed
            lastPromptTokens = 0
            chargedThrough = messages.count
            return
        }
        await compact()
        // Aim well under the threshold so the next compaction isn't a few calls away.
        if messages.reduce(0, { $0 + estimatedTokens(for: $1) }) > Int(Double(threshold) * 0.7) {
            messages = ObservationPolicy.collapseStale(messages, keepLast: 4, minCharacters: 400, batch: 1)
        }
        // Still too big (a few huge recent tool results): shrink older results harder.
        if messages.reduce(0, { $0 + estimatedTokens(for: $1) }) > threshold {
            messages = ObservationPolicy.collapseStale(messages, keepLast: 3, minCharacters: 400, batch: 1)
        }
        lastPromptTokens = 0
        chargedThrough = messages.count
    }

    private var contextWindow: Int { isLocalModel ? OllamaBackend.contextWindowTokens : 32_768 }

    private func chargeUsage(_ usage: TokenUsage?) {
        guard let usage else { return }
        if countsResentContext {
            tokensUsed += usage.total
        } else {
            let added = messages.dropFirst(min(chargedThrough, messages.count)).reduce(0) { $0 + estimatedTokens(for: $1) }
            tokensUsed += usage.completionTokens + added
            chargedThrough = messages.count + 1   // the reply appended next is already counted as completion
        }
        lastPromptTokens = usage.promptTokens
    }

    /// Keeps `messages[0]` (the system prompt) and the most recent
    /// turns untouched, and replaces everything else with ONE summary
    /// message — asking the model itself to condense it, so what's kept
    /// is an actual digest of what mattered rather than a blind
    /// truncation that could drop something the model still needs. The
    /// cut point is snapped backward off of any `.tool` message so a
    /// tool call and its result (which some backends require adjacent)
    /// are never split across the kept/summarized boundary.
    private func compact() async {
        let keepRecentCount = 10
        guard messages.count > keepRecentCount + 3 else { return }
        var cutIndex = messages.count - keepRecentCount
        while cutIndex > 1, messages[cutIndex].role == .tool {
            cutIndex -= 1
        }
        guard cutIndex > 1 else { return }

        // The task itself stays word for word when it's a reasonable size: losing it is how a bot forgets
        // what it was asked to do.
        let taskMessage = messages[1]
        let keepTask = taskMessage.role == .user && estimatedTokens(for: taskMessage) <= contextWindow / 5
        let firstSummarized = keepTask ? 2 : 1
        // Too little old history to be worth a summary call: the size is in recent tool output instead,
        // which `compactContextIfNeeded` shrinks next.
        guard cutIndex - firstSummarized >= 4 else { return }
        let toSummarize = Array(messages[firstSummarized..<cutIndex])
        let kept = Array(messages[cutIndex...])
        // Images stripped from the copies sent for summarizing — the
        // point is a text digest, not reproducing them, and this keeps
        // the summarization call itself cheap and working even when the
        // active model has no vision support.
        var summaryRequest = toSummarize.map { message -> ChatMessage in
            var stripped = message
            stripped.images = nil
            return stripped
        }
        summaryRequest.append(ChatMessage(
            role: .user,
            content: ContextBudget.summaryInstruction
        ))

        let summaryText: String
        do {
            let reply = try await model.chat(messages: summaryRequest, tools: [], model: modelName, temperature: 0.2)
            if let usage = reply.usage { tokensUsed += countsResentContext ? usage.total : usage.completionTokens }
            summaryText = ContextBudget.cleanSummary(reply.message.content)
        } catch {
            // Don't lose history over a failed summarization attempt —
            // just skip compaction this time; the normal budget checks
            // still apply next iteration regardless.
            return
        }
        guard !summaryText.isEmpty else { return }

        let droppedCount = toSummarize.count
        let summaryMessage = ChatMessage(
            role: .user,
            content: "(Earlier conversation summarized to keep this within the model's context — "
                + "nothing before this point is verbatim anymore:)\n\n\(summaryText)"
        )
        messages = [messages[0]] + (keepTask ? [taskMessage] : []) + [summaryMessage] + kept
        onEvent(.contextCompacted(summary: summaryText))
        Telemetry.recorder.compaction(dropped: droppedCount)
        // `.system` role specifically: `Bot.handleEvent`'s `.message`
        // case drops system-role content from the visible chat (it
        // would just be noise there), but `logToDebugConsole` sees
        // every event regardless of role — so this shows up in the
        // debug console without cluttering the actual conversation.
        onEvent(.message(ChatMessage(role: .system, content: "Context compacted: summarized \(droppedCount) earlier messages into one.")))
    }

    private func checkBudgets() throws {
        // Checked once per loop iteration — between tool calls, not
        // strictly mid-model-call, but a cancelled outer `Task` also
        // propagates into the in-flight `model.chatStream`/`run_shell`
        // await (URLSession's async APIs throw on cancellation), so a
        // "Stop" tends to land immediately either way. See `Bot.stop()`.
        if Task.isCancelled {
            throw RuntimeError.cancelled
        }
        if iterations >= budgets.maxIterations {
            throw RuntimeError.budgetExceeded("max iterations (\(budgets.maxIterations)) reached")
        }
        if Date().timeIntervalSince(startedAt) - secondsWaitingForHuman > budgets.maxWallSeconds {
            throw RuntimeError.budgetExceeded("max wall-clock time (\(Int(budgets.maxWallSeconds))s) exceeded")
        }
        if tokensUsed > budgets.maxTokens {
            throw RuntimeError.budgetExceeded("max tokens (\(budgets.maxTokens)) exceeded")
        }
    }

    /// Returns how many times (including this one) `call` has been made
    /// with these exact arguments in this run — `execute` uses it to
    /// nudge the model once, well before the hard abort below.
    @discardableResult
    private func checkRepeat(_ call: ToolCall) throws -> Int {
        let key = Self.repeatFingerprint(for: call)
        let count = (callFingerprints[key] ?? 0) + 1
        callFingerprints[key] = count
        if count > Self.loopRepeatThreshold {
            throw RuntimeError.repeated("repeated the same '\(call.name)' call too many times")
        }
        return count
    }

    /// What counts as "the same call". Exact argument equality missed a model re-running one check with
    /// cosmetic changes (`| head -20`, an added `timeout`, echo labels, a duplicated clause), so shell
    /// commands are reduced to their set of real commands, and `timeout` is ignored everywhere.
    static func repeatFingerprint(for call: ToolCall) -> String {
        var args = call.arguments
        args["timeout"] = nil
        if call.name == "run_shell", let command = args["command"]?.asString {
            args["command"] = AnyCodable(normalizedShell(command))
        }
        let data = try? JSONSerialization.data(withJSONObject: args.mapValues(\.value), options: [.sortedKeys])
        return "\(call.name)|" + (data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
    }

    static func normalizedShell(_ command: String) -> String {
        var text = command
        for noise in ["2>&1", "2>/dev/null", "1>/dev/null", ">/dev/null"] { text = text.replacingOccurrences(of: noise, with: " ") }
        let separators = CharacterSet(charactersIn: ";\n")
        var parts: [String] = []
        for rawPart in text.components(separatedBy: separators) {
            // `a && b || c` -> a, b, c
            for sub in rawPart.replacingOccurrences(of: "&&", with: ";").replacingOccurrences(of: "||", with: ";").components(separatedBy: ";") {
                var piece = sub.trimmingCharacters(in: .whitespaces)
                // drop display-only pipes
                if let pipe = piece.range(of: #"\|\s*(head|tail)\b.*$"#, options: .regularExpression) { piece.removeSubrange(pipe) }
                piece = piece.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
                if piece.isEmpty || piece.hasPrefix("echo ") || piece == "echo" || piece.hasPrefix("exit=") { continue }
                parts.append(piece)
            }
        }
        return Array(Set(parts)).sorted().joined(separator: " ; ")
    }

    /// A tool returning the very same result again and again means the model is going in circles,
    /// whatever the arguments look like.
    private func noteResult(_ call: ToolCall, observation: [String: Any]) -> Int {
        let key = call.name + "|" + jsonString(observation)
        if key == lastResultKey { sameResultStreak += 1 } else { lastResultKey = key; sameResultStreak = 1 }
        return sameResultStreak
    }

    /// What a result says, for `seenResults`: shell output without echo labels or checkout chatter. `nil` for
    /// tiny or write-type results, which neither count nor reset the streak.
    private func staleKey(_ call: ToolCall, observation: [String: Any]) -> String? {
        if ["update_user", "post_to_group", "message_bot", "write_file", "edit_file", "remember", "finish_task"].contains(call.name) { return nil }
        let text: String
        if call.name == "run_shell" {
            let raw = ["stdout", "stderr", "error"].compactMap { observation[$0] as? String }.joined(separator: "\n")
            text = raw.split(separator: "\n").filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !(t.hasPrefix("---") || t.hasPrefix("===") || t.hasPrefix("Already on ") || t.hasPrefix("Switched to branch "))
            }.joined(separator: "\n")
        } else {
            text = jsonString(observation)
        }
        guard text.count >= 40 else { return nil }
        return call.name + "|" + text
    }

    // MARK: - Transcript helpers

    /// The third identical error from one tool this turn gets a single message naming it, before the
    /// loop guards would stop the run.
    /// The user wants to hear about a problem before the bot takes more actions on it: a hard failure,
    /// or two failures in a row, tell it to stop and report; a third in a row ends the run.
    private func noteFailure(_ kind: FailureCheck.Kind, key: String) {
        guard Reliability.isOn(.loopGuards) else { return }
        guard kind != .ok else { failureStreak = 0; sameFailureStreak = 0; lastFailureKey = ""; return }
        failureStreak += 1
        sameFailureStreak = key == lastFailureKey ? sameFailureStreak + 1 : 1
        lastFailureKey = key
        // Stop on the same failure three times (nothing new is being learned), or six failures of any kind.
        // A test that fails differently each run is debugging, not a loop.
        if sameFailureStreak >= FailureCheck.stopAfter || failureStreak >= FailureCheck.stopAfterAny {
            abortForFailures = true
        } else if kind == .blocked {
            messages.append(ChatMessage(role: .user, content: FailureCheck.blockedNotice))
        } else if kind == .hard || sameFailureStreak == 2 || failureStreak == FailureCheck.stopAfter {
            messages.append(ChatMessage(role: .user, content: FailureCheck.stopNotice))
        }
    }

    private func stopForFailures() -> Bool {
        let error = RuntimeError.repeated(sameFailureStreak >= FailureCheck.stopAfter
            ? "the same action failed \(sameFailureStreak) times in a row, so it stopped to check with you before trying anything else"
            : "\(failureStreak) actions in a row failed, so it stopped to check with you before trying anything else")
        emitAbortMessage(for: error)
        onEvent(.status(.aborted("\(error)")))
        return false
    }

    private func noteError(_ call: ToolCall, observation: [String: Any]) {
        guard Reliability.isOn(.loopGuards) else { return }
        var error = observation["error"] as? String ?? ""
        if error.isEmpty, let code = observation["exit_code"] as? Int, code != 0 {
            error = (observation["stderr"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !error.isEmpty else { return }
        let normalized = String(error.prefix(300)).replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
        let key = call.name + "|" + normalized
        errorCounts[key, default: 0] += 1
        guard errorCounts[key] == Self.sameErrorNudgeAt else { return }
        messages.append(ChatMessage(role: .user, content:
            "[stuck] \(call.name) has failed \(Self.sameErrorNudgeAt) times with the same error: \"\(String(error.prefix(240)))\". "
            + "Repeating it won't help. Read the error, check your assumptions (path, name, arguments, whether a tool is installed), "
            + "and try a different approach; if you can't, finish_task with outcome \"blocked\" and say what you need."))
    }

    private func appendToolResult(name: String, observation: [String: Any]) {
        let message = ChatMessage(role: .tool, content: jsonString(observation), toolName: name)
        messages.append(message)
        onEvent(.message(message))
    }

    private func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            return "{\"error\":\"failed to encode tool result\"}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
