import XCTest
@testable import AgentCore

final class ContextBudgetTests: XCTestCase {
    func testThresholdLeavesRoomForToolsAndTheReply() {
        XCTAssertEqual(ContextBudget.compactionThreshold(window: 32_768, schemaTokens: 8_000), Int(Double(32_768 - 8_000 - 2_048) * 0.65))
        XCTAssertEqual(ContextBudget.compactionThreshold(window: 8_000, schemaTokens: 7_000), 4_000)
    }

    func testAHeavyFixedPrefixRaisesTheThresholdSoItDoesNotCompactEveryStep() {
        let base = ContextBudget.compactionThreshold(window: 32_768, schemaTokens: 8_000)
        // A small prefix changes nothing.
        XCTAssertEqual(ContextBudget.threshold(window: 32_768, schemaTokens: 8_000, fixedPrefixTokens: 2_000), base)
        // A prefix near the old threshold leaves room to work, but never past 85% of what the window can hold.
        let heavy = ContextBudget.threshold(window: 32_768, schemaTokens: 8_000, fixedPrefixTokens: base)
        XCTAssertGreaterThan(heavy, base)
        XCTAssertLessThanOrEqual(heavy, Int(Double(32_768 - 8_000 - 2_048) * 0.85))
        XCTAssertEqual(ContextBudget.threshold(window: 32_768, schemaTokens: 8_000, fixedPrefixTokens: 1_000_000),
                       Int(Double(32_768 - 8_000 - 2_048) * 0.85))
    }

    func testSummaryAsksForWhatTheBotNeedsToContinue() {
        for heading in ["GOAL:", "DONE AND VERIFIED:", "FILES AND PATHS:", "WHAT WORKED:", "OPEN:"] {
            XCTAssertTrue(ContextBudget.summaryInstruction.contains(heading), heading)
        }
        XCTAssertTrue(ContextBudget.summaryInstruction.contains("Never include passwords"))
    }

    private final class Growing: ModelBackend, @unchecked Sendable {
        let name = "growing"
        private let lock = NSLock()
        private var calls = 0
        private(set) var summaryRequests: [[ChatMessage]] = []
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            lock.lock(); defer { lock.unlock() }
            if tools.isEmpty {
                summaryRequests.append(messages)
                return ModelReply(message: ChatMessage(role: .assistant, content: "GOAL: build it. OPEN: keep going."), usage: nil)
            }
            calls += 1
            if calls <= 14 {
                return ModelReply(message: ChatMessage(role: .assistant, content: "", toolCalls: [
                    ToolCall(name: "run_shell", arguments: ["command": AnyCodable("cat log\(calls).txt")]),
                ]), usage: nil)
            }
            return ModelReply(message: ChatMessage(role: .assistant, content: "", toolCalls: [
                ToolCall(name: "finish_task", arguments: ["summary": AnyCodable("done"), "outcome": AnyCodable("done")]),
            ]), usage: nil)
        }
    }

    private final class Chatty: SandboxProvider, @unchecked Sendable {
        let name = "chatty"
        func exec(_ sandboxID: String, command: String, timeout: TimeInterval, env: [String: String]?) async throws -> ExecResult {
            ExecResult(exitCode: 0, stdout: String(repeating: "line of output \(command)\n", count: 120), stderr: "")
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

    func testCompactionKeepsTheTaskWordForWord() async {
        let model = Growing()
        let task = "Build the tic tac toe game.py in /workspace/ExampleRepo"
        let runtime = AgentRuntime(model: model, sandbox: Chatty(), sandboxID: "t",
                                   budgets: AgentRuntime.Budgets(maxIterations: 30, compactionThresholdTokens: 3_000),
                                   requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "system", goal: task)
        XCTAssertFalse(model.summaryRequests.isEmpty, "expected the conversation to be compacted")
        let transcript = await runtime.transcript()
        XCTAssertEqual(transcript[1].content, task, "the task must survive compaction verbatim")
        XCTAssertTrue(transcript.contains { $0.content.contains("Earlier conversation summarized") })
        XCTAssertTrue(model.summaryRequests.last?.last?.content.contains("FILES AND PATHS:") == true)
        XCTAssertLessThanOrEqual(model.summaryRequests.count, 7, "compaction must not re-run on every step (14 steps here)")
        XCTAssertFalse(model.summaryRequests.contains { $0.contains { $0.content == task } }, "the task is never summarized away")
    }

    private final class Rereads: ModelBackend, @unchecked Sendable {
        let name = "rereads"
        private let lock = NSLock()
        private var calls = 0
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            if calls <= 2 {   // the same look at the same thing, twice
                return ModelReply(message: ChatMessage(role: .assistant, content: "", toolCalls: [
                    ToolCall(name: "run_shell", arguments: ["command": AnyCodable("cat same.txt")]),
                ]), usage: nil)
            }
            return ModelReply(message: ChatMessage(role: .assistant, content: "", toolCalls: [
                ToolCall(name: "finish_task", arguments: ["summary": AnyCodable("done"), "outcome": AnyCodable("done")]),
            ]), usage: nil)
        }
    }

    func testAnIdenticalReadOfTheSameThingIsNotPastedTwice() async {
        let runtime = AgentRuntime(model: Rereads(), sandbox: Chatty(), sandboxID: "t",
                                   budgets: AgentRuntime.Budgets(maxIterations: 10), requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "system", goal: "look")
        let results = await runtime.transcript().filter { $0.role == .tool }
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results[0].content.contains("line of output"))
        XCTAssertTrue(results[1].content.contains("Identical to your earlier"), results[1].content)
        XCTAssertLessThan(results[1].content.count, 600)
    }
}
