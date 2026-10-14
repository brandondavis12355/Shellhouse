import XCTest
@testable import AgentCore

/// From a run where "How are we doing with our goal?" got a 60-step work run, a bot re-ran the same
/// `git checkout ... && ls && head` five times, and git commands went out without the token.
final class RunFixes3Tests: XCTestCase {
    func testGoalProgressQuestionsAreStatusRequests() {
        for text in ["How are we doing with our goal?", "how's the project going?", "Where are we at?", "how far along are we",
                     "what's the status?", "any progress on the web UI?", "goal status"] {
            XCTAssertTrue(AddressingAnalyzer.isStatusRequest(text), text)
        }
        for text in ["how are you all doing today?", "how is it going", "where are we deploying this?", "add a status page"] {
            XCTAssertFalse(AddressingAnalyzer.isStatusRequest(text), text)
        }
    }

    func testTokenIsAttachedToChainsWithLocalGitVerbs() {
        XCTAssertTrue(ActionClassifier.isGitHubNetworkCommand(
            "cd /workspace/r && git fetch origin 2>&1 | tail -5 && echo \"=== files ===\" && git ls-tree -r --name-only origin/feat/web"))
        XCTAssertTrue(ActionClassifier.isGitHubNetworkCommand(
            "cd /workspace/r && git checkout main && git merge fix/a --no-edit && git merge feat/b --no-edit && git push origin main"))
        XCTAssertFalse(ActionClassifier.isGitHubNetworkCommand("cd /workspace/r && git fetch origin && python3 setup.py"))
    }

    private final class SameCheckout: ModelBackend, @unchecked Sendable {
        let name = "same"
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        private let lock = NSLock(); private(set) var calls = 0
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return ModelReply(message: ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "run_shell", arguments: [
                "command": AnyCodable("cd /workspace/r && git checkout feat/web 2>&1 | tail -2 && ls -la && head -60 server.py")])]), usage: nil)
        }
    }
    private final class Repo: SandboxProvider, @unchecked Sendable {
        let name = "repo"
        func exec(_ sandboxID: String, command: String, timeout: TimeInterval, env: [String: String]?) async throws -> ExecResult {
            ExecResult(exitCode: 0, stdout: "Already on 'feat/web'\nYour branch is up to date.\ntotal 60\n-rw-r--r-- server.py\n\"\"\"Tic Tac Toe server\"\"\"\n", stderr: "")
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
    private final class Aborts: @unchecked Sendable {
        private let lock = NSLock(); private(set) var why: String?
        func add(_ e: AgentRuntime.Event) { if case .status(.aborted(let w)) = e { lock.lock(); why = w; lock.unlock() } }
    }

    func testRepeatingANoOpCheckoutIsStillALoop() async {
        let model = SameCheckout(); let aborts = Aborts()
        let runtime = AgentRuntime(model: model, sandbox: Repo(), sandboxID: "t", budgets: AgentRuntime.Budgets(maxIterations: 40),
                                   onEvent: { aborts.add($0) }, requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "x", goal: "check the branch")
        XCTAssertNotNil(aborts.why, "must stop")
        XCTAssertLessThan(model.calls, AgentRuntime.staleAbortAt, "the repeat guards catch it, not only the stale one (\(model.calls) calls)")
    }
}
