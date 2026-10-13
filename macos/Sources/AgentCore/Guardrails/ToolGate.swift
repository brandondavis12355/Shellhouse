import Foundation

/// The single place a tool call is judged, shared by every agent engine
/// (the built-in `AgentRuntime` and the smolagents engine), so both obey the
/// same guardrails: classify → combine with run taint → deny / ask / allow →
/// approvals bound to the exact action → audit → checkpoint → circuit breaker.
public actor ToolGate {
    public enum Outcome: Sendable {
        /// Go ahead and execute. `askedHuman` is true if a person just approved it.
        case run(GuardrailDecision, askedHuman: Bool)
        /// Do not execute; tell the model this.
        case refuse(String)
        /// A durable change was held for the user's review (or dropped).
        case held(note: String, stored: Bool)
        /// The circuit breaker tripped; stop the whole run.
        case freeze(String)
    }

    private let sandboxID: String
    private let sandbox: any SandboxProvider
    private let permissions: RunShellPermissions
    private let config: GuardrailConfig
    private let audit: AuditLog?
    private let inbox: PendingInboxStore?
    private let requestApproval: @Sendable (Approval) async -> AgentRuntime.ApprovalDecision
    private let onEvent: @Sendable (AgentRuntime.Event) -> Void
    private let friendSafeTools: Set<String>
    private let reviewer: ActionReviewer?
    /// The user's current request, for the reviewer.
    private var task = ""

    private var taint: TaintState
    private var runGuard: RunGuard
    private var browserEngaged = false
    /// Bumped whenever the run's trust state changes; lets an approval notice that it went stale.
    private var taintVersion = 0

    /// How long a strict approval stays valid after it is shown.
    public static let strictApprovalTTL: TimeInterval = 900

    public init(
        sandboxID: String,
        sandbox: any SandboxProvider,
        permissions: RunShellPermissions,
        config: GuardrailConfig,
        limits: RunLimits,
        audit: AuditLog?,
        inbox: PendingInboxStore?,
        initialTaint: [TaintSource],
        friendSafeTools: Set<String>,
        reviewer: ActionReviewer? = nil,
        requestApproval: @escaping @Sendable (Approval) async -> AgentRuntime.ApprovalDecision,
        onEvent: @escaping @Sendable (AgentRuntime.Event) -> Void
    ) {
        self.reviewer = reviewer
        self.sandboxID = sandboxID
        self.sandbox = sandbox
        self.permissions = permissions
        self.config = config
        self.audit = audit
        self.inbox = inbox
        self.taint = TaintState(sources: initialTaint)
        self.runGuard = RunGuard(limits: limits)
        self.friendSafeTools = friendSafeTools
        self.requestApproval = requestApproval
        self.onEvent = onEvent
    }

    // MARK: state

    public var isTainted: Bool { taint.isTainted }
    public var taintSources: [String] { taint.sources.map(\.rawValue) }

    /// The user vouches that the conversation is trustworthy again. A friend's
    /// message can't be vouched away.
    public func clearTaint() {
        taint = TaintState(sources: taint.hasFriend ? [.friendMessage] : [])
        browserEngaged = false
        taintVersion += 1
    }

    public func setTask(_ text: String) { task = text }

    public func mark(_ source: TaintSource) {
        if taint.mark(source) { taintVersion += 1 }
    }

    // MARK: YOLO

    /// Strict findings YOLO still waves through on a clean run: privilege use inside the bot's own
    /// disposable VM, and deletes (which are checkpointed to the trash first). Everything else strict
    /// (GitHub/remote actions, disk tools, force-pushes, deleting outside the workspace...) keeps asking.
    public static let yoloStrictRules: Set<String> = ["exec.privilege", "destroy.rm_recursive", "destroy.rm_many"]

    /// Read live from the setting, not only from the config captured when the run began: a chat that is
    /// already open must honor the switch the moment it is flipped.
    private var yoloOn: Bool { config.yolo || UserDefaults.standard.bool(forKey: GuardrailConfig.yoloKey) }

    func yoloApplies(to call: ToolCall, _ decision: GuardrailDecision) -> Bool {
        yoloVerdict(for: call, decision).applies
    }

    /// Whether YOLO waves this call through, and if not, why (shown on the approval card so it is never a mystery).
    func yoloVerdict(for call: ToolCall, _ decision: GuardrailDecision) -> (applies: Bool, reason: String?) {
        guard yoloOn else { return (false, nil) }
        if taint.hasFriend { return (false, "YOLO is on, but a friend's message is in this chat, so everything beyond bookkeeping asks.") }
        let classification = ActionClassifier.classify(tool: call.name, arguments: call.arguments, config: config)
        let untrusted = decision.tainted || taint.isTainted
        if untrusted {
            // After reading untrusted content, only calls that cannot change anything or reach anywhere are waved
            // through: every finding is plain read-only and none is stricter than a normal ask when tainted.
            let readOnly = !classification.findings.isEmpty
                && classification.findings.allSatisfy { $0.effect == .observe && $0.tainted <= .ask && !$0.tripwire }
            if readOnly, decision.verdict <= .ask { return (true, nil) }
            let sources = taint.sources.map(\.rawValue).joined(separator: ", ")
            return (false, "YOLO is on, but this run has read untrusted content (\(sources.isEmpty ? "see audit log" : sources)), so anything that changes something still asks. Read-only commands don't.")
        }
        if decision.verdict == .ask { return (true, nil) }
        guard decision.verdict == .askStrict else { return (false, nil) }
        // Strict: allowed only when EVERY strict finding is one of the sanctioned kinds.
        let strict = classification.findings.filter { $0.clean >= .askStrict }
        if !strict.isEmpty, strict.allSatisfy({ Self.yoloStrictRules.contains($0.rule) && !$0.tripwire }) { return (true, nil) }
        return (false, "YOLO is on, but this is a high-risk action (\(decision.reasons.first ?? "strict")), which always asks.")
    }

    // MARK: judging a call

    public func evaluate(_ call: ToolCall) async -> Outcome {
        do { try runGuard.recordCall(tool: call.name) } catch {
            return await freeze(call, "\(error)", decision: nil)
        }

        let decision = GuardrailPolicy.evaluate(
            tool: call.name,
            arguments: call.arguments,
            baseline: Policy.evaluate(tool: call.name),
            taint: taint,
            config: config,
            friendSafeTools: friendSafeTools
        )

        switch decision.verdict {
        case .deny:
            await record(call, decision, outcome: decision.tripwire ? "tripwire" : "denied")
            if decision.tripwire {
                return await freeze(call, "the agent touched a decoy credential", decision: decision)
            }
            do { try runGuard.recordBlocked() } catch {
                return await freeze(call, "\(error)", decision: decision)
            }
            return .refuse("blocked by guardrails: \(decision.reasons.joined(separator: "; ")). This action is not allowed here; choose a different approach or tell the user what you need.")

        case .allow:
            if decision.quarantine { return await quarantine(call, decision) }
            return await prepareToRun(call, decision, outcome: "auto", askedHuman: false)

        case .ask, .askStrict:
            // Standing shell grants only ever satisfy a plain, clean-run ask for
            // `run_shell` (`decision.grantable`).
            let binary = call.name == "run_shell"
                ? call.arguments["command"]?.asString.flatMap(RunShellPermissions.extractBinary(fromCommand:))
                : nil
            if decision.grantable {
                if await permissions.isBlanketAllowed(botID: sandboxID) {
                    return await prepareToRun(call, decision, outcome: "granted_blanket", askedHuman: false)
                }
                if let binary, await permissions.isAllowed(binary) {
                    return await prepareToRun(call, decision, outcome: "granted_binary", askedHuman: false)
                }
            }

            // YOLO mode: a plain ask on a clean run is approved without a prompt. Hard denials never reach
            // here, and anything strict, tainted by untrusted content, or tied to a friend still asks.
            let yolo = yoloVerdict(for: call, decision)
            if yolo.applies {
                return await prepareToRun(call, decision, outcome: "yolo_auto", askedHuman: false)
            }

            // The fast model settles routine asks so bots can work on their own; anything it isn't sure of
            // comes to the user with its reason.
            var reviewNote: String?
            if let reviewer, ActionReviewPrompt.isOn, ActionReviewPrompt.eligible(decision, friendInChat: taint.hasFriend) {
                let request = ActionReviewRequest(
                    tool: call.name, arguments: Self.json(call.arguments), reasons: decision.reasons,
                    untrustedSources: taint.isTainted ? taint.sources.map(\.rawValue) : [], task: task
                )
                if let review = await reviewer(request) {
                    if review.approve {
                        return await prepareToRun(call, decision, outcome: "reviewer_auto", askedHuman: false)
                    }
                    reviewNote = "Fast-model reviewer wants your OK" + (review.reason.isEmpty ? "." : ": \(review.reason)")
                }
            }

            onEvent(.status(.waitingForApproval))
            let shownAt = Date()
            let versionAtPrompt = taintVersion
            let approval = Approval(
                taskID: sandboxID,
                toolName: call.name,
                argumentsSummary: Self.json(call.arguments),
                alwaysAllowCandidate: decision.grantable ? binary : nil,
                untrusted: decision.tainted,
                effect: decision.effect.rawValue,
                reasons: (reviewNote.map { [$0] } ?? []) + decision.reasons + (yolo.reason.map { [$0] } ?? []),
                strict: decision.isStrict,
                argsDigest: ArgsDigest.digest(tool: call.name, arguments: call.arguments),
                sources: taint.sources.map(\.rawValue),
                expiresAt: decision.isStrict ? shownAt.addingTimeInterval(Self.strictApprovalTTL) : nil
            )
            onEvent(.approvalNeeded(approval))
            let answer = await requestApproval(approval)

            // A strict approval that sat unanswered past its TTL is void.
            if let expiry = approval.expiresAt, Date() > expiry, answer != .deny {
                await record(call, decision, outcome: "approval_expired")
                return .refuse("approval expired; ask again if this is still needed")
            }

            // The run may have read untrusted content while the card was open. If
            // that makes this action stricter than what the person approved, the
            // approval no longer applies.
            if answer != .deny, taintVersion != versionAtPrompt {
                let now = GuardrailPolicy.evaluate(
                    tool: call.name, arguments: call.arguments, baseline: Policy.evaluate(tool: call.name),
                    taint: taint, config: config, friendSafeTools: friendSafeTools
                )
                if now.verdict > decision.verdict {
                    await record(call, now, outcome: "approval_stale")
                    return .refuse("the situation changed while this was waiting for approval (untrusted content was read); ask again")
                }
            }

            switch answer {
            case .deny:
                await record(call, decision, outcome: "denied_by_user")
                do { try runGuard.recordBlocked() } catch {
                    return await freeze(call, "\(error)", decision: decision)
                }
                return .refuse("denied by user")
            case .approveAlwaysSession where decision.grantable:
                if let binary { await permissions.allow(binary, scope: .session) }
            case .approveAlwaysGlobal where decision.grantable:
                if let binary { await permissions.allow(binary, scope: .global) }
            case .approveAllShellThisBotSession where decision.grantable:
                await permissions.allowAll(botID: sandboxID, scope: .botSession)
            case .approveAllShellThisBotAlways where decision.grantable:
                await permissions.allowAll(botID: sandboxID, scope: .botAlways)
            case .approve, .approveAlwaysSession, .approveAlwaysGlobal, .approveAllShellThisBotSession,
                 .approveAllShellThisBotAlways, .approveAllShellEveryBot:
                // Strict / untrusted cases land here: approve this ONE call and
                // record nothing. (The global "every bot" grant is retired.)
                break
            }
            return await prepareToRun(call, decision, outcome: "approved", askedHuman: true)
        }
    }

    /// Called after the tool ran. Returns a notice to show if the run just became untrusted.
    public func didExecute(_ call: ToolCall, decision: GuardrailDecision, observation: [String: Any]) -> String? {
        if TaintRules.opensBrowser(tool: call.name, arguments: call.arguments) { browserEngaged = true }
        let introduced = TaintRules.sources(
            tool: call.name, arguments: call.arguments, rules: decision.rules,
            observation: observation, browserEngaged: browserEngaged
        )
        var newly = false
        for source in introduced where taint.mark(source) { newly = true }
        if newly { taintVersion += 1 }
        guard newly else { return nil }
        return "Guardrails: this run now includes untrusted content (\(taint.summary)). Destructive and credential actions are blocked, "
            + "standing approvals are ignored, and changes to memory or routines are held for review."
    }

    /// For engines that run the tool elsewhere and only learn its effect
    /// beforehand: mark the run untrusted as soon as the call is allowed.
    public func anticipateTaint(_ call: ToolCall, decision: GuardrailDecision) -> String? {
        didExecute(call, decision: decision, observation: [:])
    }

    // MARK: pieces

    private func prepareToRun(_ call: ToolCall, _ decision: GuardrailDecision, outcome: String, askedHuman: Bool) async -> Outcome {
        if call.name == "write_file" {
            do { try runGuard.recordWrite(bytes: call.arguments["content"]?.asString?.utf8.count ?? 0) } catch {
                return await freeze(call, "\(error)", decision: decision)
            }
        }
        await record(call, decision, outcome: outcome)
        if !decision.checkpointPaths.isEmpty { await checkpoint(decision.checkpointPaths) }
        return .run(decision, askedHuman: askedHuman)
    }

    private func quarantine(_ call: ToolCall, _ decision: GuardrailDecision) async -> Outcome {
        await record(call, decision, outcome: "quarantined")
        var held = false
        if let inbox {
            let item = PendingItem(
                botID: sandboxID, tool: call.name, arguments: call.arguments,
                summary: "\(call.name): \(Self.preview(call))", sources: taint.sources.map(\.rawValue)
            )
            held = inbox.append(item)
        }
        let note = held
            ? "Held for the user's review. This conversation included untrusted content (\(taint.summary)), so changes to memory or routines only take effect if the user approves them. Continue without relying on it."
            : "Not saved: this conversation included untrusted content (\(taint.summary)), so changes to memory or routines are not allowed right now."
        return .held(note: note, stored: held)
    }

    private func freeze(_ call: ToolCall, _ why: String, decision: GuardrailDecision?) async -> Outcome {
        if let decision {
            await record(call, decision, outcome: "run_frozen")
        } else if let audit {
            await audit.append(
                bot: sandboxID, tool: call.name, effect: "unknown", verdict: "deny", outcome: "run_frozen",
                rules: ["circuit_breaker"], reasons: [why], tainted: taint.isTainted,
                sources: taint.sources.map(\.rawValue), preview: Self.preview(call)
            )
        }
        return .freeze(why)
    }

    private func record(_ call: ToolCall, _ decision: GuardrailDecision, outcome: String) async {
        guard let audit else { return }
        await audit.append(
            bot: sandboxID, tool: call.name, effect: decision.effect.rawValue, verdict: "\(decision.verdict)",
            outcome: outcome, rules: decision.rules, reasons: decision.reasons, tainted: decision.tainted,
            sources: taint.sources.map(\.rawValue), preview: Self.preview(call)
        )
    }

    /// Best-effort snapshot (inside the sandbox) of paths about to be
    /// overwritten or deleted, so a wrong approval is recoverable.
    private func checkpoint(_ paths: [String]) async {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        guard let command = Checkpoint.command(for: paths, stamp: stamp, config: config) else { return }
        _ = try? await sandbox.exec(sandboxID, command: command, timeout: 20, env: nil)
    }

    static func preview(_ call: ToolCall) -> String {
        switch call.name {
        case "run_shell": return call.arguments["command"]?.asString ?? ""
        case "write_file":
            let path = call.arguments["path"]?.asString ?? ""
            return "\(path) (\(call.arguments["content"]?.asString?.utf8.count ?? 0) bytes)"
        default: return json(call.arguments)
        }
    }

    static func json(_ arguments: [String: AnyCodable]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments.mapValues(\.value), options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
