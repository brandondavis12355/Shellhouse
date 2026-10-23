import XCTest
@testable import AgentCore

final class ThinkingTests: XCTestCase {
    func testOffNeverThinksAndOnAlwaysDoes() {
        for first in [true, false] {
            for trouble in [true, false] {
                XCTAssertFalse(ThinkingPolicy(mode: .off, firstStepOfTask: first, troubleSinceLastStep: trouble).shouldThink)
                XCTAssertTrue(ThinkingPolicy(mode: .on, firstStepOfTask: first, troubleSinceLastStep: trouble).shouldThink)
            }
        }
    }

    func testAutoThinksOnTheFirstStepAndAfterTroubleOnly() {
        XCTAssertTrue(ThinkingPolicy(mode: .auto, firstStepOfTask: true).shouldThink)
        XCTAssertTrue(ThinkingPolicy(mode: .auto, troubleSinceLastStep: true).shouldThink)
        XCTAssertFalse(ThinkingPolicy(mode: .auto).shouldThink)
    }

    func testRoutineNotesAreNotTrouble() {
        for kind in ["reminder", "budget_warning", "duplicate_call", "unchanged_result", "desktop_verify", "desktop_decide", "gate_vote_split"] {
            XCTAssertFalse(ThinkingPolicy.troubleKinds.contains(kind), kind)
        }
        for kind in ["no_progress", "same_error", "narration", "failure_stop", "open_plan", "unverified_done"] {
            XCTAssertTrue(ThinkingPolicy.troubleKinds.contains(kind), kind)
        }
    }

    func testModesDecodeFromTheirNamesAndDefaultToOffForAnythingElse() {
        XCTAssertEqual(ThinkingMode(rawValue: "auto"), .auto)
        XCTAssertNil(ThinkingMode(rawValue: "maybe"))
        XCTAssertEqual(ThinkingMode.allCases, [.off, .on, .auto])
        XCTAssertFalse(ThinkingMode.allCases.contains { $0.label.isEmpty || $0.detail.isEmpty })
    }

    // MARK: through the runtime

    private final class Box: SandboxProvider, @unchecked Sendable {
        let name = "box"
        func exec(_ sandboxID: String, command: String, timeout: TimeInterval, env: [String: String]?) async throws -> ExecResult {
            ExecResult(exitCode: 0, stdout: "out of \(command) " + UUID().uuidString, stderr: "")
        }
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

    /// Replays a script and notes, for each call, what the runtime asked for: thinking and temperature.
    private final class Observer: ModelBackend, @unchecked Sendable {
        let name = "observer"
        private let lock = NSLock()
        private var script: [ChatMessage]
        private(set) var seen: [(think: Bool?, temperature: Double)] = []
        init(_ script: [ChatMessage]) { self.script = script }
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            let think = ModelThinking.override
            let next: ChatMessage = lock.withLock {
                seen.append((think, temperature))
                return script.isEmpty ? ChatMessage(role: .assistant, content: "", toolCalls: [ThinkingTests.finish]) : script.removeFirst()
            }
            return ModelReply(message: next, usage: nil)
        }
    }
    static let finish = ToolCall(name: "finish_task", arguments: ["summary": AnyCodable("done"), "outcome": AnyCodable("done")])

    private func run(_ mode: ThinkingMode) async -> [(think: Bool?, temperature: Double)] {
        func call(_ command: String) -> ChatMessage {
            ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "run_shell", arguments: ["command": AnyCodable(command)])])
        }
        // step 1 (first), step 2 (routine), step 3 announces (trouble), step 4 acts, step 5 finishes
        let model = Observer([call("ls /a"), call("ls /b"), ChatMessage(role: .assistant, content: "Let me look at it."), call("ls /c"), ChatMessage(role: .assistant, content: "", toolCalls: [Self.finish])])
        let runtime = AgentRuntime(model: model, sandbox: Box(), sandboxID: "t", budgets: AgentRuntime.Budgets(maxIterations: 12),
                                   requestApproval: { _ in .approve }, thinkingMode: mode)
        await runtime.start(systemPrompt: "system", goal: "do the task")
        return model.seen
    }

    func testAutoThinksOnTheFirstStepAndTheStepAfterAnAnnouncement() async {
        let seen = await run(.auto)
        XCTAssertEqual(seen.map { $0.think }, [true, false, false, true, false])
        XCTAssertEqual(seen.map { $0.temperature }, [0.6, 0.2, 0.2, 0.6, 0.2])
    }

    func testOffAsksForNoThinkingAtTheUsualTemperature() async {
        let seen = await run(.off)
        XCTAssertTrue(seen.allSatisfy { $0.think == false && $0.temperature == 0.2 }, "\(seen)")
    }

    func testOnThinksEveryStep() async {
        let seen = await run(.on)
        XCTAssertEqual(seen.count, 5)
        XCTAssertTrue(seen.allSatisfy { $0.think == true && $0.temperature == 0.6 }, "\(seen)")
    }

    func testEveryThinkingStepIsCounted() async {
        let before = Telemetry.recorder.loopEventCounts()["thinking_step"] ?? 0
        _ = await run(.auto)
        XCTAssertEqual((Telemetry.recorder.loopEventCounts()["thinking_step"] ?? 0) - before, 2)
    }

    func testAFollowUpMessageThinksOnItsFirstStepToo() async {
        let model = Observer([ChatMessage(role: .assistant, content: "", toolCalls: [Self.finish]), ChatMessage(role: .assistant, content: "", toolCalls: [Self.finish])])
        let runtime = AgentRuntime(model: model, sandbox: Box(), sandboxID: "t", requestApproval: { _ in .approve }, thinkingMode: .auto)
        await runtime.start(systemPrompt: "system", goal: "first")
        await runtime.send("second")
        XCTAssertEqual(model.seen.map { $0.think }, [true, true])
    }
}
