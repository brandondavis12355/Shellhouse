import XCTest
@testable import AgentCore

final class LoopPlanTests: XCTestCase {
    final class SlowBoxShared: SandboxProvider, @unchecked Sendable {
        let name = "shared"
        func exec(_ sandboxID: String, command: String, timeout: TimeInterval, env: [String: String]?) async throws -> ExecResult { ExecResult(exitCode: 0, stdout: "", stderr: "") }
        func create(taskID: String, persistent: Bool) async throws -> SandboxHandle { SandboxHandle(id: taskID, provider: name, persistent: persistent) }
        func start(_ sandboxID: String) async throws -> SandboxHandle { SandboxHandle(id: sandboxID, provider: name, persistent: true) }
        func readFile(_ sandboxID: String, path: String, maxBytes: Int) async throws -> Data { Data() }
        func writeFile(_ sandboxID: String, path: String, contents: Data) async throws {}
        func pause(_ sandboxID: String) async throws {}
        func resume(_ sandboxID: String) async throws {}
        func destroy(_ sandboxID: String) async throws {}
        func health(_ sandboxID: String) async -> Bool { true }
        func reconcile() async throws -> [SandboxHandle] { [] }
        func listSandboxes() async throws -> [SandboxHandle] { [] }
    }

    private final class SlowBox: SandboxProvider, @unchecked Sendable {
        let name = "slow"
        func exec(_ sandboxID: String, command: String, timeout: TimeInterval, env: [String: String]?) async throws -> ExecResult {
            ExecResult(exitCode: 0, stdout: "ok", stderr: "")
        }
        func create(taskID: String, persistent: Bool) async throws -> SandboxHandle { SandboxHandle(id: taskID, provider: name, persistent: persistent) }
        func start(_ sandboxID: String) async throws -> SandboxHandle { SandboxHandle(id: sandboxID, provider: name, persistent: true) }
        func readFile(_ sandboxID: String, path: String, maxBytes: Int) async throws -> Data {
            try await Task.sleep(nanoseconds: 300_000_000)
            return Data("contents of \(path)\n".utf8)
        }
        func writeFile(_ sandboxID: String, path: String, contents: Data) async throws {}
        func pause(_ sandboxID: String) async throws {}
        func resume(_ sandboxID: String) async throws {}
        func destroy(_ sandboxID: String) async throws {}
        func health(_ sandboxID: String) async -> Bool { true }
        func reconcile() async throws -> [SandboxHandle] { [] }
        func listSandboxes() async throws -> [SandboxHandle] { [] }
    }

    private final class Script: ModelBackend, @unchecked Sendable {
        let name = "script"
        private let lock = NSLock()
        private var replies: [ModelReply]
        private(set) var calls = 0
        init(_ replies: [[ToolCall]]) {
            self.replies = replies.map { ModelReply(message: ChatMessage(role: .assistant, content: "", toolCalls: $0), usage: nil) }
        }
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return replies.isEmpty ? ModelReply(message: ChatMessage(role: .assistant, content: "", toolCalls: [finish]), usage: nil) : replies.removeFirst()
        }
    }
    private static let finish = ToolCall(name: "finish_task", arguments: ["summary": AnyCodable("done"), "outcome": AnyCodable("done")])

    private func read(_ path: String) -> ToolCall { ToolCall(name: "read_file", arguments: ["path": AnyCodable(path)]) }

    func testReadsInOneReplyOverlapTheirWaits() async {
        let model = Script([[read("a.txt"), read("b.txt"), read("c.txt")], [Self.finish]])
        let runtime = AgentRuntime(model: model, sandbox: SlowBox(), sandboxID: "t", budgets: AgentRuntime.Budgets(maxIterations: 10), requestApproval: { _ in .approve })
        let started = Date()
        await runtime.start(systemPrompt: "system", goal: "read three files")
        let elapsed = Date().timeIntervalSince(started)
        let results = await runtime.transcript().filter { $0.role == .tool }
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results[0].content.contains("a.txt") && results[2].content.contains("c.txt"), "results stay in call order")
        XCTAssertLessThan(elapsed, 0.8, "three 0.3 s reads should overlap, took \(elapsed)")
    }

    func testDoneAfterAnUncheckedCodeChangeIsBouncedOnce() async {
        let write = ToolCall(name: "write_file", arguments: ["path": AnyCodable("app.py"), "content": AnyCodable("print(1)\n")])
        let model = Script([[write], [Self.finish], [Self.finish]])
        let runtime = AgentRuntime(model: model, sandbox: SlowBox(), sandboxID: "t", budgets: AgentRuntime.Budgets(maxIterations: 10), requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "system", goal: "write app")
        let bounced = await runtime.transcript().filter { $0.role == .tool && $0.content.contains("ran nothing afterwards") }
        XCTAssertEqual(bounced.count, 1)
        XCTAssertEqual(model.calls, 3, "write, bounced finish, accepted finish")
    }

    func testDoneAfterRunningACheckIsNotBounced() async {
        let write = ToolCall(name: "write_file", arguments: ["path": AnyCodable("app.py"), "content": AnyCodable("print(1)\n")])
        let check = ToolCall(name: "run_shell", arguments: ["command": AnyCodable("python3 app.py")])
        let model = Script([[write], [check], [Self.finish]])
        let runtime = AgentRuntime(model: model, sandbox: SlowBox(), sandboxID: "t", budgets: AgentRuntime.Budgets(maxIterations: 10), requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "system", goal: "write app")
        let bounced = await runtime.transcript().filter { $0.content.contains("ran nothing afterwards") }
        XCTAssertTrue(bounced.isEmpty)
    }

    func testLookingAtOneFileDifferentWaysIsTheSameCall() {
        func key(_ command: String) -> String { AgentRuntime.repeatFingerprint(for: ToolCall(name: "run_shell", arguments: ["command": AnyCodable(command)])) }
        XCTAssertEqual(key("cat game.py"), key("head -20 game.py"))
        XCTAssertEqual(key("tail -n 50 game.py"), key("cat game.py"))
        XCTAssertNotEqual(key("cat game.py"), key("cat other.py"))
    }

    func testTimeoutAndSyntaxFeedback() {
        let hinted = ObservationPolicy.annotate(tool: "run_shell", observation: ["exit_code": 124, "stdout": "", "stderr": ""])
        XCTAssertTrue((hinted["hint"] as? String ?? "").contains("background: true"))
        let excerpt = WorkspaceTools.excerpt(of: "a = 1\nb = (\nc = 3\nd = 4\n", near: "SyntaxError: '(' was never closed (x.py, line 2)")
        XCTAssertTrue(excerpt.contains("2: b = ("), excerpt)
        XCTAssertEqual(WorkspaceTools.excerpt(of: "x", near: "no line info"), "")
    }

    func testFirstNarrationNudgeCarriesTheScreenshotRoute() {
        XCTAssertTrue(AgentRuntime.screenshotRoute(for: "Let me take a screenshot of the site.").contains("--screenshot="))
        XCTAssertEqual(AgentRuntime.screenshotRoute(for: "Let me read the file."), "")
    }
}

/// Replays a scripted run and reports loop corrections, so a change to the loop shows up as a number.
final class LoopReplayTests: XCTestCase {
    private final class Narrator: ModelBackend, @unchecked Sendable {
        let name = "narrator"
        private let lock = NSLock()
        private(set) var calls = 0
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            if calls <= 2 { return ModelReply(message: ChatMessage(role: .assistant, content: "Let me take a screenshot of the site now."), usage: nil) }
            return ModelReply(message: ChatMessage(role: .assistant, content: "", toolCalls: [
                ToolCall(name: "finish_task", arguments: ["summary": AnyCodable("done"), "outcome": AnyCodable("done")])]), usage: nil)
        }
    }

    func testNarrationRunCountsItsCorrectionsAndStillFinishes() async {
        let before = Telemetry.recorder.loopEventCounts()
        let model = Narrator()
        let runtime = AgentRuntime(model: model, sandbox: LoopPlanTests.SlowBoxShared(), sandboxID: "t", budgets: AgentRuntime.Budgets(maxIterations: 10), requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "system", goal: "send a screenshot")
        let after = Telemetry.recorder.loopEventCounts()
        XCTAssertEqual((after["narration"] ?? 0) - (before["narration"] ?? 0), 1)
        XCTAssertEqual((after["narration_escalated"] ?? 0) - (before["narration_escalated"] ?? 0), 1)
        XCTAssertLessThanOrEqual(model.calls, 3, "two misses and then the finish: no wasted steps")
    }
}

final class GroupLoopPlanTests: XCTestCase {
    func testQuickRepliesThatPromiseWorkAreDetected() {
        XCTAssertTrue(ReplyQuality.promisesWork("Sure, I'll send the screenshot now."))
        XCTAssertTrue(ReplyQuality.promisesWork("Let me check that for you."))
        XCTAssertFalse(ReplyQuality.promisesWork("Hello! I help with testing and reviews."))
    }

    func testNobodyValidatesTheirOwnStep() {
        var goal = GroupGoal(title: "t", ownerBotID: "o", steps: [
            GroupGoal.Step(text: "build it", assigneeName: "Tester"), GroupGoal.Step(text: "other", assigneeName: "Coder"),
        ])
        goal.validatorName = "Tester"
        XCTAssertFalse(goal.validates("Tester", isOwner: false, step: goal.steps[0]), "the validator's own step")
        XCTAssertTrue(goal.validates("Owner", isOwner: true, step: goal.steps[0]), "falls to the owner")
        XCTAssertTrue(goal.validates("Tester", isOwner: false, step: goal.steps[1]))
        XCTAssertFalse(goal.validates("Owner", isOwner: true, step: goal.steps[1]))
    }
}
