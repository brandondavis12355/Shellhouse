import XCTest
@testable import AgentCore

final class ObservationPolicyTests: XCTestCase {
    func testLongOutputKeepsHeadAndTailAndSaysWhatWasCut() {
        let big = (1...2000).map { "line \($0)" }.joined(separator: "\n")
        let cut = ObservationPolicy.truncateMiddle(big, limit: 1000)
        XCTAssertLessThan(cut.count, 1300)
        XCTAssertTrue(cut.hasPrefix("line 1\n"))
        XCTAssertTrue(cut.hasSuffix("line 2000"))
        XCTAssertTrue(cut.contains("characters") && cut.contains("omitted"))
        XCTAssertEqual(ObservationPolicy.truncateMiddle("short"), "short")
    }

    func testBoundedOnlyTouchesLongStringFields() {
        let out = ObservationPolicy.bounded(["exit_code": 0, "stdout": String(repeating: "x", count: 20_000), "stderr": "small"])
        XCTAssertEqual(out["exit_code"] as? Int, 0)
        XCTAssertEqual(out["stderr"] as? String, "small")
        XCTAssertLessThan((out["stdout"] as? String)?.count ?? 99_999, 6_500)
    }

    func testAChainedFailureWithExitZeroIsFlagged() {
        // Seen in the real logs: `gh --version; echo "exit=$?"` reports exit_code 0 around a failure.
        let o = ObservationPolicy.annotate(tool: "run_shell", observation: ["exit_code": 0, "stdout": "bash: line 1: gh: command not found\nexit=127\n", "stderr": ""])
        XCTAssertNotNil(o["warning"])
        XCTAssertTrue((o["hint"] as? String)?.contains("not installed") == true)
    }

    func testHintsAreSpecificAndGrounded() {
        func hint(_ out: String) -> String? { ObservationPolicy.annotate(tool: "run_shell", observation: ["exit_code": 1, "stdout": "", "stderr": out])["hint"] as? String }
        XCTAssertTrue(hint("E: Unable to locate package gh")?.contains("apt-get update") == true)
        XCTAssertTrue(hint("ls: cannot access '/x': No such file or directory")?.contains("parent") == true)
        XCTAssertTrue(hint("bash: /root/x: Permission denied")?.contains("ownership") == true)
        XCTAssertNil(hint("something odd happened"))
        XCTAssertNil(ObservationPolicy.annotate(tool: "read_file", observation: ["content": "command not found"])["warning"])
    }

    func testAnEmptyResultIsExplained() {
        let o = ObservationPolicy.annotate(tool: "run_shell", observation: ["exit_code": 0, "stdout": "", "stderr": ""])
        XCTAssertNotNil(o["note"])
    }

    func testOldBulkyToolResultsAreCollapsedButRecentOnesAndOtherRolesStay() {
        var messages: [ChatMessage] = [ChatMessage(role: .system, content: "sys"), ChatMessage(role: .user, content: "go")]
        for i in 0..<12 {
            messages.append(ChatMessage(role: .assistant, content: "step \(i)"))
            messages.append(ChatMessage(role: .tool, content: "result \(i)\n" + String(repeating: "data ", count: 400), toolName: "run_shell"))
        }
        let out = ObservationPolicy.collapseStale(messages, keepLast: 4)
        let tools = out.filter { $0.role == .tool }
        XCTAssertEqual(tools.count, 12)
        XCTAssertTrue(tools.prefix(8).allSatisfy { $0.content.hasPrefix("[earlier output") })
        XCTAssertTrue(tools.suffix(4).allSatisfy { !$0.content.hasPrefix("[earlier output") })
        XCTAssertEqual(out.filter { $0.role == .assistant }.count, 12)
        XCTAssertEqual(out.first?.content, "sys")
    }
}

final class StuckDetectorTests: XCTestCase {
    func testPingPongIsNudgedThenStopped() {
        var d = StuckDetector()
        var verdicts: [StuckDetector.Verdict] = []
        for i in 0..<8 { verdicts.append(d.recordAction(i % 2 == 0 ? "A" : "B")) }
        XCTAssertEqual(verdicts[5].isNudge, true)
        XCTAssertEqual(verdicts[7], .abort("alternated between the same two actions without making progress"))
        XCTAssertEqual(verdicts[0], .fine)
    }

    func testProgressingWorkIsLeftAlone() {
        var d = StuckDetector()
        for i in 0..<20 { XCTAssertEqual(d.recordAction("call-\(i)"), .fine) }
        for i in 0..<10 { XCTAssertEqual(d.recordAction(i % 3 == 0 ? "A" : (i % 3 == 1 ? "B" : "C")), .fine) }
    }

    func testMonologueIsNudgedAtThreeAndStoppedAtFive() {
        var d = StuckDetector()
        XCTAssertEqual(d.recordPlainReply(), .fine)
        XCTAssertEqual(d.recordPlainReply(), .fine)
        XCTAssertTrue(d.recordPlainReply().isNudge)
        XCTAssertEqual(d.recordPlainReply(), .fine)
        if case .abort = d.recordPlainReply() {} else { XCTFail("must stop at five") }
    }

    func testAnActionBreaksAMonologue() {
        var d = StuckDetector()
        _ = d.recordPlainReply(); _ = d.recordPlainReply()
        _ = d.recordAction("x")
        XCTAssertEqual(d.recordPlainReply(), .fine)
    }

    func testResetForgetsHistory() {
        var d = StuckDetector()
        for i in 0..<5 { _ = d.recordAction(i % 2 == 0 ? "A" : "B") }
        d.reset()
        XCTAssertEqual(d.recordAction("A"), .fine)
        XCTAssertEqual(d.recordAction("B"), .fine)
    }
}
private extension StuckDetector.Verdict { var isNudge: Bool { if case .nudge = self { return true }; return false } }

final class ToolCallValidatorTests: XCTestCase {
    private let schemas = [
        ToolSchema(name: "run_shell", description: "", parameters: ["type": "object", "properties": ["command": ["type": "string"], "timeout": ["type": "integer"]], "required": ["command"]]),
        ToolSchema(name: "read_file", description: "", parameters: ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]),
        ToolSchema(name: "finish_task", description: "", parameters: ["type": "object", "properties": ["summary": ["type": "string"]], "required": ["summary"]]),
    ]
    private func call(_ name: String, _ args: [String: Any]) -> ToolCall { ToolCall(name: name, arguments: args.mapValues { AnyCodable($0) }) }

    func testValidCallsPass() {
        XCTAssertNil(ToolCallValidator.problem(with: call("run_shell", ["command": "ls"]), schemas: schemas))
        XCTAssertNil(ToolCallValidator.problem(with: call("run_shell", ["command": "ls", "timeout": 30]), schemas: schemas))
    }

    func testMissingAndWrongTypedArgumentsAreExplained() {
        XCTAssertTrue(ToolCallValidator.problem(with: call("run_shell", [:]), schemas: schemas)?.contains("missing required 'command'") == true)
        XCTAssertTrue(ToolCallValidator.problem(with: call("run_shell", ["command": "  "]), schemas: schemas)?.contains("missing") == true)
        XCTAssertTrue(ToolCallValidator.problem(with: call("run_shell", ["command": "ls", "timeout": "soon"]), schemas: schemas)?.contains("'timeout' should be integer") == true)
    }

    func testUnknownToolsGetADidYouMean() {
        XCTAssertTrue(ToolCallValidator.problem(with: call("run_command", ["command": "ls"]), schemas: schemas)?.contains("Did you mean 'run_shell'") == true)
        XCTAssertTrue(ToolCallValidator.problem(with: call("bash", [:]), schemas: schemas)?.contains("run_shell") == true)
        XCTAssertTrue(ToolCallValidator.problem(with: call("read_fil", ["path": "x"]), schemas: schemas)?.contains("read_file") == true)
        XCTAssertNil(ToolCallValidator.problem(with: call("finish_task", ["summary": "done"]), schemas: schemas))
    }
}

final class ShellLintTests: XCTestCase {
    func testBrokenCommandsAreCaughtBeforeAnyApproval() {
        XCTAssertNotNil(ShellLint.problem(in: "echo \"unterminated"))
        XCTAssertNotNil(ShellLint.problem(in: ""))
        XCTAssertNotNil(ShellLint.problem(in: "```bash\nls\n```"))
    }
    func testNormalCommandsPass() {
        for c in ["ls -la", "echo \"a b\" | grep a", "sudo apt-get install -y gh", "for f in *.txt; do cat \"$f\"; done"] {
            XCTAssertNil(ShellLint.problem(in: c), c)
        }
    }
}

final class ReplyQualityTests: XCTestCase {
    func testAnnouncementsAreNotAnswers() {
        for t in ["I'll check that now.", "Let me look into the gh install and report back.", "First, I need to check the VM:", "Now I will run the version check"] {
            XCTAssertTrue(ReplyQuality.looksLikeNarration(t), t)
        }
        for t in ["gh 2.46.0 is installed at /usr/bin/gh.", "Done: installed gh (2.46.0).", "No blockers. Next I'm waiting for tasks.",
                  String(repeating: "I'll summarize the findings in detail. ", count: 20)] {
            XCTAssertFalse(ReplyQuality.looksLikeNarration(t), t)
        }
    }

    func testNearDuplicatesAreDetected() {
        let a = "Hey! I'm Cleo, here for the consumer-experience angle on whatever you need."
        XCTAssertTrue(ReplyQuality.isDuplicate(a, of: ["something else entirely", a + " "]))
        XCTAssertTrue(ReplyQuality.isDuplicate("Hey!  I'm Cleo, here for the consumer experience angle on whatever you need", of: [a]))
        XCTAssertFalse(ReplyQuality.isDuplicate("gh 2.46.0 is installed on my VM.", of: [a]))
        XCTAssertFalse(ReplyQuality.isDuplicate("ok", of: ["ok"]), "very short replies are never duplicates")
    }
}

final class EvidenceGroundingTests: XCTestCase {
    private let pool = "{\"stdout\":\"/usr/bin/gh\\ngh version 2.46.0 (2025-01-13 Debian 2.46.0-3)\"}"

    func testEvidenceThatQuotesRealOutputIsGrounded() {
        XCTAssertTrue(EvidenceGrounding.isGrounded(evidence: "Ran gh --version: gh version 2.46.0, exit 0", observations: pool))
        XCTAssertTrue(EvidenceGrounding.isGrounded(evidence: "binary at /usr/bin/gh", observations: pool))
    }

    func testVagueOrInventedEvidenceIsNot() {
        XCTAssertFalse(EvidenceGrounding.isGrounded(evidence: "I checked and it works fine, everything verified", observations: pool))
        XCTAssertFalse(EvidenceGrounding.isGrounded(evidence: "gh version 9.99.1 installed at /opt/bin/gh", observations: pool))
        XCTAssertFalse(EvidenceGrounding.isGrounded(evidence: "gh version 2.46.0", observations: ""), "no tool output at all")
    }
}

final class TemporalContextTests: XCTestCase {
    func testPromptLineStatesTheDateExplicitly() {
        let date = Date(timeIntervalSince1970: 1_791_300_000)   // 2026-10-06
        let line = TemporalContext.promptLine(now: date, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(line.contains("2026"), line)
        XCTAssertTrue(line.contains("UTC") || line.contains("GMT"), line)
        XCTAssertTrue(line.contains("never guess the date"), line)
    }
}

final class RuntimeReliabilityIntegrationTests: XCTestCase {
    private final class Script: ModelBackend, @unchecked Sendable {
        let name = "script"
        private let lock = NSLock(); private var turns: [ChatMessage]; private(set) var seen: [[ChatMessage]] = []
        init(_ turns: [ChatMessage]) { self.turns = turns }
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            lock.lock(); defer { lock.unlock() }
            seen.append(messages)
            let next = turns.isEmpty ? ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "finish_task", arguments: ["summary": AnyCodable("finished the whole job"), "outcome": AnyCodable("done")])]) : turns.removeFirst()
            return ModelReply(message: next, usage: nil)
        }
    }
    private final class Box: SandboxProvider, @unchecked Sendable {
        let name = "box"; let stdout: String
        private let lock = NSLock(); private(set) var ran: [String] = []
        init(stdout: String = "") { self.stdout = stdout }
        func exec(_ sandboxID: String, command: String, timeout: TimeInterval, env: [String: String]?) async throws -> ExecResult {
            lock.lock(); ran.append(command); lock.unlock()
            return ExecResult(exitCode: 0, stdout: stdout, stderr: "")
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
    private func shell(_ c: String) -> ChatMessage { ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "run_shell", arguments: ["command": AnyCodable(c)])]) }

    func testBadCallsAreAnsweredWithACorrectionAndNeverReachTheSandbox() async {
        let model = Script([ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "run_command", arguments: ["command": AnyCodable("ls /workspace")])]),
                            shell("echo \"unterminated")])
        let box = Box()
        let runtime = AgentRuntime(model: model, sandbox: box, sandboxID: "t", requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "x", goal: "go")
        XCTAssertTrue(box.ran.filter { !$0.contains("/workspace/.shellhouse") }.isEmpty, "nothing executed: \(box.ran)")
        let toolMessages = await runtime.transcript().filter { $0.role == .tool }.map(\.content)
        XCTAssertTrue(toolMessages.contains { $0.contains("Did you mean") && $0.contains("run_shell") })
        XCTAssertTrue(toolMessages.contains { $0.contains("syntax problem") })
    }

    func testHugeOutputIsBoundedAndAFailureInAChainIsFlagged() async {
        let model = Script([shell("cat /workspace/big.log")])
        let box = Box(stdout: String(repeating: "log line\n", count: 5_000) + "bash: line 1: gh: command not found\n")
        let runtime = AgentRuntime(model: model, sandbox: box, sandboxID: "t", requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "x", goal: "go")
        let result = await runtime.transcript().first { $0.role == .tool }?.content ?? ""
        XCTAssertLessThan(result.count, 9_000)
        XCTAssertTrue(result.contains("omitted"))
        XCTAssertTrue(result.contains("warning") && result.contains("command not found"), "tail with the real error survives and is flagged")
    }
}

final class ClaimCheckTests: XCTestCase {
    func testSpecificsAreVersionsPathsAddressesAndHashes() {
        let found = ClaimCheck.specifics(in: "gh 2.46.0 lives at /usr/bin/gh (host 192.0.2.10), commit fcf48a5d67c8, see github.com and step 3.")
        XCTAssertEqual(Set(found), ["2.46.0", "/usr/bin/gh", "192.0.2.10", "fcf48a5d67c8"])
    }

    func testOnlyUnseenSpecificsAreFlagged() {
        let tools = "gh version 2.46.0 (2025-01-13 Debian 2.46.0-3)\n/usr/bin/gh"
        XCTAssertEqual(ClaimCheck.unsupported(in: "Installed gh 2.46.0 at /usr/bin/gh.", sources: tools), [])
        XCTAssertEqual(ClaimCheck.unsupported(in: "Installed gh 2.99.1 at /usr/bin/gh.", sources: tools), ["2.99.1"])
        XCTAssertEqual(ClaimCheck.unsupported(in: "Binary at /opt/tools/gh version 2.46.0", sources: tools), ["/opt/tools/gh"])
        XCTAssertEqual(ClaimCheck.unsupported(in: "All good, nothing to flag here.", sources: ""), [])
    }

    func testUnsupportedLinesAreRemovedAsALastResort() {
        let reply = "Done: installed gh.\nVersion: 9.9.9\nBlockers: none"
        XCTAssertEqual(ClaimCheck.removingLines(stating: ["9.9.9"], from: reply), "Done: installed gh.\nBlockers: none")
        XCTAssertEqual(ClaimCheck.removingLines(stating: [], from: reply), reply)
    }
}

final class ToolCallRecoveryTests: XCTestCase {
    private let names: Set<String> = ["run_shell", "read_file", "finish_task"]

    private func schema(_ name: String, _ properties: [String], required: [String]) -> ToolSchema {
        ToolSchema(name: name, description: "", parameters: [
            "type": "object", "properties": Dictionary(uniqueKeysWithValues: properties.map { ($0, ["type": "string"]) }), "required": required,
        ])
    }

    func testArgumentsOnlyJSONBecomesTheOneToolThatTakesThem() {
        let schemas = [schema("update_goal_step", ["step_id", "status", "evidence", "assignee"], required: ["step_id", "status"]),
                       schema("read_file", ["path"], required: ["path"])]
        let text = #"{"step_id":"X1","status":"done","evidence":"ran the tests"}"#
        let call = ToolCallRecovery.extract(from: text, toolNames: ["update_goal_step", "read_file"], schemas: schemas)
        XCTAssertEqual(call?.name, "update_goal_step")
        XCTAssertEqual(call?.arguments["step_id"]?.asString, "X1")
    }

    func testArgumentsOnlyJSONIsNotGuessedWhenAmbiguousOrIncomplete() {
        let two = [schema("a", ["text"], required: ["text"]), schema("b", ["text"], required: ["text"])]
        XCTAssertNil(ToolCallRecovery.extract(from: #"{"text":"hi"}"#, toolNames: ["a", "b"], schemas: two))
        let one = [schema("update_goal_step", ["step_id", "status"], required: ["step_id", "status"])]
        XCTAssertNil(ToolCallRecovery.extract(from: #"{"status":"done"}"#, toolNames: ["update_goal_step"], schemas: one))
        // JSON inside a sentence is prose, not a call.
        XCTAssertNil(ToolCallRecovery.extract(from: #"The reply looks like {"step_id":"X1","status":"done"} to me."#, toolNames: ["update_goal_step"], schemas: one))
    }

    func testTrashPathsGetAWarning() {
        XCTAssertNotNil(ObservationPolicy.trashWarning(forArguments: #"{"command":"cd /workspace/.shellhouse/trash/2026-10-15T17-48-56Z/workspace/Repo && ls"}"#))
        XCTAssertNotNil(ObservationPolicy.trashWarning(forArguments: #"{"path":"/workspace/.brok/trash/x/y.py"}"#))
        XCTAssertNil(ObservationPolicy.trashWarning(forArguments: #"{"command":"cd /workspace/Repo && ls"}"#))
    }

    func testToolCallsWrittenAsTextAreRecovered() {
        let forms = [
            #"{"name":"run_shell","arguments":{"command":"ls /workspace"}}"#,
            "Action: {\"name\": \"run_shell\", \"arguments\": {\"command\": \"ls /workspace\"}}",
            "```json\n{\"tool\":\"run_shell\",\"parameters\":{\"command\":\"ls /workspace\"}}\n```",
            "I'll run it.\n{\"name\":\"run_shell\",\"arguments\":\"{\\\"command\\\":\\\"ls /workspace\\\"}\"}",
        ]
        for text in forms {
            let call = ToolCallRecovery.extract(from: text, toolNames: names)
            XCTAssertEqual(call?.name, "run_shell", text)
            XCTAssertEqual(call?.arguments["command"]?.asString, "ls /workspace", text)
        }
    }

    func testOrdinaryTextAndUnknownToolsAreLeftAlone() {
        XCTAssertNil(ToolCallRecovery.extract(from: "The config looks like {\"debug\": true}.", toolNames: names))
        XCTAssertNil(ToolCallRecovery.extract(from: #"{"name":"launch_missiles","arguments":{}}"#, toolNames: names))
        XCTAssertNil(ToolCallRecovery.extract(from: "no json at all", toolNames: names))
        XCTAssertNil(ToolCallRecovery.extract(from: String(repeating: "{\"name\":\"run_shell\"} ", count: 400), toolNames: names), "too long to be a call")
    }
}

final class ArgumentCoercionTests: XCTestCase {
    private let schemas = [ToolSchema(name: "run_shell", description: "", parameters: ["type": "object", "properties": ["command": ["type": "string"], "timeout": ["type": "integer"], "flag": ["type": "boolean"], "names": ["type": "array"]], "required": ["command"]])]

    func testHarmlessTypeSlipsAreFixedNotRejected() {
        let call = ToolCall(name: "run_shell", arguments: ["command": AnyCodable("ls"), "timeout": AnyCodable("30"), "flag": AnyCodable("true"), "names": AnyCodable("one")])
        let fixed = ToolCallValidator.coerced(call, schemas: schemas)
        XCTAssertEqual(fixed.arguments["timeout"]?.value as? Int, 30)
        XCTAssertEqual(fixed.arguments["flag"]?.value as? Bool, true)
        XCTAssertEqual((fixed.arguments["names"]?.value as? [String]) ?? [], ["one"])
        XCTAssertNil(ToolCallValidator.problem(with: fixed, schemas: schemas))
    }

    func testNonsenseIsStillReported() {
        let call = ToolCall(name: "run_shell", arguments: ["command": AnyCodable("ls"), "timeout": AnyCodable("soon")])
        XCTAssertNotNil(ToolCallValidator.problem(with: ToolCallValidator.coerced(call, schemas: schemas), schemas: schemas))
    }
}

final class DigestAndBudgetTests: XCTestCase {
    func testEvidenceDigestIsReadableAndBounded() {
        let raw = "{\"stdout\":\"/usr/bin/gh\\ngh version 2.46.0\\n\",\"exit_code\":0}"
        let d = EvidenceDigest.digest(raw)
        XCTAssertTrue(d.contains("gh version 2.46.0"))
        XCTAssertFalse(d.contains("\\n"))
        XCTAssertLessThanOrEqual(EvidenceDigest.digest(String(repeating: "x ", count: 2_000), limit: 300).count, 302)
    }

    func testBudgetWarningsComeInTwoSteps() {
        XCTAssertNil(StepBudget.warning(iteration: 10, max: 40))
        XCTAssertEqual(StepBudget.warning(iteration: 30, max: 40)?.id, 1)
        XCTAssertEqual(StepBudget.warning(iteration: 36, max: 40)?.id, 2)
        XCTAssertTrue(StepBudget.warning(iteration: 36, max: 40)?.text.contains("finish_task") == true)
        XCTAssertNil(StepBudget.warning(iteration: 3, max: 4), "tiny budgets are not nagged")
    }
}

final class RuntimeRoundTwoTests: XCTestCase {
    private final class Script: ModelBackend, @unchecked Sendable {
        let name = "script"
        private let lock = NSLock(); private var turns: [ChatMessage]
        init(_ turns: [ChatMessage]) { self.turns = turns }
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            lock.lock(); defer { lock.unlock() }
            let next = turns.isEmpty ? ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "finish_task", arguments: ["summary": AnyCodable("finished the whole job"), "outcome": AnyCodable("done")])]) : turns.removeFirst()
            return ModelReply(message: next, usage: nil)
        }
    }
    private final class Box: SandboxProvider, @unchecked Sendable {
        let name = "box"
        private let lock = NSLock(); private(set) var ran: [String] = []
        func exec(_ sandboxID: String, command: String, timeout: TimeInterval, env: [String: String]?) async throws -> ExecResult {
            lock.lock(); ran.append(command); lock.unlock()
            return ExecResult(exitCode: 0, stdout: "ok \(command.count)", stderr: "")
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
        var userCommands: [String] { lock.lock(); defer { lock.unlock() }; return ran.filter { !$0.contains("/workspace/.shellhouse") } }
    }
    private func call(_ command: String, extra: [String: Any] = [:]) -> ToolCall {
        var args: [String: AnyCodable] = ["command": AnyCodable(command)]
        for (k, v) in extra { args[k] = AnyCodable(v) }
        return ToolCall(name: "run_shell", arguments: args)
    }

    private final class Counting: ModelBackend, @unchecked Sendable {
        let name = "counting"
        private let lock = NSLock(); private var turns: [ChatMessage]; private(set) var calls = 0
        init(_ turns: [ChatMessage]) { self.turns = turns }
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            let next = turns.isEmpty ? ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "finish_task", arguments: ["summary": AnyCodable("done via finish_task"), "outcome": AnyCodable("done")])]) : turns.removeFirst()
            return ModelReply(message: next, usage: nil)
        }
    }

    func testAPlainAnswerAfterToolWorkEndsTheTurn() async {
        let model = Counting([
            ChatMessage(role: .assistant, content: "", toolCalls: [call("uname -r")]),
            ChatMessage(role: .assistant, content: "The kernel is 6.17.0 and the distribution is Debian 13."),
        ])
        let runtime = AgentRuntime(model: model, sandbox: Box(), sandboxID: "t", requestApproval: { _ in .approve }, answerEndsTurnAfterTools: true)
        await runtime.start(systemPrompt: "x", goal: "Which kernel?")
        XCTAssertEqual(model.calls, 2, "no extra round trip through finish_task")
    }

    func testAnAnnouncementAfterToolsDoesNotEndTheTurn() async {
        let model = Counting([
            ChatMessage(role: .assistant, content: "", toolCalls: [call("ls /workspace")]),
            ChatMessage(role: .assistant, content: "Let me check the other folder as well before I answer."),
        ])
        let runtime = AgentRuntime(model: model, sandbox: Box(), sandboxID: "t", requestApproval: { _ in .approve }, answerEndsTurnAfterTools: true)
        await runtime.start(systemPrompt: "x", goal: "List files")
        XCTAssertEqual(model.calls, 3, "narration is nudged on to finish_task")
    }

    func testAPlainReplyWithoutToolWorkStillNeedsFinishTask() async {
        let model = Counting([ChatMessage(role: .assistant, content: "Sure, the answer is that there are four files here.")])
        let runtime = AgentRuntime(model: model, sandbox: Box(), sandboxID: "t", requestApproval: { _ in .approve }, answerEndsTurnAfterTools: true)
        await runtime.start(systemPrompt: "x", goal: "How many files?")
        XCTAssertEqual(model.calls, 2)
    }

    func testAReplyEndingInAPlanDoesNotEndTheTurn() async {
        let model = Counting([
            ChatMessage(role: .assistant, content: "", toolCalls: [call("curl -s https://example.com/licence")]),
            ChatMessage(role: .assistant, content: "The licensing page returned \"Not Found\". Let me try the correct URL."),
        ])
        let runtime = AgentRuntime(model: model, sandbox: Box(), sandboxID: "t", requestApproval: { _ in .approve }, answerEndsTurnAfterTools: true)
        await runtime.start(systemPrompt: "x", goal: "Which license?")
        XCTAssertEqual(model.calls, 3, "a reply that ends with what it will do next keeps going")
    }

    func testEndsWithIntent() {
        XCTAssertTrue(ReplyQuality.endsWithIntent("The browser window is open. Let me focus it and take a screenshot to confirm."))
        XCTAssertTrue(ReplyQuality.endsWithIntent("Found the file. Next, I'll check its contents"))
        XCTAssertFalse(ReplyQuality.endsWithIntent("I checked it. PostgreSQL uses the PostgreSQL License (source: postgresql.org)."))
        XCTAssertFalse(ReplyQuality.endsWithIntent("Let me know if you need anything else? The average is 18.0."))
        XCTAssertFalse(ReplyQuality.endsWithIntent("The average is 18.0. Let me know if you need anything else."))
    }

    func testAToolCallWrittenAsTextIsExecuted() async {
        let model = Script([ChatMessage(role: .assistant, content: "Action: {\"name\": \"run_shell\", \"arguments\": {\"command\": \"mkdir /workspace/from_text\"}}")])
        let box = Box()
        let runtime = AgentRuntime(model: model, sandbox: box, sandboxID: "t", requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "x", goal: "go")
        XCTAssertTrue(box.userCommands.contains { $0.contains("from_text") }, "\(box.userCommands)")
    }

    func testAStringTimeoutIsCoercedAndIdenticalCallsInOneTurnRunOnce() async {
        let same = call("mkdir /workspace/once", extra: ["timeout": "30"])
        let model = Script([ChatMessage(role: .assistant, content: "", toolCalls: [same, same])])
        let box = Box()
        let runtime = AgentRuntime(model: model, sandbox: box, sandboxID: "t", requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "x", goal: "go")
        XCTAssertEqual(box.userCommands.filter { $0.contains("mkdir /workspace/once") }.count, 1)
        let tools = await runtime.transcript().filter { $0.role == .tool }.map(\.content)
        XCTAssertEqual(tools.count, 2, "both calls get an answer so the transcript stays well-formed")
        XCTAssertTrue(tools.contains { $0.contains("Duplicate") })
    }

    func testTheObjectiveIsRecitedAndTheBudgetWarnedAsTheRunGoesOn() async {
        let turns = (0..<9).map { ChatMessage(role: .assistant, content: "", toolCalls: [call("echo step\($0) > /workspace/s\($0).txt")]) }
        let runtime = AgentRuntime(model: Script(turns), sandbox: Box(), sandboxID: "t", budgets: AgentRuntime.Budgets(maxIterations: 12), requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "x", goal: "Install gh on the VM and report its version")
        let users = await runtime.transcript().filter { $0.role == .user }.map(\.content)
        XCTAssertTrue(users.contains { $0.hasPrefix("[reminder]") && $0.contains("Install gh on the VM") })
        XCTAssertTrue(users.contains { $0.hasPrefix("[budget]") && $0.contains("wrapping up") || $0.contains("wrap") })
        // Earlier reminders stay in place (cache-friendly); the newest one is the last reminder.
        XCTAssertTrue(users.last { $0.hasPrefix("[reminder]") }?.contains("Install gh on the VM") == true)
    }
}

final class ReliabilityFlagsTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "rel-\(UUID().uuidString)")! }

    func testEverythingIsOnUntilSwitchedOffAndTheSwitchSticks() {
        let d = defaults()
        for f in Reliability.Feature.allCases { XCTAssertTrue(Reliability.isOn(f, defaults: d), f.rawValue) }
        Reliability.set(.loopGuards, false, defaults: d)
        XCTAssertFalse(Reliability.isOn(.loopGuards, defaults: d))
        XCTAssertTrue(Reliability.isOn(.callChecks, defaults: d), "other groups unaffected")
        Reliability.resetAll(defaults: d)
        XCTAssertTrue(Reliability.isOn(.loopGuards, defaults: d))
    }

    func testEveryFeatureHasATitleAndExplanation() {
        for f in Reliability.Feature.allCases { XCTAssertFalse(f.title.isEmpty); XCTAssertGreaterThan(f.detail.count, 40) }
        XCTAssertEqual(Set(Reliability.Feature.allCases.map(\.title)).count, Reliability.Feature.allCases.count)
    }
}

/// Switching a group off really turns that behaviour off (and back on restores it). Uses the shared defaults,
/// so each test restores what it changed.
final class FlagsActuallyGateBehaviourTests: XCTestCase {
    private final class Script: ModelBackend, @unchecked Sendable {
        let name = "script"
        private let lock = NSLock(); private var turns: [ChatMessage]
        init(_ turns: [ChatMessage]) { self.turns = turns }
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            lock.lock(); defer { lock.unlock() }
            let next = turns.isEmpty ? ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "finish_task", arguments: ["summary": AnyCodable("finished the whole job"), "outcome": AnyCodable("done")])]) : turns.removeFirst()
            return ModelReply(message: next, usage: nil)
        }
    }
    private final class Box: SandboxProvider, @unchecked Sendable {
        let name = "box"
        func exec(_ sandboxID: String, command: String, timeout: TimeInterval, env: [String: String]?) async throws -> ExecResult {
            ExecResult(exitCode: 0, stdout: String(repeating: "line\n", count: 4_000) + "bash: x: command not found\n", stderr: "")
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
    private func firstToolResult() async -> String {
        let turn = ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "run_shell", arguments: ["command": AnyCodable("cat /workspace/big.log")])])
        let runtime = AgentRuntime(model: Script([turn]), sandbox: Box(), sandboxID: "t", requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "x", goal: "go")
        return await runtime.transcript().first { $0.role == .tool }?.content ?? ""
    }

    func testOutputLimitsAndFailureHintsFollowTheirSwitches() async {
        defer { Reliability.resetAll() }
        let on = await firstToolResult()
        XCTAssertTrue(on.contains("omitted") && on.contains("warning"))
        Reliability.set(.outputLimits, false); Reliability.set(.failureHints, false)
        let off = await firstToolResult()
        XCTAssertFalse(off.contains("omitted"))
        XCTAssertFalse(off.contains("warning"))
        XCTAssertGreaterThan(off.count, on.count * 2)
        Reliability.resetAll()
        let back = await firstToolResult()
        XCTAssertTrue(back.contains("omitted"))
    }

    func testCallChecksOffStillNeverRunsAnUnknownTool() async {
        defer { Reliability.resetAll() }
        Reliability.set(.callChecks, false)
        let turn = ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "run_command", arguments: ["command": AnyCodable("ls")])])
        let runtime = AgentRuntime(model: Script([turn]), sandbox: Box(), sandboxID: "t", requestApproval: { _ in .approve })
        await runtime.start(systemPrompt: "x", goal: "go")
        let result = await runtime.transcript().first { $0.role == .tool }?.content ?? ""
        XCTAssertTrue(result.contains("unknown tool"))
        XCTAssertFalse(result.contains("Did you mean"), "the suggestion is part of the switchable check")
    }
}

final class ModelConnectionTests: XCTestCase {
    private func urlError(_ code: URLError.Code) -> Error { URLError(code) }

    func testConnectionTroubleIsRecognizedIncludingWrappedErrors() {
        for code in [URLError.Code.cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotFindHost, .notConnectedToInternet] {
            XCTAssertTrue(ModelConnection.isConnectionProblem(urlError(code)), "\(code)")
        }
        let wrapped = NSError(domain: "Outer", code: 1, userInfo: [NSUnderlyingErrorKey: urlError(.cannotConnectToHost)])
        XCTAssertTrue(ModelConnection.isConnectionProblem(wrapped))
        XCTAssertFalse(ModelConnection.isConnectionProblem(urlError(.badServerResponse)))
        XCTAssertFalse(ModelConnection.isConnectionProblem(NSError(domain: "x", code: -1004)), "right code, wrong domain")
        XCTAssertFalse(ModelConnection.friendlyMessage(for: urlError(.cannotConnectToHost)).contains("NSURL"))
    }

    private final class Flaky: ModelBackend, @unchecked Sendable {
        let name = "flaky"
        private let lock = NSLock(); private(set) var calls = 0
        let failures: Int; let error: Error
        init(failures: Int, error: Error = URLError(.cannotConnectToHost)) { self.failures = failures; self.error = error }
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            lock.lock(); calls += 1; let n = calls; lock.unlock()
            if n <= failures { throw error }
            return ModelReply(message: ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "finish_task", arguments: ["summary": AnyCodable("all finished here"), "outcome": AnyCodable("done")])]), usage: nil)
        }
    }
    private final class Box: SandboxProvider, @unchecked Sendable {
        let name = "box"
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
        private let lock = NSLock(); private(set) var messages: [String] = []; private(set) var completed = false; private(set) var failed: String?
        func add(_ e: AgentRuntime.Event) {
            lock.lock(); defer { lock.unlock() }
            if case .message(let m) = e, m.isTaskSummary { messages.append(m.content) }
            if case .status(.completed) = e { completed = true }
            if case .status(.failed(let why)) = e { failed = why }
        }
    }

    func testARestartingServerIsWaitedOutAndTheRunCompletes() async {
        let saved = ModelConnection.retryDelays; defer { ModelConnection.retryDelays = saved }
        ModelConnection.retryDelays = [0.01, 0.01, 0.01]
        let model = Flaky(failures: 2); let seen = Seen()
        let runtime = AgentRuntime(model: model, sandbox: Box(), sandboxID: "t", onEvent: { seen.add($0) })
        await runtime.start(systemPrompt: "x", goal: "go")
        XCTAssertTrue(seen.completed, "\(seen.messages)")
        XCTAssertEqual(model.calls, 3)
    }

    func testAServerThatStaysDownGivesOnePlainSentenceNotTheRawError() async {
        let saved = ModelConnection.retryDelays; defer { ModelConnection.retryDelays = saved }
        ModelConnection.retryDelays = [0.01, 0.01, 0.01]
        let model = Flaky(failures: 99); let seen = Seen()
        let runtime = AgentRuntime(model: model, sandbox: Box(), sandboxID: "t", onEvent: { seen.add($0) })
        await runtime.start(systemPrompt: "x", goal: "go")
        XCTAssertEqual(model.calls, 4, "first try + 3 retries")
        XCTAssertFalse(seen.completed)
        let shown = seen.messages.joined(separator: " ")
        XCTAssertTrue(shown.hasPrefix(ModelConnection.unreachablePrefix), shown)
        for noise in ["NSURLErrorDomain", "kCFStream", "127.0.0.1", "UserInfo", "stopped early"] { XCTAssertFalse(shown.contains(noise), noise) }
        XCTAssertEqual(seen.failed, "the model server is unreachable")
    }

    func testOtherErrorsAreNotRetried() async {
        let saved = ModelConnection.retryDelays; defer { ModelConnection.retryDelays = saved }
        ModelConnection.retryDelays = [0.01, 0.01, 0.01]
        let model = Flaky(failures: 99, error: URLError(.badServerResponse)); let seen = Seen()
        let runtime = AgentRuntime(model: model, sandbox: Box(), sandboxID: "t", onEvent: { seen.add($0) })
        await runtime.start(systemPrompt: "x", goal: "go")
        XCTAssertEqual(model.calls, 1)
        XCTAssertTrue(seen.messages.joined().contains("stopped early"))
    }
}

final class SummaryDisplayTests: XCTestCase {
    func testAnswerOnlyInTheSummaryIsShown() {
        XCTAssertFalse(SummaryDisplay.collapses(summary: "Hey! How can I help you today?", shownThisTurn: []))
    }
    func testANarrationStepDoesNotHideTheResult() {
        XCTAssertFalse(SummaryDisplay.collapses(summary: "The kernel is 6.17.0 on Debian 13.", shownThisTurn: ["Let me check that for you."]))
    }
    func testARepeatOfTheShownReplyIsCollapsed() {
        let reply = "The kernel is 6.17.0-1032-oem and the distribution is Debian GNU/Linux 13 (trixie)."
        XCTAssertTrue(SummaryDisplay.collapses(summary: "Kernel 6.17.0-1032-oem on Debian GNU/Linux 13 (trixie).", shownThisTurn: [reply]))
        XCTAssertTrue(SummaryDisplay.collapses(summary: reply, shownThisTurn: [reply]))
    }
}
