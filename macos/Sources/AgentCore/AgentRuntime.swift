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
        /// Older context was shrunk (old tool output collapsed, or earlier turns summarized): what was done and the sizes, for the debug console.
        case contextTrimmed(detail: String)
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
    private let toolNames: Set<String>
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

    /// Everything that happened in this run, append-only. The prompt is `ContextView`'s reading of it.
    private var log: RunLog
    /// The gate's taint as of the last tool call, for guards (their hooks are not async).
    private var taintSnapshot: [String] = []
    private let runLogSink: (any RunLogSink)?
    private var viewCache: (count: Int, collapse: Bool, rendered: ContextView.Rendered)?
    private var rendered: ContextView.Rendered {
        let collapse = Reliability.isOn(.outputLimits)
        if let cache = viewCache, cache.count == log.count, cache.collapse == collapse { return cache.rendered }
        let fresh = ContextView(collapseOldOutput: collapse).render(log.events)
        viewCache = (log.count, collapse, fresh)
        return fresh
    }
    /// What the model is sent: the log read through `ContextView`.
    private var messages: [ChatMessage] { rendered.messages }
    /// The model reply appended last, so a guard can ask for it to be left out of the prompt.
    private var lastReplyEventID: Int?
    private var iterations = 0
    private var tokensUsed = 0
    /// For local models, `maxTokens` counts new work: replies plus what was added to the conversation since
    /// the last call. Resending the same history costs nothing extra (the server reuses its prompt cache).
    private var chargedThrough = 0
    private var lastPromptTokens = 0
    private var schemaTokens = 0
    /// The local model (also when wrapped by `ModelScheduler`): it keeps the prompt cached, so only new tokens count.
    private var isLocalModel: Bool { model.innermost is OllamaBackend }
    private var countsResentContext: Bool { !isLocalModel }
    /// Why the current turn stopped early, for telemetry (nil = it finished).
    private var stopReason: String?
    private var startedAt = Date()
    /// Time spent waiting for a person to answer an approval card: it does not count against the wall-clock budget.
    private var secondsWaitingForHuman: TimeInterval = 0
    /// Read-only calls from one reply, started together so their waits overlap (see `prefetchReads`).
    private var prefetched: [String: Task<UncheckedBox<[String: Any]>, Never>] = [:]
    static let parallelReadTools: Set<String> = ["read_file", "list_files", "search_files", "find_files"]
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
    var openPlanItems: [PlanItem] { plan.filter { $0.status == .pending || $0.status == .in_progress } }
    /// The rules of the loop, each with its own state (see `GuardSet`).
    private let guards: [any Guard]
    static let sameErrorNudgeAt = SameErrorGuard.nudgeAt
    static let plainReplyMinLength = NarrationGuard.plainReplyMinLength
    static let sameResultNudgeAt = RepeatedCallsGuard.sameResultNudgeAt
    static let sameResultAbortAt = RepeatedCallsGuard.sameResultAbortAt
    static let staleNudgeAt = StaleResultsGuard.nudgeAt
    static let staleAbortAt = StaleResultsGuard.abortAt
    private var githubTokenSaved: Bool?

    private func hasSavedGitHubToken() async -> Bool {
        if let known = githubTokenSaved { return known }
        let saved = ((try? await secretStore.list()) ?? []).contains { $0.name == "GITHUB_TOKEN" }
        githubTokenSaved = saved
        return saved
    }
    private var currentGoal = ""
    /// How many messages the conversation had after the last compaction (see `compactContextIfNeeded`).
    private var lastCompactionMessageCount: Int?

    /// Tools that may still run without approval during an untrusted run:
    /// they only read this bot's own state or update shared bookkeeping.
    static let untrustedSafeTools: Set<String> = [
        "list_files", "read_file", "search_files", "find_files", "check_job", "update_plan",
        "screenshot", "list_windows", "use_skill", "search_memory", "recall_memory",
        "list_routines", "get_profile", "list_tasks", "list_secrets", "list_bots", "complete_task", "update_user",
        "get_goal", "update_goal_step", "propose_goal", "add_goal_step", "edit_goal_step", "propose_goal_complete", "ask_helpers",
        "get_bot_instructions",
    ]

    /// Screenshots dominate token cost, so only the newest few stay in the prompt (see `ContextView`; the log keeps them all).

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
    var planText: String { PlanItem.text(of: plan) }

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
        seenResults: SeenResults = SeenResults(),
        runLogSink: (any RunLogSink)? = nil,
        onMissingPath: (@Sendable (String) -> Void)? = nil,
        guards: [any Guard]? = nil
    ) {
        self.runLogSink = runLogSink
        self.log = RunLog(sink: runLogSink)
        self.guards = guards ?? GuardSet.standard(plainReplyEndsTurn: plainReplyEndsTurn, answerEndsTurnAfterTools: answerEndsTurnAfterTools, seenResults: seenResults, onMissingPath: onMissingPath)
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
        self.toolNames = self.tools.names()
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
        guards.forEach { $0.reset(.conversation) }
        iterations = 0
        tokensUsed = 0
        chargedThrough = 0
        log = RunLog(sink: runLogSink)
        log.append(.stateNote("seeded with \(history.count) earlier messages"))
        // The earlier turns were saved by the app's transcript, not by this log: keep them in memory only.
        log.append(.system(systemPrompt), persist: false)
        for message in history { log.append(Self.event(for: message), persist: false) }
        chargedThrough = messages.count
    }

    /// Begin a brand new conversation.
    public func start(systemPrompt: String, goal: String) async {
        startedAt = Date()
        secondsWaitingForHuman = 0
        guards.forEach { $0.reset(.conversation) }
        iterations = 0
        tokensUsed = 0
        chargedThrough = 0
        log = RunLog(sink: runLogSink)
        log.append(.system(systemPrompt))
        log.append(.userMessage(content: goal, images: nil))
        currentGoal = goal
        await gate.setTask(goal)
        toolCallsThisTurn = 0
        plan = []
        guards.forEach { $0.reset(.turn); $0.reset(.run) }
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
        log.append(.userMessage(content: userMessage, images: images.isEmpty ? nil : images))
        currentGoal = userMessage
        await gate.setTask(userMessage)
        toolCallsThisTurn = 0
        plan = []
        // Loop-detection is meant to catch a model stuck repeating the SAME call within one reasoning task, not across
        // entirely separate turns: a call with no arguments, made legitimately on separate days, must not add up.
        guards.forEach { $0.reset(.turn) }
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

    private var currentReplyEventID: Int {
        log.events.last(where: { if case .modelReply = $0.kind { return true } else { return false } })?.id ?? 0
    }

    /// What the guards are shown: the run as it stands now.
    private func makeContext() -> RunContext {
        var ctx = RunContext()
        ctx.iteration = iterations
        ctx.maxIterations = budgets.maxIterations
        ctx.goal = currentGoal
        ctx.plan = plan
        ctx.toolNames = toolNames
        ctx.registrySchemas = tools.schemas
        ctx.validationSchemas = tools.schemas + [Self.finishTaskSchema]
        ctx.messages = messages
        ctx.toolCallsThisTurn = toolCallsThisTurn
        ctx.compactionThresholdTokens = budgets.compactionThresholdTokens
        ctx.contextWindow = contextWindow
        ctx.schemaTokens = schemaTokens
        ctx.lastPromptTokens = lastPromptTokens
        ctx.lastCompactionMessageCount = lastCompactionMessageCount
        ctx.taintSources = taintSnapshot
        ctx.session = log.session
        ctx.replyEventID = currentReplyEventID
        return ctx
    }

    /// A correction reaches the model as the next user turn, and is counted.
    private func apply(_ nudge: Nudge) {
        Telemetry.recorder.loopEvent(nudge.kind)
        let repeated = nudge.skipIfRepeat && messages.last?.content == nudge.text
        log.append(.nudge(kind: nudge.kind, text: nudge.text, escalation: nudge.escalation.rawValue, supersedes: nil, inContext: !repeated))
    }

    /// A guard acted without adding a turn to the prompt (it answered a call or changed a result): still logged and counted.
    private func recordFiring(kind: String, detail: String) {
        Telemetry.recorder.loopEvent(kind)
        log.append(.nudge(kind: kind, text: detail, escalation: Escalation.specific.rawValue, supersedes: nil, inContext: false))
    }

    private func stopRun(_ why: String) {
        let error = RuntimeError.repeated(why)
        emitAbortMessage(for: error)
        onEvent(.status(.aborted("\(error)")))
    }

    private enum LoopStep { case carryOn, endRun }

    /// Does what guards asked for after a reply or a batch of calls. Only nudges, drops and stops are expected here.
    private func applyAfterReply(_ actions: [GuardAction]) -> LoopStep {
        for action in actions {
            switch action {
            case .dropReply:
                if let id = lastReplyEventID {
                    log.append(.nudge(kind: "narration_dropped", text: "", escalation: 0, supersedes: id, inContext: false))
                }
            case .nudge(let nudge):
                apply(nudge)
            case .endTurn(let text):
                onEvent(.message(ChatMessage(role: .assistant, content: text, isTaskSummary: true)))
                onEvent(.status(.completed))
                return .endRun
            case .abort(let why):
                stopRun(why)
                return .endRun
            default:
                break
            }
        }
        return .carryOn
    }

    private func loop() async {
        onEvent(.status(.planning))
        // Group goal turns already have the goal's checklist; a second plan would compete with it.
        let offersPlan = !toolNames.contains("update_goal_step")
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
            iterations += 1
            for guardian in guards {
                for action in guardian.beforeModel(makeContext()) {
                    switch action {
                    case .condense(let threshold, let size): await condense(threshold: threshold, before: size)
                    case .nudge(let nudge): apply(nudge)
                    case .abort(let why): stopRun(why); return
                    default: break
                    }
                }
            }
            onEvent(.status(.executing(iteration: iterations, maxIterations: budgets.maxIterations)))

            var reply: ModelReply
            var loopBroken = false
            var attempt = 0
            while true {
                do {
                    let loopGuard = RepetitionGuard()
                    let streamed = StreamedText()
                    let backend = model
                    let schemas = toolSchemas
                    let history = messages
                    let name = modelName
                    let work = Task { [onEvent] in
                        try await backend.chatStream(
                            messages: history, tools: schemas, model: name, temperature: 0.2,
                            onDelta: { delta in
                                streamed.append(delta)
                                onEvent(.messageDelta(delta))
                                if loopGuard.feed(delta) { streamed.cancelStream() }
                            }
                        )
                    }
                    streamed.onStop { work.cancel() }
                    do {
                        reply = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    } catch where loopGuard.isTripped && !Task.isCancelled {
                        reply = Self.cutRepeatedReply(streamed.text, onEvent: onEvent)
                        loopBroken = true
                    }
                    if !loopBroken, loopGuard.isTripped, !Task.isCancelled {
                        reply = Self.cutRepeatedReply(streamed.text, onEvent: onEvent)
                        loopBroken = true
                    }
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

            // The guards read the reply before it is recorded: a call written as text becomes the call it meant.
            var queued: [GuardAction] = []
            for guardian in guards {
                for action in guardian.afterReply(reply, cutOff: loopBroken, makeContext()) {
                    if case .rewrite(let call) = action {
                        reply = ModelReply(message: ChatMessage(role: .assistant, content: "", toolCalls: [call]), usage: reply.usage)
                    } else {
                        queued.append(action)
                    }
                }
            }
            lastReplyEventID = log.append(.modelReply(reply.message)).id
            // After "I'll do X" with no tool call, the model usually repeats that sentence alongside the call:
            // show it once, not twice.
            if queued.contains(where: { if case .hideReplyText = $0 { return true } else { return false } }) {
                var shown = reply.message; shown.content = ""
                onEvent(.message(shown))
            } else {
                onEvent(.message(reply.message))
            }
            if applyAfterReply(queued) == .endRun { return }

            guard let calls = reply.message.toolCalls, !calls.isEmpty else { continue }

            if let finishCall = calls.first(where: { $0.name == Self.finishTaskName }) {
                let summary = finishCall.arguments["summary"]?.asString ?? reply.message.content
                let outcome = finishCall.arguments["outcome"]?.asString ?? "done"
                let request = FinishRequest(summary: summary, outcome: outcome, callCount: calls.count)
                if refusesFinish(request) { continue }
                onEvent(.message(ChatMessage(role: .assistant, content: summary, isTaskSummary: true)))
                onEvent(.status(outcome == "done" ? .completed : .aborted(outcome)))
                return
            }

            var ranSomething = false
            prefetchReads(calls)
            for call in calls {
                if call.name == Self.updatePlanName {
                    onEvent(.toolStarted(name: call.name, argumentsJSON: jsonString(call.arguments.mapValues(\.value))))
                    let result = updatePlan(call)
                    appendToolResult(name: call.name, observation: result)
                    onEvent(.toolCompleted(name: call.name, resultJSON: jsonString(result)))
                    continue
                }
                switch await handle(call) {
                case .stop: return
                case .ran:
                    ranSomething = true
                    toolCallsThisTurn += 1
                case .skipped: break
                }
            }
            var afterTurn: [GuardAction] = []
            for guardian in guards { afterTurn += guardian.afterTurn(ranTools: ranSomething, makeContext()) }
            if applyAfterReply(afterTurn) == .endRun { return }
        }
    }

    /// The model asked to finish: a guard may answer the call instead (the first to do so wins).
    private func refusesFinish(_ request: FinishRequest) -> Bool {
        for guardian in guards {
            for action in guardian.beforeFinish(request, makeContext()) {
                switch action {
                case .nudge(let nudge):
                    apply(nudge)
                    return true
                case .replaceResult(let json, let kind):
                    recordFiring(kind: kind, detail: json)
                    appendToolResult(name: Self.finishTaskName, content: json)
                    return true
                default:
                    break
                }
            }
        }
        return false
    }

    /// What one tool call did. `.ran` is the only result that clears the no-action counter.
    private enum StepEffect { case stop, ran, skipped }

    private static func cutRepeatedReply(_ text: String, onEvent: @escaping @Sendable (Event) -> Void) -> ModelReply {
        let once = RepetitionGuard.collapsed(text)
        onEvent(.contextTrimmed(detail: "reply cut off: the model was repeating itself (\(text.count) characters)"))
        return ModelReply(message: ChatMessage(role: .assistant, content: once), usage: nil)
    }

    /// Runs one tool call to completion.
    private func handle(_ original: ToolCall) async -> StepEffect {
        do {
            try checkBudgets()
        } catch {
            emitAbortMessage(for: error)
            onEvent(.status(.aborted("\(error)")))
            return .stop
        }

        // Before it runs, a guard may fix the call (string numbers, a text-written call), answer it (a duplicate, a
        // malformed or unknown call, a shell syntax error: a precise correction instead of an approval prompt for
        // something that cannot work), or stop the run (the same call too many times).
        var call = original
        taintSnapshot = await gate.taintSources
        for guardian in guards {
            for action in guardian.beforeTool(call, makeContext()) {
                switch action {
                case .rewrite(let rewritten): call = rewritten
                case .replaceResult(let json, let kind):
                    recordFiring(kind: kind, detail: json)
                    appendToolResult(name: call.name, content: json)
                    return .skipped
                case .nudge(let nudge): apply(nudge)
                case .abort(let why): stopRun(why); return .stop
                default: break
                }
            }
        }

        // A plain GitHub git/gh network command with no secret attached: bots often forget use_secrets and get
        // "could not read Username". When a GITHUB_TOKEN is saved, attach it (it only ever reaches github.com
        // through gh's credential helper, and the guardrails still judge the call with it attached).
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
            return .stop
        case .refuse(let message):
            appendToolResult(name: call.name, observation: ["error": message])
            let refused = ToolOutcome(kind: .refused, raw: ["error": message], shown: ["error": message])
            var stop: String?
            for guardian in guards {
                for action in guardian.afterTool(call, refused, makeContext()) {
                    switch action {
                    case .nudge(let nudge): apply(nudge)
                    case .abort(let why): stop = stop ?? why
                    default: break
                    }
                }
            }
            if let why = stop { stopRun(why); return .stop }
            return .skipped
        case .held(let note, let stored):
            onEvent(.toolStarted(name: call.name, argumentsJSON: jsonString(call.arguments.mapValues(\.value))))
            appendToolResult(name: call.name, observation: ["ok": stored, "held_for_review": stored, "note": note])
            onEvent(.toolCompleted(name: call.name, resultJSON: jsonString(["held_for_review": stored])))
            return .ran
        case .run(let decision, let askedHuman):
            if askedHuman {
                onEvent(.status(.executing(iteration: iterations, maxIterations: budgets.maxIterations)))
            }
            if let why = await execute(call, decision: decision) {
                stopRun(why)
                return .stop
            }
            return .ran
        }
    }

    /// Runs the tool and records its result. Returns why the run should stop, if a guard said so.
    private func execute(_ call: ToolCall, decision: GuardrailDecision) async -> String? {
        onEvent(.toolStarted(name: call.name, argumentsJSON: jsonString(call.arguments.mapValues(\.value))))
        let toolStarted = Date()
        var observation: [String: Any]
        if let early = prefetched.removeValue(forKey: Self.repeatFingerprint(for: call)) {
            observation = await early.value.value
        } else {
            // A tool that saves state can tell which run, and which reply, it was called from (see `MemoryBook.add`).
            let provenance = RunProvenance(session: log.session, eventID: currentReplyEventID,
                                           tainted: !taintSnapshot.isEmpty, taintSources: taintSnapshot)
            observation = await RunProvenance.$current.withValue(provenance) {
                await tools.execute(
                    name: call.name, arguments: call.arguments, sandboxID: sandboxID, sandbox: sandbox, secretStore: secretStore
                )
            }
        }
        let screenshotBase64 = observation.removeValue(forKey: "_base64") as? String
        // What the model reads (and the console shows): bounded, with grounded warnings/hints added.
        var shown = observation
        if Reliability.isOn(.outputLimits) { shown = ObservationPolicy.bounded(shown, limit: call.name == "read_file" ? PagedRead.defaultCharacterBudget + 500 : ObservationPolicy.maxFieldCharacters) }
        if Reliability.isOn(.failureHints) { shown = ObservationPolicy.annotate(tool: call.name, observation: shown) }

        // The guards look at the result, in order. Annotations and replacements shape what the model reads;
        // nudges and stops come after it in the prompt.
        var result = ToolOutcome(kind: .executed(isObservation: ObservationPolicy.isObservation(decision)), raw: observation, shown: shown)
        var replacement: String?
        var queued: [GuardAction] = []
        for guardian in guards {
            for action in guardian.afterTool(call, result, makeContext()) {
                switch action {
                case .annotate(let key, let value):
                    result.shown[key] = value
                    recordFiring(kind: guardian.id, detail: "\(key): \(value)")
                case .replaceResult(let json, let kind):
                    replacement = json
                    recordFiring(kind: kind, detail: json)
                default:
                    queued.append(action)
                }
            }
        }
        let resultText = jsonString(result.shown)
        appendToolResult(name: call.name, content: replacement ?? resultText)
        onEvent(.toolCompleted(name: call.name, resultJSON: resultText))
        Telemetry.recorder.toolRun(call.name, seconds: Date().timeIntervalSince(toolStarted), failed: FailureCheck.kind(result.shown) != .ok)

        // Whatever this call brought into context may be attacker-controlled.
        if let notice = await gate.didExecute(call, decision: decision, observation: observation) {
            onEvent(.message(ChatMessage(role: .system, content: notice)))
        }
        var stop: String?
        for action in queued {
            switch action {
            case .nudge(let nudge): apply(nudge)
            case .abort(let why): stop = stop ?? why
            default: break
            }
        }

        // Not just the `screenshot` tool: `click` and `type_text` attach their own verification screenshot too (see
        // ToolRegistry), so the model sees the result of an action whether or not it thought to ask for it.
        if let base64 = screenshotBase64 {
            if await model.supportsVision(model: modelName) {
                log.append(.screenshot(content: "Here is the current screenshot. Compare it against what you expected to happen — "
                    + "does it actually show the intended effect? Don't assume the previous action worked "
                    + "just because it returned ok:true.", images: [base64]))
            } else {
                log.append(.userMessage(content: "(a screenshot was taken, but the active model has no vision support and cannot see it)", images: nil))
            }
        }
        return stop
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

    private func estimatedTokens(for message: ChatMessage) -> Int { ContextBudget.estimatedTokens(for: message) }

    /// The context guard asked for a smaller prompt. Old tool output is usually most of it: stubbing that first is
    /// free, a summary costs a model call. Both are events in the log; nothing is edited.
    private func condense(threshold: Int, before: Int) async {
        defer { lastCompactionMessageCount = messages.count }
        let collapsedTokens = ObservationPolicy.collapseStale(messages, keepLast: 4, minCharacters: 400, batch: 1)
            .reduce(0) { $0 + estimatedTokens(for: $1) }
        if collapsedTokens < Int(Double(threshold) * 0.7) {
            log.append(.condensed(.collapse(keepLast: 4, minCharacters: 400, batch: 1)))
            lastPromptTokens = 0
            chargedThrough = messages.count
            onEvent(.contextTrimmed(detail: "collapsed old tool output (no summary needed): ~\(before) → ~\(collapsedTokens) tokens, limit \(threshold), \(messages.count) messages kept"))
            return
        }
        let countBefore = messages.count
        await compact()
        if messages.count == countBefore {
            onEvent(.contextTrimmed(detail: "over the limit (~\(before) tokens, limit \(threshold)) but nothing could be summarized yet (too little old history, or the summary call failed); shrinking recent tool output instead"))
        }
        // Aim well under the threshold so the next compaction isn't a few calls away.
        if messages.reduce(0, { $0 + estimatedTokens(for: $1) }) > Int(Double(threshold) * 0.7) {
            log.append(.condensed(.collapse(keepLast: 4, minCharacters: 400, batch: 1)))
        }
        // Still too big (a few huge recent tool results): shrink older results harder.
        if messages.reduce(0, { $0 + estimatedTokens(for: $1) }) > threshold {
            log.append(.condensed(.collapse(keepLast: 3, minCharacters: 400, batch: 1)))
        }
        let after = messages.reduce(0) { $0 + estimatedTokens(for: $1) }
        onEvent(.contextTrimmed(detail: "after compaction: ~\(before) → ~\(after) tokens, limit \(threshold), \(countBefore) → \(messages.count) messages"))
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
        let current = rendered
        let toSummarize = Array(current.messages[firstSummarized..<cutIndex])
        let firstID = current.sourceIDs[firstSummarized], lastID = current.sourceIDs[cutIndex - 1]
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
        log.append(.condensed(.summary(first: firstID, last: lastID, text: summaryText)))
        onEvent(.contextCompacted(summary: summaryText))
        Telemetry.recorder.compaction(dropped: droppedCount)
        // `.system` role specifically: `Bot.handleEvent`'s `.message`
        // case drops system-role content from the visible chat (it
        // would just be noise there), but `logToDebugConsole` sees
        // every event regardless of role — so this shows up in the
        // debug console without cluttering the actual conversation.
        onEvent(.contextTrimmed(detail: "summarized \(droppedCount) earlier messages into one"))
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
    /// Starts the reads of one multi-call reply together: each still goes through the same checks, gate and
    /// result handling in order, but the waits on the sandbox overlap instead of adding up. A read the gate
    /// then refuses is simply never used.
    private func prefetchReads(_ calls: [ToolCall]) {
        prefetched.removeAll()
        guard calls.count >= 2 else { return }
        if calls.filter({ Self.parallelReadTools.contains($0.name) }).count >= 2 { Telemetry.recorder.loopEvent("parallel_reads") }
        let backend = tools, box = sandbox, id = sandboxID, store = secretStore
        for call in calls where Self.parallelReadTools.contains(call.name) {
            let key = Self.repeatFingerprint(for: call)
            guard prefetched[key] == nil else { continue }
            prefetched[key] = Task {
                UncheckedBox(value: await backend.execute(name: call.name, arguments: call.arguments, sandboxID: id, sandbox: box, secretStore: store))
            }
        }
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
                // `head -20 f`, `tail -n 50 f`, `cat f` are one look at one file.
                if piece.range(of: #"^(cat|head|tail|less|more)( -n ?\d+| -\d+)? \S+$"#, options: .regularExpression) != nil,
                   let file = piece.split(separator: " ").last {
                    piece = "cat " + file
                }
                if piece.isEmpty || piece.hasPrefix("echo ") || piece == "echo" || piece.hasPrefix("exit=") { continue }
                parts.append(piece)
            }
        }
        return Array(Set(parts)).sorted().joined(separator: " ; ")
    }

    // MARK: - Transcript helpers

    private func appendToolResult(name: String, observation: [String: Any]) {
        appendToolResult(name: name, content: jsonString(observation))
    }

    private func appendToolResult(name: String, content: String) {
        log.append(.toolResult(name: name, content: content))
        onEvent(.message(ChatMessage(role: .tool, content: content, toolName: name)))
    }

    static func screenshotRoute(for narration: String) -> String { NarrationGuard.screenshotRoute(for: narration) }
    static var missingToolNudge: String { NarrationGuard.missingToolNudge }
    static func narrationNudge(count: Int, narration: String, toolNames: [String]) -> String {
        NarrationGuard.narrationNudge(count: count, narration: narration, toolNames: toolNames)
    }
    static func escalatedNarrationNudge(narration: String, toolNames: [String]) -> String {
        NarrationGuard.escalatedNarrationNudge(narration: narration, toolNames: toolNames)
    }

    /// A turn restored from a saved transcript, as the event it would have been.
    private static func event(for message: ChatMessage) -> RunEvent.Kind {
        switch message.role {
        case .system: return .system(message.content)
        case .user: return .userMessage(content: message.content, images: message.images)
        case .assistant: return .modelReply(message)
        case .tool: return .toolResult(name: message.toolName ?? "tool", content: message.content)
        }
    }

    private func jsonString(_ dict: [String: Any]) -> String { runJSONString(dict) }
}

/// Carries a value across a task boundary that Swift can't prove safe; used for tool results that are plain data.
struct UncheckedBox<T>: @unchecked Sendable { let value: T }
