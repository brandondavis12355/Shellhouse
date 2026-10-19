import XCTest
@testable import AgentCore

/// Replay-style tests for each guard: a scripted model drives the real runtime and the assertions read the run log
/// (which nudges fired, what the model was shown, how the run ended), plus direct tests of each guard's own state.
final class GuardTests: XCTestCase {
    // MARK: harness

    private final class Box: SandboxProvider, @unchecked Sendable {
        let name = "box"
        let output: @Sendable (String) -> ExecResult
        init(_ output: @escaping @Sendable (String) -> ExecResult) { self.output = output }
        func exec(_ sandboxID: String, command: String, timeout: TimeInterval, env: [String: String]?) async throws -> ExecResult { output(command) }
        func create(taskID: String, persistent: Bool) async throws -> SandboxHandle { SandboxHandle(id: taskID, provider: name, persistent: persistent) }
        func start(_ sandboxID: String) async throws -> SandboxHandle { SandboxHandle(id: sandboxID, provider: name, persistent: true) }
        func readFile(_ sandboxID: String, path: String, maxBytes: Int) async throws -> Data { Data("body of \(path)".utf8) }
        func writeFile(_ sandboxID: String, path: String, contents: Data) async throws {}
        func pause(_ sandboxID: String) async throws {}
        func resume(_ sandboxID: String) async throws {}
        func destroy(_ sandboxID: String) async throws {}
        func health(_ sandboxID: String) async -> Bool { true }
        func reconcile() async throws -> [SandboxHandle] { [] }
        func listSandboxes() async throws -> [SandboxHandle] { [] }
    }

    private final class Replayer: ModelBackend, @unchecked Sendable {
        let name = "replay"
        private let lock = NSLock()
        private var script: [ChatMessage]
        private var count = 0
        init(_ script: [ChatMessage]) { self.script = script }
        var calls: Int { lock.withLock { count } }
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            let next: ChatMessage = lock.withLock {
                count += 1
                return script.isEmpty ? ChatMessage(role: .assistant, content: "", toolCalls: [GuardTests.finish()]) : script.removeFirst()
            }
            return ModelReply(message: next, usage: nil)
        }
    }

    private final class Collector: RunLogSink, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [RunEvent] = []
        private var shown: [ChatMessage] = []
        private var abort: String?
        func write(_ event: RunEvent) { lock.withLock { items.append(event) } }
        func handle(_ event: AgentRuntime.Event) {
            lock.withLock {
                switch event {
                case .message(let message): shown.append(message)
                case .status(.aborted(let why)): abort = why
                default: break
                }
            }
        }
        var events: [RunEvent] { lock.withLock { items } }
        var messages: [ChatMessage] { lock.withLock { shown } }
        var aborted: String? { lock.withLock { abort } }
    }

    private struct Run {
        let collector: Collector
        let transcript: [ChatMessage]
        let modelCalls: Int
        var events: [RunEvent] { collector.events }
        var aborted: String? { collector.aborted }
        /// The kinds of the nudges that fired, in order.
        var nudgeKinds: [String] {
            events.compactMap { if case .nudge(let kind, _, _, _, _) = $0.kind { return kind } else { return nil } }
        }
        var toolResults: [String] {
            events.compactMap { if case .toolResult(_, let content) = $0.kind { return content } else { return nil } }
        }
    }

    private static func finish(_ summary: String = "done") -> ToolCall {
        ToolCall(name: "finish_task", arguments: ["summary": AnyCodable(summary), "outcome": AnyCodable("done")])
    }
    private func shell(_ command: String) -> ToolCall { ToolCall(name: "run_shell", arguments: ["command": AnyCodable(command)]) }
    private func calls(_ calls: ToolCall...) -> ChatMessage { ChatMessage(role: .assistant, content: "", toolCalls: calls) }
    private func say(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, content: text) }

    private func replay(_ script: [ChatMessage], maxIterations: Int = 15, budgets: AgentRuntime.Budgets? = nil, plainReplyEndsTurn: Bool = false,
                        seen: SeenResults = SeenResults(),
                        exec: @escaping @Sendable (String) -> ExecResult = { _ in ExecResult(exitCode: 0, stdout: "ok", stderr: "") }) async -> Run {
        let collector = Collector()
        let model = Replayer(script)
        let runtime = AgentRuntime(
            model: model, sandbox: Box(exec), sandboxID: "t", budgets: budgets ?? AgentRuntime.Budgets(maxIterations: maxIterations),
            onEvent: { collector.handle($0) }, requestApproval: { _ in .approve },
            plainReplyEndsTurn: plainReplyEndsTurn, seenResults: seen, runLogSink: collector
        )
        await runtime.start(systemPrompt: "system", goal: "do the task")
        return Run(collector: collector, transcript: await runtime.transcript(), modelCalls: model.calls)
    }

    private func counts() -> [String: Int] { Telemetry.recorder.loopEventCounts() }

    // MARK: pipeline

    func testGuardsRunInOneFixedOrder() {
        XCTAssertEqual(GuardSet.standard().map(\.id), [
            "context_budget", "tool_call_recovery", "narration", "repeated_calls", "tool_validation", "memory_write_gate", "trash_warning",
            "same_error", "failure_streak", "stale_results", "unverified_change", "empty_summary", "open_plan",
        ])
    }

    func testTheSameScriptReplaysToTheSameLog() async {
        let script = [say("Let me check the files."), calls(shell("ls")), calls(shell("ls")), calls(shell("ls"))]
        let a = await replay(script), b = await replay(script)
        XCTAssertEqual(a.nudgeKinds, b.nudgeKinds)
        XCTAssertEqual(a.transcript.map(\.content), b.transcript.map(\.content))
    }

    // MARK: narration

    func testAnnouncementIsNudgedAndLeftOutOfThePrompt() async {
        let before = counts()
        let run = await replay([say("Let me read the file now."), say("Let me read the file now."), calls(shell("ls"))])
        XCTAssertEqual(Array(run.nudgeKinds.prefix(3)), ["narration_dropped", "narration", "narration_dropped"])
        XCTAssertTrue(run.nudgeKinds.contains("narration_escalated"), "the second miss names the tools: \(run.nudgeKinds)")
        XCTAssertFalse(run.transcript.contains { $0.role == .assistant && $0.content == "Let me read the file now." })
        XCTAssertEqual((counts()["narration"] ?? 0) - (before["narration"] ?? 0), 1)
        XCTAssertEqual((counts()["narration_escalated"] ?? 0) - (before["narration_escalated"] ?? 0), 1)
    }

    func testAnnouncementRepeatedNextToTheCallIsShownOnce() async {
        let run = await replay([say("Let me list the files."),
                                ChatMessage(role: .assistant, content: "Let me list the files.", toolCalls: [shell("ls")])])
        let withCall = run.collector.messages.filter { $0.role == .assistant && !($0.toolCalls ?? []).isEmpty }
        XCTAssertEqual(withCall.first?.content, "", "the repeated sentence is not shown a second time")
    }

    func testRepliesWithoutAToolEndTheRunAtTheFifth() async {
        let run = await replay(Array(repeating: say("ok."), count: 8))
        XCTAssertEqual(run.aborted, "kept replying in plain text without using a tool or finishing")
        XCTAssertTrue(run.nudgeKinds.contains("missing_tool"))
        XCTAssertTrue(run.events.contains { if case .nudge(_, let text, _, _, _) = $0.kind { return text.contains("three times without calling a tool") } else { return false } },
                      "the third miss gets the stuck detector's wording")
        XCTAssertEqual(run.modelCalls, 5)
    }

    func testARealAnswerEndsAChatTurn() async {
        let run = await replay([say("The answer is forty-two, as computed above.")], plainReplyEndsTurn: true)
        XCTAssertEqual(run.modelCalls, 1)
        XCTAssertTrue(run.nudgeKinds.isEmpty)
    }

    func testCallsThatDidNotRunAreNudged() async {
        let run = await replay([calls(ToolCall(name: "launch_missiles", arguments: [:]))])
        XCTAssertEqual(run.nudgeKinds.filter { $0 == "calls_not_run" }.count, 1)
        XCTAssertTrue(run.nudgeKinds.contains("unknown_tool"))
    }

    func testNarrationGuardCountsOnlyRepliesInARow() {
        let narration = NarrationGuard()
        let ctx = RunContext()
        let plain = ModelReply(message: ChatMessage(role: .assistant, content: "ok."), usage: nil)
        for _ in 0..<2 { _ = narration.afterReply(plain, cutOff: false, ctx) }
        _ = narration.afterTool(ToolCall(name: "run_shell", arguments: [:]), ToolOutcome(kind: .executed(isObservation: true), raw: [:], shown: [:]), ctx)
        for _ in 0..<2 {
            let actions = narration.afterReply(plain, cutOff: false, ctx)
            XCTAssertFalse(actions.contains { if case .abort = $0 { return true } else { return false } })
        }
    }

    func testAReplyCutForRepeatingItselfGetsItsOwnNudge() {
        let narration = NarrationGuard()
        let actions = narration.afterReply(ModelReply(message: say("x"), usage: nil), cutOff: true, RunContext())
        guard case .nudge(let nudge) = actions.first else { return XCTFail("a nudge") }
        XCTAssertEqual(nudge.kind, "repetition_cut")
    }

    // MARK: repeated calls

    func testSameCallRepeatedIsNudgedThenStopped() async {
        let long = String(repeating: "x", count: 500)
        let run = await replay(Array(repeating: calls(shell("ls /workspace")), count: 6), exec: { _ in ExecResult(exitCode: 0, stdout: long, stderr: "") })
        XCTAssertEqual(run.aborted, "repeated the same 'run_shell' call too many times")
        XCTAssertTrue(run.nudgeKinds.contains("repeat_call"))
        XCTAssertTrue(run.nudgeKinds.contains("repeat_call_last"))
        XCTAssertTrue(run.nudgeKinds.contains("unchanged_result"), "the same answer is not pasted into the prompt again")
        XCTAssertTrue(run.transcript.contains { $0.role == .tool && $0.content.contains("\"unchanged\":true") })
    }

    func testTheSameCallTwiceInOneReplyRunsOnce() async {
        let run = await replay([calls(shell("ls /a"), shell("ls /a"))])
        XCTAssertEqual(run.toolResults.filter { $0.contains("Duplicate of an identical call") }.count, 1)
        XCTAssertTrue(run.nudgeKinds.contains("duplicate_call"))
    }

    func testIdenticalResultsInARowGetOneNudge() async {
        let run = await replay([calls(shell("echo a")), calls(shell("echo b")), calls(shell("echo c"))],
                               exec: { _ in ExecResult(exitCode: 0, stdout: "same", stderr: "") })
        XCTAssertEqual(run.nudgeKinds.filter { $0 == "same_result" }.count, 1)
    }

    func testAlternatingBetweenTwoActionsIsNoticed() {
        let repeated = RepeatedCallsGuard()
        var kinds: [String] = []
        var abort: String?
        for i in 0..<8 {
            let call = ToolCall(name: "run_shell", arguments: ["command": AnyCodable(i % 2 == 0 ? "cat a" : "cat b")])
            // Results differ each time so only the pattern, not the content, repeats.
            let outcome = ToolOutcome(kind: .executed(isObservation: true), raw: ["stdout": "r\(i)"], shown: ["stdout": "r\(i)"])
            _ = repeated.beforeTool(call, RunContext())
            for action in repeated.afterTool(call, outcome, RunContext()) {
                if case .nudge(let nudge) = action { kinds.append(nudge.kind) }
                if case .abort(let why) = action { abort = why }
            }
        }
        XCTAssertTrue(kinds.contains("alternating"))
        XCTAssertEqual(abort, "alternated between the same two actions without making progress")
    }

    // MARK: same error, failures

    private func failed(_ error: String) -> ToolOutcome {
        ToolOutcome(kind: .executed(isObservation: false), raw: ["exit_code": 1, "stderr": error], shown: ["exit_code": 1, "stderr": error])
    }

    func testSameErrorIsNamedOnTheThird() {
        let guardian = SameErrorGuard()
        let call = ToolCall(name: "run_shell", arguments: [:])
        XCTAssertTrue(guardian.afterTool(call, failed("boom at line 3"), RunContext()).isEmpty)
        XCTAssertTrue(guardian.afterTool(call, failed("boom at line 4"), RunContext()).isEmpty, "numbers don't make an error different")
        guard case .nudge(let nudge)? = guardian.afterTool(call, failed("boom at line 5"), RunContext()).first else { return XCTFail("nudge") }
        XCTAssertTrue(nudge.text.contains("failed 3 times with the same error"))
        XCTAssertTrue(guardian.afterTool(call, failed("boom at line 6"), RunContext()).isEmpty, "named once")
        guardian.reset(.turn)
        XCTAssertTrue(guardian.afterTool(call, failed("boom"), RunContext()).isEmpty, "a new turn starts the count over")
    }

    func testFailureStreakStopsTheRunAtTheThirdIdenticalFailure() {
        let guardian = FailureStreakGuard()
        let call = ToolCall(name: "run_shell", arguments: [:])
        var verdicts: [String] = []
        for _ in 0..<3 {
            for action in guardian.afterTool(call, failed("No such file or directory"), RunContext()) {
                switch action {
                case .nudge(let nudge): verdicts.append("nudge:" + nudge.kind)
                case .abort: verdicts.append("abort")
                default: break
                }
            }
        }
        XCTAssertEqual(verdicts, ["nudge:failure_stop", "abort"])
    }

    func testASuccessClearsTheFailureStreak() {
        let guardian = FailureStreakGuard()
        let call = ToolCall(name: "run_shell", arguments: [:])
        _ = guardian.afterTool(call, failed("x"), RunContext())
        _ = guardian.afterTool(call, ToolOutcome(kind: .executed(isObservation: true), raw: ["stdout": "fine"], shown: ["stdout": "fine"]), RunContext())
        XCTAssertTrue(guardian.afterTool(call, failed("x"), RunContext()).isEmpty, "the count started over")
    }

    func testARefusedCallCountsAsAFailure() {
        let guardian = FailureStreakGuard()
        let call = ToolCall(name: "run_shell", arguments: [:])
        let refused = ToolOutcome(kind: .refused, raw: ["error": "blocked: not allowed"], shown: ["error": "blocked: not allowed"])
        guard case .nudge(let nudge)? = guardian.afterTool(call, refused, RunContext()).first else { return XCTFail("nudge") }
        XCTAssertEqual(nudge.kind, "blocked")
    }

    // MARK: stale results

    func testStaleResultsNudgeAtFourAndStopAtSeven() {
        let guardian = StaleResultsGuard(seen: SeenResults())
        let call = ToolCall(name: "run_shell", arguments: [:])
        let text = String(repeating: "waiting for review ", count: 4)
        let outcome = ToolOutcome(kind: .executed(isObservation: true), raw: ["stdout": text], shown: ["stdout": text])
        var firstNudge: Int?, firstAbort: Int?
        for step in 1...9 {
            for action in guardian.afterTool(call, outcome, RunContext()) {
                if case .nudge = action, firstNudge == nil { firstNudge = step }
                if case .abort = action, firstAbort == nil { firstAbort = step }
            }
        }
        XCTAssertEqual(firstNudge, StaleResultsGuard.nudgeAt + 1, "the first sight doesn't count")
        XCTAssertEqual(firstAbort, StaleResultsGuard.abortAt + 1)
    }

    func testStaleResultsIgnoreTinyAndWriteResults() {
        let guardian = StaleResultsGuard(seen: SeenResults())
        for _ in 0..<10 {
            XCTAssertTrue(guardian.afterTool(ToolCall(name: "write_file", arguments: [:]),
                                             ToolOutcome(kind: .executed(isObservation: false), raw: ["ok": true], shown: [:]), RunContext()).isEmpty)
            XCTAssertFalse(guardian.lastWasSeen)
        }
    }

    func testStaleResultsAreSharedAcrossRunsThroughSeenResults() async {
        let seen = SeenResults()
        let text = "the very same long answer about the build state, repeated again and again"
        let exec: @Sendable (String) -> ExecResult = { _ in ExecResult(exitCode: 0, stdout: text, stderr: "") }
        _ = await replay([calls(shell("ls /d1"))], seen: seen, exec: exec)
        let second = await replay([calls(shell("ls /d2")), calls(shell("ls /d3")), calls(shell("ls /d4")), calls(shell("ls /d5")), calls(shell("ls /d6"))], seen: seen, exec: exec)
        XCTAssertTrue(second.nudgeKinds.contains("stale_results"), "\(second.nudgeKinds)")
    }

    // MARK: finish gates

    func testFinishIsRefusedOnceWhileThePlanIsOpen() async {
        let plan = ToolCall(name: "update_plan", arguments: ["steps": AnyCodable([["text": "do it", "status": "pending"]])])
        let run = await replay([calls(plan), calls(GuardTests.finish()), calls(GuardTests.finish())])
        XCTAssertEqual(run.nudgeKinds.filter { $0 == "open_plan" }.count, 1)
        XCTAssertTrue(run.toolResults.contains { $0.contains("Not finished: your plan still has open steps") })
        XCTAssertEqual(run.modelCalls, 3, "the second attempt goes through")
    }

    func testBlockedFinishIsNotHeldByTheOpenPlan() {
        let guardian = OpenPlanGuard()
        var ctx = RunContext()
        ctx.plan = [AgentRuntime.PlanItem(text: "x", status: .pending)]
        XCTAssertTrue(guardian.beforeFinish(FinishRequest(summary: "s", outcome: "blocked", callCount: 1), ctx).isEmpty)
        XCTAssertTrue(guardian.beforeFinish(FinishRequest(summary: "s", outcome: "done", callCount: 2), ctx).isEmpty, "only a lone finish call")
        XCTAssertFalse(guardian.beforeFinish(FinishRequest(summary: "s", outcome: "done", callCount: 1), ctx).isEmpty)
        XCTAssertTrue(guardian.beforeFinish(FinishRequest(summary: "s", outcome: "done", callCount: 1), ctx).isEmpty, "once")
        guardian.reset(.turn)
        XCTAssertFalse(guardian.beforeFinish(FinishRequest(summary: "s", outcome: "done", callCount: 1), ctx).isEmpty, "a new turn asks again")
    }

    func testChangedCodeWithNothingRunBouncesTheFinishOnce() {
        let guardian = UnverifiedChangeGuard()
        let write = ToolCall(name: "write_file", arguments: ["path": AnyCodable("/workspace/app.swift")])
        let ok = ToolOutcome(kind: .executed(isObservation: false), raw: ["ok": true], shown: ["ok": true])
        let finish = FinishRequest(summary: "s", outcome: "done", callCount: 1)
        _ = guardian.afterTool(write, ok, RunContext())
        XCTAssertFalse(guardian.beforeFinish(finish, RunContext()).isEmpty)
        XCTAssertTrue(guardian.beforeFinish(finish, RunContext()).isEmpty, "asked once")
        guardian.reset(.turn)
        _ = guardian.afterTool(write, ok, RunContext())
        _ = guardian.afterTool(ToolCall(name: "run_shell", arguments: [:]), ok, RunContext())
        XCTAssertTrue(guardian.beforeFinish(finish, RunContext()).isEmpty, "running something clears it")
    }

    func testProseFilesAndFailedWritesDoNotNeedChecking() {
        let guardian = UnverifiedChangeGuard()
        let ok = ToolOutcome(kind: .executed(isObservation: false), raw: ["ok": true], shown: [:])
        _ = guardian.afterTool(ToolCall(name: "write_file", arguments: ["path": AnyCodable("notes.md")]), ok, RunContext())
        _ = guardian.afterTool(ToolCall(name: "write_file", arguments: ["path": AnyCodable("a.py")]),
                               ToolOutcome(kind: .executed(isObservation: false), raw: ["error": "denied"], shown: [:]), RunContext())
        XCTAssertTrue(guardian.beforeFinish(FinishRequest(summary: "s", outcome: "done", callCount: 1), RunContext()).isEmpty)
    }

    func testFinishNeedsASummary() async {
        let empty = ToolCall(name: "finish_task", arguments: ["summary": AnyCodable(""), "outcome": AnyCodable("done")])
        let run = await replay([calls(empty)])
        XCTAssertTrue(run.nudgeKinds.contains("empty_summary"))
        XCTAssertEqual(run.modelCalls, 2)
    }

    // MARK: tool-call recovery and validation

    func testACallWrittenAsTextIsMadeAsTheCallItMeant() async {
        let run = await replay([say(#"{"name":"run_shell","arguments":{"command":"ls /workspace"}}"#)])
        XCTAssertTrue(run.toolResults.contains { $0.contains("ok") }, "the command ran: \(run.toolResults)")
        XCTAssertTrue(run.collector.messages.contains { $0.role == .assistant && ($0.toolCalls ?? []).first?.name == "run_shell" })
    }

    func testRecoveryLeavesProseAndCutRepliesAlone() {
        let recovery = ToolCallRecoveryGuard()
        var ctx = RunContext()
        ctx.toolNames = ["run_shell"]
        let prose = ModelReply(message: say("The config looks like {\"debug\": true}."), usage: nil)
        XCTAssertTrue(recovery.afterReply(prose, cutOff: false, ctx).isEmpty)
        let text = ModelReply(message: say(#"{"name":"run_shell","arguments":{"command":"ls"}}"#), usage: nil)
        XCTAssertEqual(recovery.afterReply(text, cutOff: false, ctx).count, 1)
        XCTAssertTrue(recovery.afterReply(text, cutOff: true, ctx).isEmpty)
    }

    func testAMisspelledToolGetsAPreciseCorrection() async {
        let run = await replay([calls(ToolCall(name: "run_shel", arguments: ["command": AnyCodable("ls")]))])
        XCTAssertTrue(run.toolResults.contains { $0.contains("Did you mean 'run_shell'") }, "\(run.toolResults)")
        XCTAssertTrue(run.nudgeKinds.contains("unknown_tool"))
    }

    func testAShellSyntaxErrorIsCaughtBeforeItRuns() async {
        let run = await replay([calls(shell("echo \"unterminated"))])
        XCTAssertTrue(run.nudgeKinds.contains("shell_lint"), "\(run.nudgeKinds)")
    }

    // MARK: trash

    func testResultsFromTheTrashCarryAWarning() async {
        let run = await replay([calls(shell("ls /workspace/.shellhouse/trash/2026-10-15/workspace"))])
        XCTAssertTrue(run.toolResults.contains { $0.contains("in the trash") })
        XCTAssertTrue(run.nudgeKinds.contains("trash_warning"))
    }

    func testTheTrashGuardOnlyAddsAWarningWhereThereIsNone() {
        let guardian = TrashWarningGuard()
        let call = shell("cat /workspace/.shellhouse/trash/x/file")  // the slashes are escaped in JSON
        let plain = ToolOutcome(kind: .executed(isObservation: true), raw: [:], shown: ["stdout": "x"])
        XCTAssertEqual(guardian.afterTool(call, plain, RunContext()).count, 1)
        let warned = ToolOutcome(kind: .executed(isObservation: true), raw: [:], shown: ["warning": "already"])
        XCTAssertTrue(guardian.afterTool(call, warned, RunContext()).isEmpty)
        XCTAssertTrue(guardian.afterTool(shell("ls"), plain, RunContext()).isEmpty)
    }

    // MARK: context budget

    func testStepWarningsComeOncePerThreshold() {
        let guardian = ContextBudgetGuard()
        var ctx = RunContext()
        ctx.maxIterations = 20
        var kinds: [String] = []
        for iteration in 1...20 {
            ctx.iteration = iteration
            for case .nudge(let nudge) in guardian.beforeModel(ctx) where nudge.kind == "budget_warning" { kinds.append("\(iteration)") }
        }
        XCTAssertEqual(kinds, ["15", "18"], "at 75% and at 90%")
        guardian.reset(.run)
        ctx.iteration = 15
        XCTAssertFalse(guardian.beforeModel(ctx).isEmpty, "a new run warns again")
    }

    func testTheTaskIsRestatedEveryFifthStepWithThePlan() {
        let guardian = ContextBudgetGuard()
        var ctx = RunContext()
        ctx.maxIterations = 40
        ctx.goal = "ship the thing"
        ctx.plan = [AgentRuntime.PlanItem(text: "write it", status: .in_progress)]
        ctx.iteration = 4
        XCTAssertTrue(guardian.beforeModel(ctx).isEmpty)
        ctx.iteration = 5
        guard case .nudge(let nudge)? = guardian.beforeModel(ctx).first else { return XCTFail("reminder") }
        XCTAssertEqual(nudge.kind, "reminder")
        XCTAssertTrue(nudge.text.contains("ship the thing") && nudge.text.contains("[~] write it"))
    }

    func testContextOverTheLimitAsksForCondensing() {
        let guardian = ContextBudgetGuard()
        var ctx = RunContext()
        ctx.maxIterations = 40
        ctx.iteration = 2
        ctx.compactionThresholdTokens = 500
        ctx.messages = [ChatMessage(role: .system, content: "s"), ChatMessage(role: .user, content: String(repeating: "x", count: 4_000))]
        XCTAssertTrue(guardian.beforeModel(ctx).contains { if case .condense = $0 { return true } else { return false } })
        // Condensed a moment ago and not near the window itself: let the bot work a few steps first.
        ctx.lastCompactionMessageCount = 2
        XCTAssertFalse(guardian.beforeModel(ctx).contains { if case .condense = $0 { return true } else { return false } })
    }

    func testARunOverTheLimitCondensesItsOldOutputInTheLog() async {
        let big = String(repeating: "data ", count: 700)
        var script: [ChatMessage] = []
        for i in 0..<8 { script.append(calls(shell("cat file\(i)"))) }
        let run = await replay(script, budgets: AgentRuntime.Budgets(maxIterations: 20, compactionThresholdTokens: 2_000),
                               exec: { _ in ExecResult(exitCode: 0, stdout: big + UUID().uuidString, stderr: "") })
        let condensed = run.events.filter { if case .condensed = $0.kind { return true } else { return false } }
        XCTAssertFalse(condensed.isEmpty, "old output was stubbed through events, not by editing")
        XCTAssertTrue(run.transcript.contains { $0.content.hasPrefix("[earlier output") })
        XCTAssertEqual(run.events.filter { if case .toolResult(_, let c) = $0.kind { return c.hasPrefix("[earlier output") } else { return false } }.count, 0,
                       "the log still has every result in full")
    }

    // MARK: every firing is counted

    func testEveryFiringIsANudgeEventAndALoopCounter() async {
        let before = counts()
        let run = await replay([calls(shell("ls /a"), shell("ls /a"))])
        let fired = run.nudgeKinds.filter { $0 != "narration_dropped" }
        XCTAssertFalse(fired.isEmpty)
        for kind in Set(fired) {
            XCTAssertGreaterThanOrEqual((counts()[kind] ?? 0) - (before[kind] ?? 0), fired.filter { $0 == kind }.count, kind)
        }
    }
}
