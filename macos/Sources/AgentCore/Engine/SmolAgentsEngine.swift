import Foundation

/// Runs a bot's turn with smolagents inside the bot's own sandbox container
/// (docs/SMOLAGENTS.md). The Mac stays the authority:
///
/// - the container's runner asks the Mac before every tool call (`policy_check`)
///   and every Mac-side tool (`bridge_call`); `ToolGate` answers using the same
///   guardrails as the built-in engine;
/// - the model is reached through the token-gated `ModelProxy`, so no model
///   credentials ever enter the container;
/// - events and replies travel as small files over the existing sandbox
///   `exec` / `readFile` / `writeFile` API (protocol v1, sandbox/agent-runner/PROTOCOL.md).
///
/// The container is untrusted: everything it sends is parsed defensively,
/// size-capped, and only ever used as display text or as a *request* the Mac
/// decides on.
public actor SmolAgentsEngine: AgentEngine {
    public struct Settings: Sendable {
        /// The proxy's address as the *container* sees it (e.g. `http://172.17.0.1:18434/v1`).
        public var containerBaseURL: String
        public var pollInterval: TimeInterval
        public var runnerCommand: String
        public var planningInterval: Int?
        /// Polls with no contact before giving up on the runner.
        public var maxConsecutiveTransportFailures: Int

        public init(
            containerBaseURL: String,
            pollInterval: TimeInterval = 0.5,
            runnerCommand: String = "shellhouse-agent",
            planningInterval: Int? = nil,
            maxConsecutiveTransportFailures: Int = 60
        ) {
            self.containerBaseURL = containerBaseURL
            self.pollInterval = pollInterval
            self.runnerCommand = runnerCommand
            self.planningInterval = planningInterval
            self.maxConsecutiveTransportFailures = maxConsecutiveTransportFailures
        }
    }

    /// Tools the runner implements itself, inside the container. `read_file` and `write_file` are
    /// bridged to Swift instead, so both engines share paged reads, read-before-edit tracking for
    /// `edit_file`, and syntax checks on write (see `WorkspaceTools`). `run_shell` stays in the
    /// container, so background jobs are a built-in-engine feature for now.
    public static let inSandboxTools: Set<String> = [
        "run_shell", "list_files",
        "screenshot", "list_windows", "focus_window", "open_app", "click", "move_mouse", "find_on_page", "click_text", "fill_field", "page_text", "type_text", "press_key", "scroll",
    ]
    static let maxFieldBytes = 256 * 1024
    static let maxTailBytes = 400_000

    private let proxy: ModelProxy
    private let settings: Settings
    private let sandbox: any SandboxProvider
    private let sandboxID: String
    private let tools: ToolRegistry
    private let secretStore: SecretStore
    private let budgets: AgentRuntime.Budgets
    private let modelName: String?
    private let onEvent: @Sendable (AgentRuntime.Event) -> Void
    private let gate: ToolGate

    private var systemPrompt = ""
    private var messages: [ChatMessage] = []
    /// Time spent waiting for a human during this turn; not charged to the wall clock.
    private var approvalWait: TimeInterval = 0
    /// Text streamed so far for the reply being written (to spot tool-call-only text early).
    private var streamBuffer = ""
    private var streamForwarded = 0   // characters of `streamBuffer` already sent on
    /// The last assistant text actually shown this turn (to avoid repeating it as the final answer).
    private var lastShownAssistant: String?

    public init(
        proxy: ModelProxy,
        settings: Settings,
        sandbox: any SandboxProvider,
        sandboxID: String,
        tools: ToolRegistry,
        secretStore: SecretStore = SecretStore(),
        permissions: RunShellPermissions = RunShellPermissions(),
        budgets: AgentRuntime.Budgets = AgentRuntime.Budgets(),
        modelName: String?,
        onEvent: @escaping @Sendable (AgentRuntime.Event) -> Void = { _ in },
        requestApproval: @escaping @Sendable (Approval) async -> AgentRuntime.ApprovalDecision = { _ in .deny },
        alwaysRequireApproval: Bool = false,
        actionReviewer: ActionReviewer? = nil,
        guardrails: GuardrailConfig = .standard,
        limits: RunLimits = RunLimits(),
        audit: AuditLog? = nil,
        inbox: PendingInboxStore? = nil,
        initialTaint: [TaintSource] = []
    ) {
        self.proxy = proxy
        self.settings = settings
        self.sandbox = sandbox
        self.sandboxID = sandboxID
        self.tools = tools
        self.secretStore = secretStore
        self.budgets = budgets
        self.modelName = modelName
        self.onEvent = onEvent
        var sources = initialTaint
        if alwaysRequireApproval, !sources.contains(.friendMessage) { sources.append(.friendMessage) }
        self.gate = ToolGate(
            sandboxID: sandboxID, sandbox: sandbox, permissions: permissions, config: guardrails, limits: limits,
            audit: audit, inbox: inbox, initialTaint: sources, friendSafeTools: AgentRuntime.untrustedSafeTools,
            reviewer: actionReviewer,
            requestApproval: requestApproval, onEvent: onEvent
        )
    }

    // MARK: AgentEngine

    public func seed(systemPrompt: String, history: [ChatMessage]) {
        self.systemPrompt = systemPrompt
        self.messages = history
    }

    public func transcript() -> [ChatMessage] { messages }
    public var isTainted: Bool { get async { await gate.isTainted } }
    public var taintSources: [String] { get async { await gate.taintSources } }
    public func clearTaint() async { await gate.clearTaint() }

    public func send(_ userMessage: String, images: [String] = []) async {
        let history = messages
        messages.append(ChatMessage(role: .user, content: userMessage, images: images.isEmpty ? nil : images))
        await gate.setTask(userMessage)
        await runTurn(task: userMessage, history: history)
    }

    // MARK: a turn

    private enum Finish { case completed, aborted(String), failed(String) }

    private func runTurn(task: String, history: [ChatMessage]) async {
        guard let modelName, !modelName.isEmpty else {
            fail("No model is selected for this bot.")
            return
        }
        let runID = "run-" + UUID().uuidString.lowercased().prefix(12)
        let dir = "/workspace/.shellhouse/runs/\(runID)"
        let rel = ".shellhouse/runs/\(runID)"
        let sandbox = self.sandbox
        let sandboxID = self.sandboxID

        approvalWait = 0
        streamBuffer = ""
        streamForwarded = 0
        lastShownAssistant = nil
        onEvent(.status(.planning))
        let token = proxy.issueToken(
            allowedModel: modelName,
            maxRequests: max(8, budgets.maxIterations * 4),
            maxTotalTokens: budgets.maxTokens,
            ttl: budgets.maxWallSeconds + 120
        )
        defer { proxy.revoke(token) }

        let config = await Self.makeConfig(
            runID: runID, baseURL: settings.containerBaseURL, token: token, model: modelName,
            systemPrompt: systemPrompt, history: history, task: task, budgets: budgets,
            planningInterval: settings.planningInterval, tainted: await gate.isTainted,
            toolSchemas: tools.schemas, availableTools: Array(tools.names())
        )
        guard let configData = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else {
            fail("Could not build the runner configuration.")
            return
        }

        // Fail early and clearly if this sandbox predates the runner (a container
        // keeps the image it was created from until it is reset).
        let runnerName = settings.runnerCommand.split(separator: " ").first.map(String.init) ?? "shellhouse-agent"
        if let probe = try? await sandbox.exec(sandboxID, command: "command -v '\(runnerName)' >/dev/null 2>&1 && echo present || echo missing", timeout: 15, env: nil),
           probe.succeeded, probe.stdout.contains("missing") {
            fail("This bot's sandbox was created before the smolagents runner existed. Open Bot settings › Danger zone › Reset sandbox (\"Reset, keep files\"), then try again.")
            return
        }

        do {
            try await sandbox.writeFile(sandboxID, path: "\(rel)/config.json", contents: configData)
            let launch = "cd /workspace && mkdir -p '\(dir)/rpc' && (nohup \(settings.runnerCommand) run --dir '\(dir)' >'\(dir)/runner.log' 2>&1 &) ; echo started"
            let result = try await sandbox.exec(sandboxID, command: launch, timeout: 20, env: nil)
            guard result.succeeded else {
                await cleanup(rel: rel, dir: dir)
                fail("Could not start the smolagents runner: \(Self.shortError(result)). Is the sandbox image built with the runner?")
                return
            }
        } catch {
            await cleanup(rel: rel, dir: dir)
            fail("Could not start the smolagents runner: \(error.localizedDescription)")
            return
        }

        let outcome = await poll(dir: dir, rel: rel)
        await cleanup(rel: rel, dir: dir)

        switch outcome {
        case .completed: break
        case .aborted, .failed: break
        }
    }

    private func poll(dir: String, rel: String) async -> Finish {
        let started = Date()
        var lastSeq = 0
        var transportFailures = 0
        var finished: Finish?
        var iteration = 0
        var lastProgress = Date()

        while finished == nil {
            if Task.isCancelled {
                await requestCancel(rel: rel)
                onEvent(.status(.aborted("Stopped by user")))
                return .aborted("cancelled")
            }
            if Date().timeIntervalSince(started) - approvalWait > budgets.maxWallSeconds {
                await requestCancel(rel: rel)
                emitAbort("max wall-clock time (\(Int(budgets.maxWallSeconds))s) exceeded")
                onEvent(.status(.aborted("max wall-clock time exceeded")))
                return .aborted("wall clock")
            }

            let cmd = "\(settings.runnerCommand) tail --dir '\(dir)' --after \(lastSeq) --max-bytes \(Self.maxTailBytes)"
            let result: ExecResult
            do {
                result = try await sandbox.exec(sandboxID, command: cmd, timeout: 15, env: nil)
            } catch {
                transportFailures += 1
                if transportFailures > settings.maxConsecutiveTransportFailures {
                    emitAbort("lost contact with the sandbox runner")
                    onEvent(.status(.failed("lost contact with the sandbox runner")))
                    return .failed("transport")
                }
                try? await Task.sleep(nanoseconds: UInt64(settings.pollInterval * 1_000_000_000))
                continue
            }
            if !result.succeeded {
                transportFailures += 1
                if transportFailures > settings.maxConsecutiveTransportFailures {
                    emitAbort("the sandbox runner stopped responding: \(Self.shortError(result))")
                    onEvent(.status(.failed("the sandbox runner stopped responding")))
                    return .failed("runner")
                }
            } else {
                transportFailures = 0
            }

            var done = false
            // The container is untrusted: never even split an absurd output.
            guard result.stdout.utf8.count <= Self.maxTailBytes * 3 else {
                transportFailures += 1
                continue
            }
            for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
                guard line.utf8.count <= Self.maxFieldBytes * 2,
                      let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                if object["tail_done"] as? Bool == true {
                    if object["finished"] as? Bool == true { done = true }
                    continue
                }
                // Strictly increasing and gap-bounded: a hostile `seq` can't swallow later events.
                guard let seq = object["seq"] as? Int, seq > lastSeq, seq <= lastSeq + 10_000 else { continue }
                lastSeq = seq
                lastProgress = Date()
                if let outcome = await handle(event: object, rel: rel, iteration: &iteration) {
                    finished = outcome
                    break
                }
            }
            if finished == nil, done {
                // Runner reported finished without a terminal event we saw.
                finished = .failed("runner exited without a result")
                emitAbort("the sandbox runner ended without producing a result")
            }
            // A runner that died (OOM kill, crash) never emits a terminal status.
            // After a quiet stretch, check its pid; if it is gone, drain once more
            // and give up rather than waiting for the wall clock.
            if finished == nil, Date().timeIntervalSince(lastProgress) > Self.livenessAfter {
                lastProgress = Date()
                if await runnerIsDead(dir: dir) {
                    emitAbort("the sandbox runner exited unexpectedly")
                    onEvent(.status(.failed("runner exited")))
                    return .failed("runner exited")
                }
            }
            if finished == nil {
                try? await Task.sleep(nanoseconds: UInt64(settings.pollInterval * 1_000_000_000))
            }
        }
        return finished ?? .failed("unknown")
    }

    // MARK: events

    /// Returns a `Finish` when the event ends the run.
    private func handle(event: [String: Any], rel: String, iteration: inout Int) async -> Finish? {
        guard let type = event["type"] as? String else { return nil }
        switch type {
        case "status":
            let state = event["state"] as? String ?? ""
            let detail = Self.clip(event["detail"] as? String ?? "", 500)
            switch state {
            case "planning": onEvent(.status(.planning))
            case "executing":
                iteration = (event["step"] as? Int) ?? iteration + 1
                onEvent(.status(.executing(iteration: iteration, maxIterations: budgets.maxIterations)))
            case "waiting_policy": break
            // Terminal statuses end the run even when no `final` preceded them
            // (cancel, step limit, fatal error).
            case "completed": return .completed
            case "aborted":
                onEvent(.status(.aborted(detail.isEmpty ? "aborted" : detail)))
                return .aborted(detail)
            case "failed":
                onEvent(.status(.failed(detail)))
                return .failed(detail)
            default: break
            }
            return nil

        case "message_delta":
            guard let text = event["text"] as? String else { return nil }
            streamBuffer += text
            if streamBuffer.utf8.count > Self.maxFieldBytes { streamBuffer = String(streamBuffer.suffix(1_000)) }
            let lead = String(streamBuffer.drop(while: \.isWhitespace).prefix(40))
            // Hold back while undecided (nothing but whitespace, or still a possible prefix of
            // "Action:" / a code fence / a tool tag), and for good if it is a written-out tool call.
            if lead.isEmpty || Self.startsLikeToolCallText(lead) || Self.couldBecomeToolCallText(lead) { return nil }
            // Decided it is prose: send everything held so far in one piece.
            let pending = String(streamBuffer.dropFirst(streamForwarded))
            streamForwarded = streamBuffer.count
            onEvent(.messageDelta(Self.clip(pending, 8_000)))
            return nil

        case "message":
            let role = (event["role"] as? String) ?? "assistant"
            streamBuffer = ""
            streamForwarded = 0
            let raw = Self.clip(event["content"] as? String ?? "", Self.maxFieldBytes)
            // Some models write their tool call as plain text ("Action: {…}"); that is
            // not something to show as a chat bubble. Keep any prose written before it.
            let content = Self.stripToolCallText(raw)
            guard role == "assistant", !content.isEmpty else { return nil }
            let message = ChatMessage(role: .assistant, content: content)
            messages.append(message)
            lastShownAssistant = content
            onEvent(.message(message))
            return nil

        case "tool_started":
            let name = Self.clip(event["name"] as? String ?? "", 80)
            onEvent(.toolStarted(name: name, argumentsJSON: Self.clip(Self.jsonString(event["args"]), 4_000)))
            return nil

        case "tool_completed":
            let name = Self.clip(event["name"] as? String ?? "", 80)
            let result = Self.clip(Self.jsonString(event["result"]), 20_000)
            let message = ChatMessage(role: .tool, content: result, toolName: name)
            messages.append(message)
            onEvent(.message(message))
            onEvent(.toolCompleted(name: name, resultJSON: result))
            return nil

        case "rpc_request":
            return await handleRPC(event, rel: rel)

        case "final":
            let summary = Self.clip(event["summary"] as? String ?? "", Self.maxFieldBytes)
            let outcome = Self.clip((event["outcome"] as? String) ?? "done", 40)
            guard !summary.isEmpty else {
                emitAbort("the runner finished without a summary")
                return .failed("empty")
            }
            // If the answer was never shown as ordinary text (the model delivered it only
            // through final_answer), show it as the reply; if it repeats what was just
            // shown, keep it as the collapsed recap.
            let alreadyShown = lastShownAssistant.map { $0.contains(summary) || summary.contains($0) } ?? false
            let message = ChatMessage(role: .assistant, content: summary, isTaskSummary: alreadyShown)
            messages.append(ChatMessage(role: .assistant, content: summary))
            onEvent(.message(message))
            onEvent(.status(outcome == "done" ? .completed : .aborted(outcome)))
            return outcome == "done" ? .completed : .aborted(outcome)

        case "error":
            let message = Self.clip(event["message"] as? String ?? "unknown error", 1_000)
            // Non-fatal: a recoverable step problem; the run continues. Shown
            // only in the debug console (system role is hidden from the chat).
            guard event["fatal"] as? Bool == true else {
                onEvent(.message(ChatMessage(role: .system, content: "smolagents note (the run continues): \(message)")))
                return nil
            }
            emitAbort(message)
            onEvent(.status(.failed(message)))
            return .failed(message)

        default:
            return nil
        }
    }

    private func handleRPC(_ event: [String: Any], rel: String) async -> Finish? {
        guard let id = event["id"] as? String, Self.isSafeID(id) else { return nil }
        // From here the runner is waiting on a reply: always give one, even to a malformed request.
        guard let kind = event["kind"] as? String, ["policy_check", "bridge_call"].contains(kind),
              let name = event["name"] as? String, name.count <= 80 else {
            await reply(rel: rel, id: id, ["id": id, "decision": "deny", "reason": "malformed request"])
            return nil
        }
        let rawArgs = (event["args"] as? [String: Any]) ?? [:]
        let call = ToolCall(name: name, arguments: rawArgs.mapValues { AnyCodable($0) })

        // The runner may only ask for tools this bot actually has.
        let known = tools.names().contains(name)
        guard known else {
            await reply(rel: rel, id: id, ["id": id, "decision": "deny", "reason": "unknown tool '\(name)'"])
            return nil
        }
        // Mac-side tools must be bridged; in-container tools must be policy-checked.
        let isBridge = !Self.inSandboxTools.contains(name)
        if isBridge != (kind == "bridge_call") {
            await reply(rel: rel, id: id, ["id": id, "decision": "deny", "reason": "wrong request kind for \(name)"])
            return nil
        }

        let gateStarted = Date()
        let verdict = await gate.evaluate(call)
        if case .run(_, let asked) = verdict, asked { approvalWait += Date().timeIntervalSince(gateStarted) }
        else if case .refuse = verdict { approvalWait += Date().timeIntervalSince(gateStarted) }

        switch verdict {
        case .freeze(let why):
            await reply(rel: rel, id: id, ["id": id, "decision": "deny", "reason": "run frozen by guardrails: \(why)"])
            await requestCancel(rel: rel)
            let error = "guardrails froze this run: \(why)"
            emitAbort(error)
            onEvent(.status(.aborted(error)))
            return .aborted(error)

        case .refuse(let message):
            await reply(rel: rel, id: id, ["id": id, "decision": "deny", "reason": message])
            return nil

        case .held(let note, let stored):
            await reply(rel: rel, id: id, ["id": id, "decision": "deny", "reason": note])
            // Same signal the built-in engine gives, so the app refreshes its review list.
            onEvent(.toolCompleted(name: name, resultJSON: "{\"held_for_review\":\(stored)}"))
            return nil

        case .run(let decision, let askedHuman):
            if askedHuman { onEvent(.status(.executing(iteration: 0, maxIterations: budgets.maxIterations))) }
            if !isBridge {
                if let notice = await gate.anticipateTaint(call, decision: decision) {
                    onEvent(.message(ChatMessage(role: .system, content: notice)))
                }
                await reply(rel: rel, id: id, ["id": id, "decision": "allow"])
                return nil
            }
            var observation = await tools.execute(
                name: name, arguments: call.arguments, sandboxID: sandboxID, sandbox: sandbox, secretStore: secretStore
            )
            observation.removeValue(forKey: "_base64")
            if let notice = await gate.didExecute(call, decision: decision, observation: observation) {
                onEvent(.message(ChatMessage(role: .system, content: notice)))
            }
            await reply(rel: rel, id: id, ["id": id, "decision": "allow", "result": Self.jsonSafe(observation)])
            return nil
        }
    }

    static var livenessAfter: TimeInterval = 20

    /// True only when the pid file exists and that process is gone.
    private func runnerIsDead(dir: String) async -> Bool {
        let check = "p=$(cat '\(dir)/pid' 2>/dev/null); if [ -z \"$p\" ]; then echo unknown; elif kill -0 \"$p\" 2>/dev/null; then echo alive; else echo dead; fi"
        guard let result = try? await sandbox.exec(sandboxID, command: check, timeout: 10, env: nil), result.succeeded else { return false }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "dead"
    }

    // MARK: runner I/O

    private func reply(rel: String, id: String, _ body: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
        let sandbox = self.sandbox, sandboxID = self.sandboxID
        // Detached so a cancelled turn still delivers its last reply / cancel.
        await Task.detached { try? await sandbox.writeFile(sandboxID, path: "\(rel)/rpc/\(id).reply.json", contents: data) }.value
    }

    private func requestCancel(rel: String) async {
        let sandbox = self.sandbox, sandboxID = self.sandboxID
        await Task.detached { try? await sandbox.writeFile(sandboxID, path: "\(rel)/cancel", contents: Data("1".utf8)) }.value
    }

    /// Remove the config (it holds the per-run token) and the rpc files.
    private func cleanup(rel: String, dir: String) async {
        let sandbox = self.sandbox, sandboxID = self.sandboxID
        await Task.detached {
            // The config holds the per-run token, so it always goes. Events and the runner
            // log stay for debugging (a failed run is otherwise a mystery); only the
            // newest few run folders are kept.
            _ = try? await sandbox.exec(
                sandboxID,
                command: "rm -rf '\(dir)/config.json' '\(dir)/rpc' '\(dir)/cancel'; cd /workspace/.shellhouse/runs 2>/dev/null && ls -1t | tail -n +6 | while read d; do rm -rf -- \"$d\"; done",
                timeout: 15, env: nil
            )
        }.value
    }

    private func emitAbort(_ reason: String, silent: Bool = false) {
        if silent { return }
        onEvent(.message(ChatMessage(role: .assistant, content: "(stopped early: \(reason))", isTaskSummary: true)))
    }

    private func fail(_ message: String) {
        onEvent(.message(ChatMessage(role: .assistant, content: "(stopped early: \(message))", isTaskSummary: true)))
        onEvent(.status(.failed(message)))
    }

    // MARK: pure helpers (tested)

    /// The runner's `config.json` (protocol v1).
    static func makeConfig(
        runID: String, baseURL: String, token: String, model: String, systemPrompt: String,
        history: [ChatMessage], task: String, budgets: AgentRuntime.Budgets, planningInterval: Int?,
        tainted: Bool, toolSchemas: [ToolSchema], availableTools: [String]
    ) async -> [String: Any] {
        let bridge = toolSchemas
            .filter { !inSandboxTools.contains($0.name) && $0.name != "finish_task" }
            .map { ["name": $0.name, "description": $0.description, "parameters": $0.parameters] as [String: Any] }
        let enabled = availableTools.filter { inSandboxTools.contains($0) }.sorted()
        let prior = history
            .filter { ($0.role == .user || $0.role == .assistant) && !$0.content.isEmpty }
            .suffix(60)
            .map { ["role": $0.role.rawValue, "content": String($0.content.prefix(8_000))] }
        var config: [String: Any] = [
            "protocol": 1,
            "run_id": runID,
            "model": ["base_url": baseURL, "api_key": token, "model_id": model, "temperature": 0.2] as [String: Any],
            "system_prompt": systemPrompt,
            "history": prior,
            "task": task,
            "max_steps": min(500, max(1, budgets.maxIterations)),
            "tainted": tainted,
            "workspace": "/workspace",
            "policy_free": [String](),
            "bridge_tools": bridge,
            "in_sandbox_tools": enabled,
            "env": [String: String](),
        ]
        // Required by the runner even when unset: JSON null means "no periodic planning".
        config["planning_interval"] = planningInterval.map { $0 as Any } ?? NSNull()
        return config
    }

    /// True while `lead` is still a possible beginning of a written-out tool call, i.e. too short to tell yet.
    static func couldBecomeToolCallText(_ lead: String) -> Bool {
        let l = lead.lowercased()
        guard l.count < 12 else { return false }
        return ["action:", "```", "<tool_call", "<|tool"].contains { $0.hasPrefix(l) && $0 != l }
    }

    /// True when text begins the way a written-out tool call does.
    static func startsLikeToolCallText(_ lead: String) -> Bool {
        let l = lead.lowercased()
        return l.hasPrefix("action:") || l.hasPrefix("{") || l.hasPrefix("```")
            || l.hasPrefix("<tool_call") || l.hasPrefix("<|tool")
    }

    /// Removes a tool call that a model wrote out as text, keeping any prose before it.
    /// `Action:\n{"name": …, "arguments": …}`, a bare JSON call, a fenced block, or a `<tool_call>` tag.
    /// Removes `Calling tools: [...]` blocks: smolagents writes earlier tool calls into the
    /// history in that form and local models copy it into replies. Same rule as the runner's
    /// `strip_echoed_tool_calls`, repeated here because the runner is untrusted.
    static func stripEchoedCallBlocks(_ text: String) -> String {
        let chars = Array(text)
        let marker = Array("Calling tools:")
        var out = ""
        var i = 0
        func matchesMarker(at j: Int) -> Bool {
            j + marker.count <= chars.count && Array(chars[j..<(j + marker.count)]) == marker
        }
        while i < chars.count {
            guard let j = (i..<chars.count).first(where: matchesMarker) else { out += String(chars[i...]); break }
            var k = j + marker.count
            while k < chars.count, chars[k].isWhitespace { k += 1 }
            guard k < chars.count, chars[k] == "[" else { out += String(chars[i..<k]); i = k; continue }
            var depth = 0, quote: Character?, escaped = false, end: Int?
            for p in k..<chars.count {
                let c = chars[p]
                if let q = quote {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == q { quote = nil }
                } else if c == "'" || c == "\"" { quote = c }
                else if c == "[" { depth += 1 }
                else if c == "]" { depth -= 1; if depth == 0 { end = p + 1; break } }
            }
            let before = String(chars[i..<j])
            out += before
            guard var stop = end else { break }  // unbalanced: drop the rest rather than show half a call
            if before.hasSuffix("\n"), stop < chars.count, chars[stop] == "\n" { stop += 1 }
            i = stop
        }
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripToolCallText(_ text: String) -> String {
        let trimmed = stripEchoedCallBlocks(text)
        guard !trimmed.isEmpty else { return "" }

        func isCallJSON(_ s: String) -> Bool {
            let body = s.trimmingCharacters(in: CharacterSet(charactersIn: "` \n\r\t"))
                .replacingOccurrences(of: "^json\\s*", with: "", options: [.regularExpression, .caseInsensitive])
            guard body.hasPrefix("{"), let data = body.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            return obj["name"] != nil && (obj["arguments"] != nil || obj["parameters"] != nil)
        }

        if isCallJSON(trimmed) { return "" }
        if trimmed.lowercased().hasPrefix("<tool_call") { return "" }

        // "<prose>\nAction:\n{…}" → keep the prose when what follows really is a call.
        if let range = trimmed.range(of: "Action:", options: [.caseInsensitive, .backwards]) {
            let tail = String(trimmed[range.upperBound...])
            if isCallJSON(tail) {
                let prose = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                return prose.lowercased().hasPrefix("thought:") && prose.count < 12 ? "" : prose
            }
        }
        if let fence = trimmed.range(of: "```", options: .backwards), trimmed.hasSuffix("```") {
            let open = trimmed[..<fence.lowerBound].range(of: "```", options: .backwards)
            if let open, isCallJSON(String(trimmed[open.upperBound..<fence.lowerBound])) {
                return String(trimmed[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Unchanged text keeps its original form; only an echoed call block is cut.
        return trimmed == text.trimmingCharacters(in: .whitespacesAndNewlines) ? text : trimmed
    }

    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    static func clip(_ s: String, _ limit: Int) -> String { s.utf8.count > limit ? String(s.prefix(limit)) + "…" : s }

    static func shortError(_ r: ExecResult) -> String {
        let text = clip((r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines), 300)
        if text.contains("command not found") {
            return "\(text) — this sandbox has no smolagents runner; reset it from Bot settings › Danger zone"
        }
        return text
    }

    static func jsonString(_ value: Any?) -> String {
        guard let value else { return "{}" }
        if let s = value as? String { return s }
        guard JSONSerialization.isValidJSONObject(value), let d = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    /// Makes an arbitrary observation JSON-encodable.
    static func jsonSafe(_ observation: [String: Any]) -> [String: Any] {
        if JSONSerialization.isValidJSONObject(observation) { return observation }
        return observation.mapValues { value -> Any in
            if JSONSerialization.isValidJSONObject([value]) { return value }
            return String(describing: value)
        }
    }
}
