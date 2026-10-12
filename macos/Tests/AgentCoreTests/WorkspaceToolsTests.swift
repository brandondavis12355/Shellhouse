import XCTest
@testable import AgentCore

/// An in-memory sandbox: files live in a dictionary; `exec` succeeds with empty output
/// unless a canned reply matches.
private final class MemoryBox: SandboxProvider, @unchecked Sendable {
    let name = "memory"
    private let lock = NSLock()
    var files: [String: String] = [:]
    var commands: [String] = []
    var replies: [(String, ExecResult)] = []

    func exec(_ sandboxID: String, command: String, timeout: TimeInterval, env: [String: String]?) async throws -> ExecResult {
        lock.lock(); defer { lock.unlock() }
        commands.append(command)
        return replies.first { command.contains($0.0) }?.1 ?? ExecResult(exitCode: 0, stdout: "", stderr: "")
    }
    func readFile(_ sandboxID: String, path: String, maxBytes: Int) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let key = try safeRelativePath(path)
        guard let text = files[key] else { throw NSError(domain: "box", code: 2, userInfo: [NSLocalizedDescriptionKey: "No such file: \(path)"]) }
        return Data(text.utf8)
    }
    func writeFile(_ sandboxID: String, path: String, contents: Data) async throws {
        lock.lock(); defer { lock.unlock() }
        files[try safeRelativePath(path)] = String(decoding: contents, as: UTF8.self)
    }
    func create(taskID: String, persistent: Bool) async throws -> SandboxHandle { SandboxHandle(id: taskID, provider: name, persistent: persistent) }
    func start(_ sandboxID: String) async throws -> SandboxHandle { SandboxHandle(id: sandboxID, provider: name, persistent: true) }
    func pause(_ sandboxID: String) async throws {}
    func resume(_ sandboxID: String) async throws {}
    func destroy(_ sandboxID: String) async throws {}
    func health(_ sandboxID: String) async -> Bool { true }
    func reconcile() async throws -> [SandboxHandle] { [] }
    func listSandboxes() async throws -> [SandboxHandle] { [] }
}

final class EditMatcherTests: XCTestCase {
    func testExactSingleMatch() {
        XCTAssertEqual(EditMatcher.apply(to: "a = 1\nb = 2\n", old: "b = 2", new: "b = 3"), .replaced("a = 1\nb = 3\n", occurrences: 1, fuzzy: false))
    }

    func testAmbiguousUnlessReplaceAll() {
        XCTAssertEqual(EditMatcher.apply(to: "x\nx\n", old: "x", new: "y"), .ambiguous(count: 2))
        XCTAssertEqual(EditMatcher.apply(to: "x\nx\n", old: "x", new: "y", replaceAll: true), .replaced("y\ny\n", occurrences: 2, fuzzy: false))
    }

    func testIndentationTolerantMatchKeepsTheFilesIndent() {
        let file = "def f():\n    return 1\n"
        guard case .replaced(let out, _, let fuzzy) = EditMatcher.apply(to: file, old: "        return 1", new: "        return 2") else {
            return XCTFail("expected a match")
        }
        XCTAssertTrue(fuzzy)
        XCTAssertEqual(out, "def f():\n    return 2\n")
    }

    func testNotFoundPointsAtTheClosestLines() {
        guard case .notFound(let hint) = EditMatcher.apply(to: "alpha\nport = 8080\nomega\n", old: "port: 8080", new: "port: 8081") else {
            return XCTFail("expected notFound")
        }
        XCTAssertTrue(hint.contains("2: port = 8080"), hint)
    }
}

final class PagedReadTests: XCTestCase {
    func testPagesWithinTheBudgetAndSaysWhereToContinue() {
        let text = (1...500).map { "line \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n")
        let first = PagedRead.page(text, offset: nil, limit: nil)
        XCTAssertEqual(first["start_line"] as? Int, 1)
        let next = try! XCTUnwrap(first["next_offset"] as? Int)
        XCTAssertLessThanOrEqual((first["content"] as? String ?? "").count, PagedRead.defaultCharacterBudget)
        let second = PagedRead.page(text, offset: next, limit: 3)
        XCTAssertEqual(second["start_line"] as? Int, next)
        XCTAssertEqual(second["end_line"] as? Int, next + 2)
        XCTAssertTrue((second["content"] as? String ?? "").hasPrefix("line \(next) "))
    }

    func testOffsetPastTheEnd() {
        XCTAssertNotNil(PagedRead.page("a\nb\n", offset: 9, limit: nil)["error"])
    }
}

final class WorkspaceToolExecutionTests: XCTestCase {
    private func run(_ registry: ToolRegistry, _ box: MemoryBox, _ name: String, _ args: [String: Any]) async -> [String: Any] {
        await registry.execute(name: name, arguments: args.mapValues { AnyCodable($0) }, sandboxID: "t", sandbox: box, secretStore: SecretStore())
    }

    func testEditRequiresAFreshRead() async {
        let box = MemoryBox(); box.files["app.py"] = "x = 1\n"
        let tools = ToolRegistry()
        let blind = await run(tools, box, "edit_file", ["path": "app.py", "old_text": "x = 1", "new_text": "x = 2"])
        XCTAssertTrue((blind["error"] as? String ?? "").contains("Read app.py"), "\(blind)")
        _ = await run(tools, box, "read_file", ["path": "app.py"])
        box.files["app.py"] = "x = 1\ny = 5\n"   // changed behind the bot's back
        let stale = await run(tools, box, "edit_file", ["path": "app.py", "old_text": "x = 1", "new_text": "x = 2"])
        XCTAssertTrue((stale["error"] as? String ?? "").contains("changed since"), "\(stale)")
        _ = await run(tools, box, "read_file", ["path": "app.py"])
        let ok = await run(tools, box, "edit_file", ["path": "app.py", "old_text": "x = 1", "new_text": "x = 2"])
        XCTAssertEqual(ok["replacements"] as? Int, 1, "\(ok)")
        XCTAssertEqual(box.files["app.py"], "x = 2\ny = 5\n")
    }

    func testAnEditThatBreaksValidJSONIsRefused() async {
        let box = MemoryBox(); box.files["cfg.json"] = "{\"port\": 80}\n"
        let tools = ToolRegistry()
        _ = await run(tools, box, "read_file", ["path": "cfg.json"])
        let bad = await run(tools, box, "edit_file", ["path": "cfg.json", "old_text": "80}", "new_text": "80,}"])
        XCTAssertTrue((bad["error"] as? String ?? "").contains("would break"), "\(bad)")
        XCTAssertEqual(box.files["cfg.json"], "{\"port\": 80}\n", "file left unchanged")
        let good = await run(tools, box, "edit_file", ["path": "cfg.json", "old_text": "80", "new_text": "81"])
        XCTAssertNil(good["error"], "\(good)")
    }

    func testTrailingCommaCountsAsBrokenJSON() {
        XCTAssertTrue(SyntaxCheck.hasTrailingComma("{\"a\": [1, 2,],}"))
        XCTAssertFalse(SyntaxCheck.hasTrailingComma("{\"a\": \"x,}\", \"b\": [1, 2]}"), "commas inside strings don't count")
    }

    func testWriteFileWarnsOnANewBrokenFileButWritesIt() async {
        let box = MemoryBox()
        let result = await run(ToolRegistry(), box, "write_file", ["path": "new.json", "content": "{\"a\": "])
        XCTAssertNotNil(result["warning"])
        XCTAssertEqual(box.files["new.json"], "{\"a\": ")
    }

    func testSearchStaysInsideTheWorkspace() async {
        let result = await run(ToolRegistry(), MemoryBox(), "search_files", ["pattern": "token", "path": "../../home/box/.ssh"])
        XCTAssertNotNil(result["error"], "\(result)")
    }

    func testBackgroundJobRefusesSecretsAndReturnsAJobID() async {
        let box = MemoryBox()
        let refused = await run(ToolRegistry(), box, "run_shell", ["command": "make", "background": true, "use_secrets": ["TOKEN"]])
        XCTAssertNotNil(refused["error"])
        let started = await run(ToolRegistry(), box, "run_shell", ["command": "make build", "background": true])
        let id = try! XCTUnwrap(started["job_id"] as? String)
        XCTAssertNotNil(id.range(of: WorkspaceTools.jobIDPattern, options: .regularExpression))
        XCTAssertTrue(box.commands.last?.contains("setsid nohup bash -c") == true)
    }

    func testCheckJobCanWaitForTheJob() async {
        let box = MemoryBox()
        _ = await run(ToolRegistry(), box, "check_job", ["job_id": "abcd1234", "wait_seconds": 30])
        XCTAssertTrue(box.commands.last?.contains("while [ $i -lt 30 ]") == true, "\(box.commands)")
    }

    func testATimeoutPointsAtBackgroundJobs() async {
        let box = MemoryBox(); box.replies = [("sleep", ExecResult(exitCode: 124, stdout: "", stderr: "Timed out after 120s"))]
        let result = await run(ToolRegistry(), box, "run_shell", ["command": "sleep 500"])
        XCTAssertTrue((result["hint"] as? String ?? "").contains("background"), "\(result)")
    }
}

final class PlanAndErrorNudgeTests: XCTestCase {
    private final class Script: ModelBackend, @unchecked Sendable {
        let name = "script"
        private let lock = NSLock(); private var turns: [ChatMessage]; private(set) var calls = 0
        private(set) var lastMessages: [ChatMessage] = []
        init(_ turns: [ChatMessage]) { self.turns = turns }
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            lock.lock(); defer { lock.unlock() }
            calls += 1; lastMessages = messages
            let next = turns.isEmpty ? ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "finish_task", arguments: ["summary": AnyCodable("ok"), "outcome": AnyCodable("done")])]) : turns.removeFirst()
            return ModelReply(message: next, usage: nil)
        }
    }

    private func finish() -> ChatMessage {
        ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "finish_task", arguments: ["summary": AnyCodable("all done"), "outcome": AnyCodable("done")])])
    }

    func testFinishIsRefusedOnceWhilePlanStepsAreOpen() async {
        let plan = ToolCall(name: "update_plan", arguments: ["steps": AnyCodable([["text": "install", "status": "done"], ["text": "test", "status": "pending"]])])
        let model = Script([ChatMessage(role: .assistant, content: "", toolCalls: [plan]), finish(), finish()])
        let runtime = AgentRuntime(model: model, sandbox: MemoryBox(), sandboxID: "t", requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "x", goal: "go")
        let tool = await runtime.transcript().filter { $0.role == .tool }.map(\.content)
        XCTAssertTrue(tool.contains { $0.contains("Not finished") && $0.contains("test") }, "\(tool)")
        XCTAssertEqual(model.calls, 3, "refused once, accepted on the second attempt")
    }

    func testOnlyOneStepInProgress() async {
        let plan = ToolCall(name: "update_plan", arguments: ["steps": AnyCodable([["text": "a", "status": "in_progress"], ["text": "b", "status": "in_progress"]])])
        let runtime = AgentRuntime(model: Script([ChatMessage(role: .assistant, content: "", toolCalls: [plan])]), sandbox: MemoryBox(), sandboxID: "t", requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "x", goal: "go")
        let tool = await runtime.transcript().filter { $0.role == .tool }.map(\.content)
        XCTAssertTrue(tool.contains { $0.contains("Only one step") }, "\(tool)")
    }

    func testTheThirdIdenticalErrorGetsOneNudge() async {
        let box = MemoryBox()
        let read = { (n: Int) in ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "read_file", arguments: ["path": AnyCodable("missing\(n).txt")])]) }
        // Different paths (so not a repeated call), same error each time once digits are ignored.
        let runtime = AgentRuntime(model: Script([read(1), read(2), read(3), read(4)]), sandbox: box, sandboxID: "t", requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "x", goal: "go")
        let nudges = await runtime.transcript().filter { $0.role == .user && $0.content.hasPrefix("[stuck]") }
        XCTAssertEqual(nudges.count, 1)
        XCTAssertTrue(nudges.first?.content.contains("read_file") == true)
    }
}
