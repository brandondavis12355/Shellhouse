import XCTest
@testable import AgentCore

/// The smolagents engine against a scripted fake of the in-container runner
/// (protocol v1). No Docker, no model, no network: the fake sandbox plays the
/// runner's side of the file protocol.
final class SmolAgentsEngineTests: XCTestCase {

    // MARK: fake runner

    private final class FakeRunnerSandbox: SandboxProvider, @unchecked Sendable {
        enum Step {
            case events([[String: Any]])
            case awaitReply(String)
            case never
        }
        let name = "fake-runner"
        private let lock = NSLock()
        private var steps: [Step]
        private var cursor = 0
        private var released: [[String: Any]] = []
        private var seq = 0
        private(set) var writes: [String: Data] = [:]
        private(set) var commands: [String] = []
        var failLaunch = false
        var failTail = false
        var runnerMissing = false   // sandbox created from the old image
        var pidState = "alive"   // what the liveness probe reports
        private var terminal = false

        init(_ steps: [Step]) { self.steps = steps }

        func replyDecision(_ id: String) -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            guard let key = writes.keys.first(where: { $0.hasSuffix("rpc/\(id).reply.json") }),
                  let data = writes[key] else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        var configJSON: [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            guard let key = writes.keys.first(where: { $0.hasSuffix("config.json") }), let d = writes[key] else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        var cancelWritten: Bool { lock.lock(); defer { lock.unlock() }; return writes.keys.contains { $0.hasSuffix("/cancel") } }
        var cleaned: Bool { lock.lock(); defer { lock.unlock() }; return commands.contains { $0.contains("rm -rf") && $0.contains("config.json") } }
        var launched: Bool { lock.lock(); defer { lock.unlock() }; return commands.contains { $0.contains(" run --dir") } }

        private func advance() {
            while cursor < steps.count {
                switch steps[cursor] {
                case .events(let list):
                    for var e in list {
                        seq += 1; e["seq"] = seq; e["ts"] = 0
                        released.append(e)
                        if let t = e["type"] as? String, ["final", "error"].contains(t) { terminal = true }
                    }
                    cursor += 1
                case .awaitReply(let id):
                    if writes.keys.contains(where: { $0.hasSuffix("rpc/\(id).reply.json") }) { cursor += 1 } else { return }
                case .never:
                    return
                }
            }
        }

        func exec(_ sandboxID: String, command: String, timeout: TimeInterval, env: [String: String]?) async throws -> ExecResult {
            lock.lock(); defer { lock.unlock() }
            commands.append(command)
            if command.hasPrefix("command -v") { return ExecResult(exitCode: 0, stdout: runnerMissing ? "missing" : "present", stderr: "") }
            if command.contains(" run --dir") {
                return failLaunch ? ExecResult(exitCode: 127, stdout: "", stderr: "python3: No module named shellhouse_agent") : ExecResult(exitCode: 0, stdout: "started", stderr: "")
            }
            if command.contains("kill -0") { return ExecResult(exitCode: 0, stdout: pidState, stderr: "") }
            if command.contains(" tail --dir") {
                if failTail { return ExecResult(exitCode: 1, stdout: "", stderr: "boom") }
                advance()
                var after = 0
                if let r = command.range(of: "--after "), let n = Int(command[r.upperBound...].prefix { $0.isNumber }) { after = n }
                var out = ""
                for e in released where (e["seq"] as! Int) > after {
                    out += String(data: try JSONSerialization.data(withJSONObject: e), encoding: .utf8)! + "\n"
                }
                out += "{\"tail_done\":true,\"last_seq\":\(seq),\"finished\":\(terminal && cursor >= steps.count)}\n"
                return ExecResult(exitCode: 0, stdout: out, stderr: "")
            }
            return ExecResult(exitCode: 0, stdout: "", stderr: "")
        }
        func writeFile(_ sandboxID: String, path: String, contents: Data) async throws { lock.lock(); writes[path] = contents; lock.unlock() }
        func create(taskID: String, persistent: Bool) async throws -> SandboxHandle { SandboxHandle(id: taskID, provider: name, persistent: persistent) }
        func start(_ sandboxID: String) async throws -> SandboxHandle { SandboxHandle(id: sandboxID, provider: name, persistent: true) }
        func readFile(_ sandboxID: String, path: String, maxBytes: Int) async throws -> Data { Data() }
        func pause(_ sandboxID: String) async throws {}
        func resume(_ sandboxID: String) async throws {}
        func destroy(_ sandboxID: String) async throws {}
        func health(_ sandboxID: String) async -> Bool { true }
        func reconcile() async throws -> [SandboxHandle] { [] }
        func listSandboxes() async throws -> [SandboxHandle] { [] }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [String] = []
        private(set) var approvals: [Approval] = []
        func add(_ e: String) { lock.lock(); events.append(e); lock.unlock() }
        func approval(_ a: Approval) { lock.lock(); approvals.append(a); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func ev(_ type: String, _ fields: [String: Any] = [:]) -> [String: Any] { fields.merging(["type": type]) { a, _ in a } }
    private func final(_ text: String = "all done") -> [String: Any] { ev("final", ["summary": text, "outcome": "done"]) }

    private func engine(
        _ sandbox: FakeRunnerSandbox, rec: Recorder, answer: AgentRuntime.ApprovalDecision = .deny,
        tools: ToolRegistry = ToolRegistry(), taint: [TaintSource] = [], proxy: ModelProxy = ModelProxy(),
        budgets: AgentRuntime.Budgets = AgentRuntime.Budgets(), model: String? = "qwen-test"
    ) -> SmolAgentsEngine {
        SmolAgentsEngine(
            proxy: proxy,
            settings: .init(containerBaseURL: "http://172.17.0.1:18434/v1", pollInterval: 0.01),
            sandbox: sandbox, sandboxID: "eng-bot", tools: tools, budgets: budgets, modelName: model,
            onEvent: { event in
                switch event {
                case .status(let s): rec.add("status:\(s)")
                case .message(let m):
                    rec.add("msg:\(m.role.rawValue):\(m.content)")
                    if m.isTaskSummary { rec.add("summary:\(m.content)") }
                case .messageDelta(let d): rec.add("delta:\(d)")
                case .toolStarted(let n, _): rec.add("tool_started:\(n)")
                case .toolCompleted(let n, _): rec.add("tool_completed:\(n)")
                default: break
                }
            },
            requestApproval: { a in rec.approval(a); return answer },
            initialTaint: taint
        )
    }

    // MARK: tests

    func testHappyPathTranslatesEventsAndCleansUp() async {
        let sandbox = FakeRunnerSandbox([.events([
            ev("status", ["state": "planning"]),
            ev("message_delta", ["text": "Hel"]),
            ev("message", ["role": "assistant", "content": "Hello"]),
            ev("tool_started", ["name": "list_files", "args": ["path": "."]]),
            ev("tool_completed", ["name": "list_files", "result": ["entries": ["a"]]]),
            final("The answer"),
        ])])
        let rec = Recorder(); let proxy = ModelProxy()
        let e = engine(sandbox, rec: rec, proxy: proxy)
        await e.seed(systemPrompt: "SYS", history: [ChatMessage(role: .user, content: "earlier"), ChatMessage(role: .assistant, content: "ok")])
        await e.send("do it", images: [])

        let log = rec.all
        XCTAssertTrue(log.contains("delta:Hel"))
        XCTAssertTrue(log.contains("msg:assistant:Hello"))
        XCTAssertTrue(log.contains("tool_started:list_files"))
        XCTAssertTrue(log.contains("tool_completed:list_files"))
        XCTAssertTrue(log.contains("msg:assistant:The answer"))
        XCTAssertTrue(log.contains("status:completed"))
        let transcript = await e.transcript()
        XCTAssertEqual(transcript.last?.content, "The answer")
        XCTAssertTrue(sandbox.launched)
        XCTAssertTrue(sandbox.cleaned, "config (which holds the run token) must be removed")

        let config = sandbox.configJSON
        XCTAssertEqual(config?["protocol"] as? Int, 1)
        XCTAssertEqual(config?["task"] as? String, "do it")
        XCTAssertEqual(config?["system_prompt"] as? String, "SYS")
        let model = config?["model"] as? [String: Any]
        XCTAssertEqual(model?["model_id"] as? String, "qwen-test")
        XCTAssertEqual(model?["base_url"] as? String, "http://172.17.0.1:18434/v1")
        let token = model?["api_key"] as? String ?? ""
        XCTAssertGreaterThan(token.count, 20)
        XCTAssertNil(proxy.usage(for: token), "token must be revoked when the turn ends")
        XCTAssertEqual((config?["history"] as? [[String: Any]])?.count, 2)
    }

    func testPolicyCheckDeniesCredentialReadWithoutAskingAnyone() async {
        let sandbox = FakeRunnerSandbox([
            .events([ev("rpc_request", ["id": "r1", "kind": "policy_check", "name": "run_shell", "args": ["command": "cat ~/.ssh/id_rsa"]])]),
            .awaitReply("r1"),
            .events([final()]),
        ])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec, answer: .approve)
        await e.send("go", images: [])
        let reply = sandbox.replyDecision("r1")
        XCTAssertEqual(reply?["decision"] as? String, "deny")
        XCTAssertTrue((reply?["reason"] as? String ?? "").contains("blocked by guardrails"))
        XCTAssertTrue(rec.approvals.isEmpty)
    }

    func testPolicyCheckAsksThenAllowsWhenApproved() async {
        let sandbox = FakeRunnerSandbox([
            .events([ev("rpc_request", ["id": "r1", "kind": "policy_check", "name": "run_shell", "args": ["command": "make build"]])]),
            .awaitReply("r1"),
            .events([final()]),
        ])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec, answer: .approve)
        await e.send("go", images: [])
        XCTAssertEqual(rec.approvals.count, 1)
        XCTAssertEqual(sandbox.replyDecision("r1")?["decision"] as? String, "allow")
    }

    func testStrictActionIsDeniedWhenTheUserSaysNo() async {
        let sandbox = FakeRunnerSandbox([
            .events([ev("rpc_request", ["id": "r1", "kind": "policy_check", "name": "run_shell", "args": ["command": "rm -rf build"]])]),
            .awaitReply("r1"),
            .events([final()]),
        ])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec, answer: .deny)
        await e.send("go", images: [])
        XCTAssertEqual(rec.approvals.first?.strict, true)
        XCTAssertEqual(sandbox.replyDecision("r1")?["decision"] as? String, "deny")
    }

    func testBridgeToolRunsOnTheMacAndReturnsItsResult() async {
        let remembered = Counter()
        let tools = ToolRegistry(onRemember: { _ in remembered.bump(); return true })
        let sandbox = FakeRunnerSandbox([
            .events([ev("rpc_request", ["id": "b1", "kind": "bridge_call", "name": "remember", "args": ["text": "likes tea"]])]),
            .awaitReply("b1"),
            .events([final()]),
        ])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec, tools: tools)
        await e.send("go", images: [])
        XCTAssertEqual(remembered.value, 1)
        let reply = sandbox.replyDecision("b1")
        XCTAssertEqual(reply?["decision"] as? String, "allow")
        XCTAssertNotNil(reply?["result"])
    }

    func testBridgeMemoryWriteIsHeldWhenTheRunIsTainted() async {
        let remembered = Counter()
        let tools = ToolRegistry(onRemember: { _ in remembered.bump(); return true })
        let sandbox = FakeRunnerSandbox([
            .events([ev("rpc_request", ["id": "b1", "kind": "bridge_call", "name": "remember", "args": ["text": "evil"]])]),
            .awaitReply("b1"),
            .events([final()]),
        ])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec, tools: tools, taint: [.web])
        await e.send("go", images: [])
        XCTAssertEqual(remembered.value, 0)
        XCTAssertEqual(sandbox.replyDecision("b1")?["decision"] as? String, "deny")
    }

    func testRunnerCannotUseTheWrongRequestKindOrUnknownTools() async {
        let tools = ToolRegistry(onRemember: { _ in true })
        let sandbox = FakeRunnerSandbox([
            .events([
                ev("rpc_request", ["id": "w1", "kind": "bridge_call", "name": "run_shell", "args": ["command": "ls"]]),
                ev("rpc_request", ["id": "w2", "kind": "policy_check", "name": "remember", "args": ["text": "x"]]),
                ev("rpc_request", ["id": "w3", "kind": "policy_check", "name": "format_disk", "args": [:]]),
            ]),
            .awaitReply("w1"), .awaitReply("w2"), .awaitReply("w3"),
            .events([final()]),
        ])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec, answer: .approve, tools: tools)
        await e.send("go", images: [])
        for id in ["w1", "w2", "w3"] {
            XCTAssertEqual(sandbox.replyDecision(id)?["decision"] as? String, "deny", id)
        }
    }

    func testUnsafeRequestIdsAreIgnoredNotUsedAsPaths() async {
        let sandbox = FakeRunnerSandbox([
            .events([ev("rpc_request", ["id": "../../etc/x", "kind": "policy_check", "name": "list_files", "args": [:]]), final()]),
        ])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec, answer: .approve)
        await e.send("go", images: [])
        XCTAssertFalse(sandbox.writes.keys.contains { $0.contains("..") }, "no file may be written from a runner-supplied path")
    }

    func testDecoyCredentialFreezesTheRunAndCancelsTheRunner() async {
        let sandbox = FakeRunnerSandbox([
            .events([ev("rpc_request", ["id": "t1", "kind": "policy_check", "name": "read_file", "args": ["path": "/workspace/.env.production"]])]),
            .never,
        ])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec, answer: .approve)
        await e.send("go", images: [])
        XCTAssertEqual(sandbox.replyDecision("t1")?["decision"] as? String, "deny")
        XCTAssertTrue(sandbox.cancelWritten)
        XCTAssertTrue(rec.all.contains { $0.hasPrefix("status:aborted") && $0.contains("froze") })
    }

    func testCancellingTheTurnTellsTheRunnerToStopAndRevokesTheToken() async throws {
        let sandbox = FakeRunnerSandbox([.events([ev("status", ["state": "executing", "step": 1])]), .never])
        let rec = Recorder(); let proxy = ModelProxy()
        let e = engine(sandbox, rec: rec, proxy: proxy)
        let task = Task { await e.send("long job", images: []) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = await task.value
        XCTAssertTrue(sandbox.cancelWritten)
        XCTAssertTrue(sandbox.cleaned)
        let token = (sandbox.configJSON?["model"] as? [String: Any])?["api_key"] as? String ?? ""
        XCTAssertNil(proxy.usage(for: token))
    }

    func testWallClockBudgetStopsARunawayRunner() async {
        let sandbox = FakeRunnerSandbox([.never])
        let rec = Recorder()
        var budgets = AgentRuntime.Budgets(); budgets.maxWallSeconds = 0.3
        let e = engine(sandbox, rec: rec, budgets: budgets)
        await e.send("go", images: [])
        XCTAssertTrue(sandbox.cancelWritten)
        XCTAssertTrue(rec.all.contains { $0.contains("wall-clock") })
    }

    func testRunnerThatCannotStartReportsAClearFailure() async {
        let sandbox = FakeRunnerSandbox([.never]); sandbox.failLaunch = true
        let rec = Recorder()
        let e = engine(sandbox, rec: rec)
        await e.send("go", images: [])
        XCTAssertTrue(rec.all.contains { $0.contains("Could not start the smolagents runner") })
        XCTAssertTrue(rec.all.contains { $0.hasPrefix("status:failed") })
    }

    func testLosingTheRunnerForTooLongFailsInsteadOfHanging() async {
        let sandbox = FakeRunnerSandbox([.never]); sandbox.failTail = true
        let rec = Recorder()
        let e = SmolAgentsEngine(
            proxy: ModelProxy(), settings: .init(containerBaseURL: "http://x/v1", pollInterval: 0.001, maxConsecutiveTransportFailures: 5),
            sandbox: sandbox, sandboxID: "eng-bot", tools: ToolRegistry(), modelName: "m",
            onEvent: { event in if case .message(let m) = event { rec.add(m.content) } }
        )
        await e.send("go", images: [])
        XCTAssertTrue(rec.all.contains { $0.contains("stopped responding") })
    }

    func testNoModelSelectedFailsFast() async {
        let sandbox = FakeRunnerSandbox([.never])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec, model: nil)
        await e.send("go", images: [])
        XCTAssertFalse(sandbox.launched)
        XCTAssertTrue(rec.all.contains { $0.contains("No model") })
    }

    func testOversizedRunnerOutputIsClipped() async {
        let big = String(repeating: "x", count: 600_000)
        let sandbox = FakeRunnerSandbox([.events([ev("message", ["role": "assistant", "content": big]), final()])])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec)
        await e.send("go", images: [])
        let longest = rec.all.map(\.count).max() ?? 0
        XCTAssertLessThan(longest, 270_000)
    }

    func testConfigSeparatesBridgeToolsFromInSandboxTools() async {
        let tools = ToolRegistry(onRemember: { _ in true })
        let config = await SmolAgentsEngine.makeConfig(
            runID: "run-1", baseURL: "http://x/v1", token: "tok", model: "m", systemPrompt: "s",
            history: [ChatMessage(role: .user, content: "u"), ChatMessage(role: .tool, content: "t"), ChatMessage(role: .system, content: "sys"), ChatMessage(role: .assistant, content: "")],
            task: "t", budgets: AgentRuntime.Budgets(), planningInterval: 3, tainted: true,
            toolSchemas: tools.schemas, availableTools: Array(tools.names())
        )
        let bridge = (config["bridge_tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(bridge.contains("remember"))
        XCTAssertFalse(bridge.contains("run_shell"))
        XCTAssertFalse(bridge.contains("finish_task"))
        let local = config["in_sandbox_tools"] as? [String] ?? []
        XCTAssertTrue(local.contains("run_shell"))
        XCTAssertFalse(local.contains("remember"))
        XCTAssertEqual((config["history"] as? [[String: Any]])?.count, 1, "only non-empty user/assistant turns are replayed")
        XCTAssertEqual(config["planning_interval"] as? Int, 3)
        XCTAssertEqual(config["tainted"] as? Bool, true)
        XCTAssertEqual((config["env"] as? [String: String])?.isEmpty, true, "no environment is forwarded into the container")
    }

    // MARK: protocol v1 details

    func testNonFatalRunnerErrorsDoNotEndTheRun() async {
        let sandbox = FakeRunnerSandbox([.events([
            ev("error", ["message": "model replied without a tool call", "fatal": false]),
            ev("message", ["role": "assistant", "content": "still going"]),
            final("recovered"),
        ])])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec)
        await e.send("go", images: [])
        XCTAssertTrue(rec.all.contains("msg:assistant:recovered"))
        XCTAssertTrue(rec.all.contains("status:completed"))
        XCTAssertFalse(rec.all.contains { $0.contains("stopped early") })
    }

    func testFatalRunnerErrorEndsTheRunWithAMessage() async {
        let sandbox = FakeRunnerSandbox([.events([ev("error", ["message": "model unreachable", "fatal": true]), ev("status", ["state": "failed", "detail": "model unreachable"])])])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec)
        await e.send("go", images: [])
        XCTAssertTrue(rec.all.contains { $0.contains("stopped early") && $0.contains("model unreachable") })
        XCTAssertTrue(rec.all.contains { $0.hasPrefix("status:failed") })
    }

    func testTerminalAbortedStatusWithoutFinalEndsTheRun() async {
        let sandbox = FakeRunnerSandbox([.events([ev("status", ["state": "aborted", "detail": "cancelled"])])])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec)
        await e.send("go", images: [])
        XCTAssertTrue(rec.all.contains { $0.hasPrefix("status:aborted") })
    }

    func testStepLimitOutcomeIsReportedAsBlocked() async {
        let sandbox = FakeRunnerSandbox([.events([ev("final", ["summary": "ran out of steps", "outcome": "blocked", "reason": "max_steps"]), ev("status", ["state": "aborted", "detail": "max_steps"])])])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec)
        await e.send("go", images: [])
        XCTAssertTrue(rec.all.contains("msg:assistant:ran out of steps"))
        XCTAssertTrue(rec.all.contains { $0.hasPrefix("status:aborted") })
    }

    func testDeadRunnerIsDetectedWithoutWaitingForTheWallClock() async {
        let sandbox = FakeRunnerSandbox([.events([ev("status", ["state": "executing"])]), .never]); sandbox.pidState = "dead"
        let rec = Recorder()
        SmolAgentsEngine.livenessAfter = 0.05
        defer { SmolAgentsEngine.livenessAfter = 20 }
        let e = engine(sandbox, rec: rec)
        await e.send("go", images: [])
        XCTAssertTrue(rec.all.contains { $0.contains("exited unexpectedly") })
    }

    func testAliveRunnerIsNotMistakenForDead() async {
        let sandbox = FakeRunnerSandbox([.events([ev("status", ["state": "executing"])]), .never])
        let rec = Recorder()
        SmolAgentsEngine.livenessAfter = 0.05
        defer { SmolAgentsEngine.livenessAfter = 20 }
        var budgets = AgentRuntime.Budgets(); budgets.maxWallSeconds = 0.4
        let e = engine(sandbox, rec: rec, budgets: budgets)
        await e.send("go", images: [])
        XCTAssertFalse(rec.all.contains { $0.contains("exited unexpectedly") })
        XCTAssertTrue(rec.all.contains { $0.contains("wall-clock") })
    }

    func testMaxStepsIsClampedToTheRunnersLimit() async {
        var budgets = AgentRuntime.Budgets(); budgets.maxIterations = 5_000
        let config = await SmolAgentsEngine.makeConfig(
            runID: "r", baseURL: "http://x/v1", token: "t", model: "m", systemPrompt: "s", history: [], task: "t",
            budgets: budgets, planningInterval: nil, tainted: false, toolSchemas: [], availableTools: []
        )
        XCTAssertEqual(config["max_steps"] as? Int, 500)
        XCTAssertTrue(config["planning_interval"] is NSNull, "the key must be present (null) because the runner requires it")
    }

    func testOldSandboxWithoutTheRunnerGetsAClearInstruction() async {
        let sandbox = FakeRunnerSandbox([.never]); sandbox.runnerMissing = true
        let rec = Recorder(); let proxy = ModelProxy()
        let e = engine(sandbox, rec: rec, proxy: proxy)
        await e.send("go", images: [])
        XCTAssertFalse(sandbox.launched, "must not try to start a runner that isn't there")
        XCTAssertTrue(rec.all.contains { $0.contains("Reset sandbox") })
        XCTAssertTrue(rec.all.contains { $0.hasPrefix("status:failed") })
        XCTAssertFalse(sandbox.writes.keys.contains { $0.hasSuffix("config.json") }, "no config (and so no run token) may be written to a sandbox that can't run it")
    }

    /// The app's config and the runner's validator share one contract file.
    func testConfigMatchesTheSharedContractWithTheRunner() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()   // …/shellhouse
        let contractURL = repoRoot.appendingPathComponent("sandbox/agent-runner/config-contract.json")
        let contract = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: contractURL)) as? [String: Any])
        let required = Set(contract["required"] as? [String] ?? [])
        let optional = Set(contract["optional"] as? [String] ?? [])
        let modelKeys = Set(contract["model_keys"] as? [String] ?? [])
        XCTAssertFalse(required.isEmpty)

        let tools = ToolRegistry(onRemember: { _ in true })
        for planning in [nil, 4] as [Int?] {
            let config = await SmolAgentsEngine.makeConfig(
                runID: "run-1", baseURL: "http://x/v1", token: "t", model: "m", systemPrompt: "s",
                history: [ChatMessage(role: .user, content: "u")], task: "t", budgets: AgentRuntime.Budgets(),
                planningInterval: planning, tainted: false, toolSchemas: tools.schemas, availableTools: Array(tools.names())
            )
            let keys = Set(config.keys)
            XCTAssertEqual(required.subtracting(keys), [], "the runner requires keys the app does not send")
            XCTAssertEqual(keys.subtracting(required).subtracting(optional), [], "the app sends keys the runner rejects")
            XCTAssertEqual(Set((config["model"] as? [String: Any])?.keys.map { $0 } ?? []), modelKeys)
            // Optional dump so the runner's own validator can be run against a real app-generated config.
            if let path = ProcessInfo.processInfo.environment["SHELLHOUSE_DUMP_CONFIG"], planning == nil {
                try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path))
            }
        }
    }

    /// Every tool the real app registers must survive the runner's validation (names, parameter schemas).
    func testFullToolRegistryProducesAConfigTheRunnerCanParse() async throws {
        let ok: @Sendable ([String: AnyCodable]) async -> [String: Any] = { _ in ["ok": true] }
        let tools = ToolRegistry(
            skills: [Skill(id: "demo-skill", name: "Demo", description: "d", content: "c")],
            onRemember: { _ in true }, onRecallMemory: { _ in [] }, onRememberTask: ok, onCompleteTask: ok,
            onListTasks: { [] }, onCreateRoutine: ok, onEditRoutine: ok, onRemoveRoutine: ok, onListRoutines: { [] },
            onGetProfile: { [:] }, onListBots: { [] }, onMessageBot: { _, _ in [:] }, onCreateBot: { _, _, _ in [:] },
            onAddBotToGroup: { _, _ in [:] }, onPostToGroup: { _, _ in [:] }, onUpdateUser: { _ in [:] },
            onGoalTool: { _, _ in [:] }
        )
        let config = await SmolAgentsEngine.makeConfig(
            runID: "run-full", baseURL: "http://x/v1", token: "t", model: "m", systemPrompt: "s", history: [],
            task: "t", budgets: AgentRuntime.Budgets(), planningInterval: nil, tainted: false,
            toolSchemas: tools.schemas, availableTools: Array(tools.names())
        )
        let bridge = (config["bridge_tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertGreaterThan(bridge.count, 12, "expected the full set of Mac-side tools: \(bridge)")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(config))
        if let path = ProcessInfo.processInfo.environment["SHELLHOUSE_DUMP_CONFIG_FULL"] {
            try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: text-written tool calls

    func testToolCallWrittenAsTextIsNeverShownButItsAnswerIs() async {
        let call = "Action:\n{\"name\": \"final_answer\", \"arguments\": {\"answer\": \"Hello! I'm Mr. Smith.\"}}"
        let sandbox = FakeRunnerSandbox([.events([
            ev("message_delta", ["text": "Act"]), ev("message_delta", ["text": "ion:\n{\"name\": \"final"]),
            ev("message", ["role": "assistant", "content": call]),
            ev("final", ["summary": "Hello! I'm Mr. Smith.", "outcome": "done"]),
        ])])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec)
        await e.send("hi", images: [])
        XCTAssertFalse(rec.all.contains { $0.contains("Action:") || $0.hasPrefix("delta:") }, "raw tool-call text must not reach the chat: \(rec.all)")
        XCTAssertTrue(rec.all.contains("msg:assistant:Hello! I'm Mr. Smith."), "the answer itself must be visible")
        XCTAssertFalse(rec.all.contains { $0.hasPrefix("summary:") }, "not collapsed into the 'Done' row when it was never shown")
    }

    func testProseBeforeAWrittenToolCallIsKept() async {
        let text = "Let me check that for you.\nAction:\n{\"name\": \"list_files\", \"arguments\": {\"path\": \".\"}}"
        let sandbox = FakeRunnerSandbox([.events([ev("message", ["role": "assistant", "content": text]), final("done here")])])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec)
        await e.send("go", images: [])
        XCTAssertTrue(rec.all.contains("msg:assistant:Let me check that for you."))
        XCTAssertFalse(rec.all.contains { $0.contains("list_files") })
    }

    func testAnswerThatRepeatsTheShownReplyStaysACollapsedRecap() async {
        let sandbox = FakeRunnerSandbox([.events([ev("message", ["role": "assistant", "content": "The sky is blue."]), ev("final", ["summary": "The sky is blue.", "outcome": "done"])])])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec)
        await e.send("go", images: [])
        XCTAssertEqual(rec.all.filter { $0 == "msg:assistant:The sky is blue." }.count, 2)
        XCTAssertTrue(rec.all.contains("summary:The sky is blue."))
    }

    func testToolCallTextDetection() {
        XCTAssertEqual(SmolAgentsEngine.stripToolCallText("{\"name\":\"x\",\"arguments\":{}}"), "")
        XCTAssertEqual(SmolAgentsEngine.stripToolCallText("```json\n{\"name\":\"x\",\"arguments\":{}}\n```"), "")
        XCTAssertEqual(SmolAgentsEngine.stripToolCallText("<tool_call>{\"name\":\"x\"}</tool_call>"), "")
        XCTAssertEqual(SmolAgentsEngine.stripToolCallText("Plain answer."), "Plain answer.")
        // Real replies that merely mention JSON or the word Action are left alone.
        XCTAssertEqual(SmolAgentsEngine.stripToolCallText("Action: we should review the plan."), "Action: we should review the plan.")
        XCTAssertEqual(SmolAgentsEngine.stripToolCallText("Use {\"a\": 1} as the payload."), "Use {\"a\": 1} as the payload.")
        XCTAssertTrue(SmolAgentsEngine.startsLikeToolCallText("Action:\n{"))
        XCTAssertFalse(SmolAgentsEngine.startsLikeToolCallText("Hello there"))
    }

    func testProseThatStartsLikeAToolWordStillStreams() async {
        let sandbox = FakeRunnerSandbox([.events([
            ev("message_delta", ["text": "Act"]), ev("message_delta", ["text": "ually, here is the plan."]),
            ev("message", ["role": "assistant", "content": "Actually, here is the plan."]), final("ok"),
        ])])
        let rec = Recorder()
        let e = engine(sandbox, rec: rec)
        await e.send("go", images: [])
        XCTAssertEqual(rec.all.first { $0.hasPrefix("delta:") }, "delta:Actually, here is the plan.", "the held 'Act' is sent together with the rest once it is clear it is prose")
    }
}
