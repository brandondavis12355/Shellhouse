import XCTest
@testable import AgentCore

/// A chat-style turn (group reply, no goal work): a substantial plain-text answer ends the turn
/// instead of triggering the "you did not call a tool" nudge that made models repeat themselves.
final class PlainReplyTurnTests: XCTestCase {
    private final class CountingModel: ModelBackend, @unchecked Sendable {
        let name = "counting"
        private let lock = NSLock()
        private var turns: [ChatMessage]
        private(set) var calls = 0
        init(_ turns: [ChatMessage]) { self.turns = turns }
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            let next = turns.isEmpty ? ChatMessage(role: .assistant, content: "", toolCalls: [
                ToolCall(name: "finish_task", arguments: ["summary": AnyCodable("done"), "outcome": AnyCodable("done")])]) : turns.removeFirst()
            return ModelReply(message: next, usage: nil)
        }
    }

    private final class NullSandbox: SandboxProvider, @unchecked Sendable {
        let name = "null"
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

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var summaries: [String] = []
        private(set) var completed = false
        func add(_ e: AgentRuntime.Event) {
            lock.lock(); defer { lock.unlock() }
            if case .message(let m) = e, m.isTaskSummary { summaries.append(m.content) }
            if case .status(.completed) = e { completed = true }
        }
    }

    private func run(_ reply: String, endsTurn: Bool) async -> (calls: Int, summaries: [String], completed: Bool) {
        let model = CountingModel([ChatMessage(role: .assistant, content: reply)])
        let events = Events()
        let runtime = AgentRuntime(
            model: model, sandbox: NullSandbox(), sandboxID: "t", budgets: AgentRuntime.Budgets(maxIterations: 4),
            onEvent: { events.add($0) }, plainReplyEndsTurn: endsTurn
        )
        await runtime.start(systemPrompt: "x", goal: "say hi")
        return (model.calls, events.summaries, events.completed)
    }

    func testASubstantialPlainReplyEndsTheTurnInOneModelCall() async {
        let r = await run("Hey! I'm Cleo, here for the consumer-experience angle on whatever you need.", endsTurn: true)
        XCTAssertEqual(r.calls, 1)
        XCTAssertEqual(r.summaries, ["Hey! I'm Cleo, here for the consumer-experience angle on whatever you need."])
        XCTAssertTrue(r.completed)
    }

    func testShortOrUnfinishedNarrationStillGetsTheNudge() async {
        for text in ["Let me check.", "I'll look into it, one moment, here is the plan:"] {
            let r = await run(text, endsTurn: true)
            XCTAssertGreaterThan(r.calls, 1, text)
        }
    }

    func testDefaultBehaviourIsUnchanged() async {
        let r = await run("Hey! I'm Cleo, here for the consumer-experience angle on whatever you need.", endsTurn: false)
        XCTAssertGreaterThan(r.calls, 1, "without the option the nudge round trip still happens")
    }
}

final class RepeatFingerprintTests: XCTestCase {
    private func fp(_ command: String, timeout: Int? = nil) -> String {
        var args: [String: AnyCodable] = ["command": AnyCodable(command)]
        if let timeout { args["timeout"] = AnyCodable(timeout) }
        return AgentRuntime.repeatFingerprint(for: ToolCall(name: "run_shell", arguments: args))
    }

    func testCosmeticVariationsOfOneCheckAreTheSameCall() {
        let base = fp(#"echo "=== apt-cache policy gh ==="; apt-cache policy gh 2>&1 | head -20; echo "=== apt-cache policy gh-cli ==="; apt-cache policy gh-cli 2>&1 | head -20"#)
        // what Tai Lung actually did: a duplicated clause, no head, a timeout
        let variant = fp(#"echo "=== apt-cache policy gh ==="; apt-cache policy gh 2>&1; echo "=== apt-cache policy gh-cli ==="; apt-cache policy gh-cli 2>&1; echo "=== apt-cache policy gh ==="; apt-cache policy gh 2>&1"#, timeout: 60)
        XCTAssertEqual(base, variant)
        XCTAssertEqual(fp("gh --version 2>&1; echo \"EXIT=$?\""), fp("gh --version 2>&1 || echo \"NOT INSTALLED\""))
    }

    func testDifferentCommandsStayDifferent() {
        XCTAssertNotEqual(fp("apt-cache policy gh"), fp("sudo apt-get update"))
        XCTAssertNotEqual(fp("ls /etc"), fp("ls /var"))
        XCTAssertNotEqual(fp("rm a.txt"), fp("rm b.txt"))
    }

    func testOtherToolsIgnoreOnlyTheTimeout() {
        func f(_ path: String, _ t: Int?) -> String {
            var a: [String: AnyCodable] = ["path": AnyCodable(path)]
            if let t { a["timeout"] = AnyCodable(t) }
            return AgentRuntime.repeatFingerprint(for: ToolCall(name: "read_file", arguments: a))
        }
        XCTAssertEqual(f("a", nil), f("a", 30))
        XCTAssertNotEqual(f("a", nil), f("b", nil))
    }
}

final class SameResultLoopTests: XCTestCase {
    private final class Loop: ModelBackend, @unchecked Sendable {
        let name = "loop"
        private let lock = NSLock()
        private(set) var calls = 0
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            // a different command every time (so argument-based detection never fires) with identical output
            return ModelReply(message: ChatMessage(role: .assistant, content: "", toolCalls: [
                ToolCall(name: "run_shell", arguments: ["command": AnyCodable("ls /workspace/nothing-\(calls)")])]), usage: nil)
        }
    }
    private final class EmptyListing: SandboxProvider, @unchecked Sendable {
        let name = "empty"
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
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock(); private(set) var aborted: String?
        func add(_ e: AgentRuntime.Event) { if case .status(.aborted(let why)) = e { lock.lock(); aborted = why; lock.unlock() } }
    }

    func testARunGettingTheSameResultOverAndOverIsStopped() async {
        let model = Loop(); let seen = Seen()
        let runtime = AgentRuntime(model: model, sandbox: EmptyListing(), sandboxID: "t", budgets: AgentRuntime.Budgets(maxIterations: 30), onEvent: { seen.add($0) }, requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "x", goal: "go")
        XCTAssertNotNil(seen.aborted, "must abort")
        XCTAssertTrue(seen.aborted?.contains("same result") == true, seen.aborted ?? "")
        XCTAssertEqual(model.calls, AgentRuntime.sameResultAbortAt)
    }
}
