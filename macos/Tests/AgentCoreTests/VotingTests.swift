import XCTest
@testable import AgentCore

final class VotingTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "voting-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: gate votes

    func testGateVotesDefaultToThreeAndStayOdd() {
        let d = defaults()
        XCTAssertEqual(GateVote.samples(defaults: d), 3)
        d.set(1, forKey: GateVote.samplesKey); XCTAssertEqual(GateVote.samples(defaults: d), 1, "1 turns voting off")
        d.set(4, forKey: GateVote.samplesKey); XCTAssertEqual(GateVote.samples(defaults: d), 5, "no exact ties")
        d.set(99, forKey: GateVote.samplesKey); XCTAssertEqual(GateVote.samples(defaults: d), 7)
        d.set(0, forKey: GateVote.samplesKey); XCTAssertEqual(GateVote.samples(defaults: d), 1)
    }

    func testTallyTakesTheMajorityAndIgnoresFailures() {
        XCTAssertEqual(GateVote.tally([true, true, false]).answer, true)
        XCTAssertEqual(GateVote.tally([false, true, false]).answer, false)
        XCTAssertEqual(GateVote.tally([nil, true, nil]).answer, true, "one answer is still an answer")
        XCTAssertTrue(GateVote.tally([true, true, true]).unanimous)
        XCTAssertFalse(GateVote.tally([true, false, true]).unanimous)
    }

    func testATieOrNoAnswersLeavesTheDecisionToTheCaller() {
        XCTAssertNil(GateVote.tally([true, false, nil]).answer)
        XCTAssertNil(GateVote.tally([nil, nil, nil]).answer)
        XCTAssertNil(GateVote.tally([]).answer)
    }

    func testTheFirstVoterIsGreedyAndTheOthersAreSampled() async {
        final class Seen: @unchecked Sendable {
            private let lock = NSLock(); private var items: [Int: Double] = [:]
            func note(_ voter: Int, _ t: Double) { lock.withLock { items[voter] = t } }
            var all: [Int: Double] { lock.withLock { items } }
        }
        let seen = Seen()
        let result = await GateVote.decide(count: 3) { voter, temperature in seen.note(voter, temperature); return voter == 0 ? false : true }
        XCTAssertEqual(seen.all[0], 0)
        XCTAssertEqual(seen.all[1], GateVote.temperature)
        XCTAssertEqual(seen.all[2], GateVote.temperature)
        XCTAssertEqual(result.answer, true)
        XCTAssertEqual(result.yes, 2); XCTAssertEqual(result.no, 1)
    }

    func testVotesAreCountedInTelemetry() async {
        let before = Telemetry.recorder.loopEventCounts()
        _ = await GateVote.decide(count: 3) { _, _ in true }
        _ = await GateVote.decide(count: 3) { voter, _ in voter == 1 }
        _ = await GateVote.decide(count: 3) { _, _ in nil }
        let after = Telemetry.recorder.loopEventCounts()
        for kind in ["gate_vote_unanimous", "gate_vote_split", "gate_vote_failed"] {
            XCTAssertEqual((after[kind] ?? 0) - (before[kind] ?? 0), 1, kind)
        }
    }

    // MARK: action votes

    private func reply(_ command: String) -> ModelReply {
        ModelReply(message: ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "run_shell", arguments: ["command": AnyCodable(command)])]), usage: nil)
    }
    private var finish: ModelReply {
        ModelReply(message: ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "finish_task", arguments: ["summary": AnyCodable("s"), "outcome": AnyCodable("blocked")])]), usage: nil)
    }
    private var text: ModelReply { ModelReply(message: ChatMessage(role: .assistant, content: "Let me look."), usage: nil) }

    func testActionVoteOffByDefault() {
        let d = defaults()
        XCTAssertEqual(ActionVote.samples(defaults: d), 1)
        d.set(3, forKey: ActionVote.samplesKey)
        XCTAssertEqual(ActionVote.samples(defaults: d), 3)
    }

    func testAStrictMajorityOfFirstActionsWins() {
        XCTAssertEqual(ActionVote.pick([reply("ls /a"), reply("pwd"), reply("pwd")]), 1)
        XCTAssertEqual(ActionVote.pick([finish, reply("pwd"), finish]), 0)
        XCTAssertEqual(ActionVote.pick([text, reply("pwd"), text]), 0)
    }

    func testWithoutAMajorityTheFirstReplyStands() {
        XCTAssertEqual(ActionVote.pick([reply("ls /a"), reply("pwd"), finish]), 0)
        XCTAssertEqual(ActionVote.pick([reply("ls /a")]), 0)
    }

    func testCosmeticDifferencesDoNotSplitTheVote() {
        // `| head` and echo labels are the same action to the repeat detector, and to the vote.
        XCTAssertEqual(ActionVote.pick([reply("ls /a"), reply("ls /b"), reply("ls /b | head -5")]), 1)
    }

    // MARK: through the runtime

    private final class Box: SandboxProvider, @unchecked Sendable {
        let name = "box"
        func exec(_ sandboxID: String, command: String, timeout: TimeInterval, env: [String: String]?) async throws -> ExecResult {
            ExecResult(exitCode: 0, stdout: "out of \(command)", stderr: "")
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

    /// Main steps come from `main`; sampled ones (temperature above 0.5) from `sampled`.
    private final class TwoQueues: ModelBackend, @unchecked Sendable {
        let name = "two"
        private let lock = NSLock()
        private var main: [ChatMessage], sampled: [ChatMessage]
        private(set) var sampledCalls = 0
        init(main: [ChatMessage], sampled: [ChatMessage]) { self.main = main; self.sampled = sampled }
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            let next: ChatMessage = lock.withLock {
                if temperature > 0.5 {
                    sampledCalls += 1
                    return sampled.isEmpty ? ChatMessage(role: .assistant, content: "") : sampled.removeFirst()
                }
                return main.isEmpty ? ChatMessage(role: .assistant, content: "", toolCalls: [GuardTests_finish()]) : main.removeFirst()
            }
            return ModelReply(message: next, usage: nil)
        }
    }

    private final class Sink: RunLogSink, @unchecked Sendable {
        private let lock = NSLock(); private var items: [RunEvent] = []
        func write(_ event: RunEvent) { lock.withLock { items.append(event) } }
        var events: [RunEvent] { lock.withLock { items } }
    }

    private func run(votes: Int) async -> (events: [RunEvent], transcript: [ChatMessage], sampledCalls: Int) {
        func call(_ command: String) -> ChatMessage {
            ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "run_shell", arguments: ["command": AnyCodable(command)])])
        }
        func say(_ t: String) -> ChatMessage { ChatMessage(role: .assistant, content: t) }
        // Three steps with nothing in them, so the no-progress nudge fires; then the main sample picks `ls /x`
        // while two sampled ones agree on `pwd`.
        let model = TwoQueues(main: [say("Let me look."), say("Let me look at it."), say("Let me check."), call("ls /x")], sampled: [call("pwd"), call("pwd")])
        let sink = Sink()
        let runtime = AgentRuntime(model: model, sandbox: Box(), sandboxID: "t", budgets: AgentRuntime.Budgets(maxIterations: 12),
                                   requestApproval: { _ in .approve }, runLogSink: sink, actionVotes: votes)
        await runtime.start(systemPrompt: "system", goal: "do the task")
        return (sink.events, await runtime.transcript(), model.sampledCalls)
    }

    func testTheStepAfterNoProgressIsDecidedByVoteWhenItIsOn() async {
        let r = await run(votes: 3)
        XCTAssertEqual(r.sampledCalls, 2)
        XCTAssertTrue(r.events.contains { if case .nudge(let kind, _, _, _, _) = $0.kind { return kind == "no_progress" } else { return false } })
        let commands = r.transcript.compactMap { $0.toolCalls?.first?.arguments["command"]?.asString }
        XCTAssertEqual(commands.first, "pwd", "two of three chose pwd")
        XCTAssertTrue(r.events.contains { if case .stateNote(let note) = $0.kind { return note.contains("2 of 3") } else { return false } })
    }

    func testNothingIsSampledWhenVotingIsOff() async {
        let r = await run(votes: 1)
        XCTAssertEqual(r.sampledCalls, 0)
        let commands = r.transcript.compactMap { $0.toolCalls?.first?.arguments["command"]?.asString }
        XCTAssertEqual(commands.first, "ls /x")
    }
}

private func GuardTests_finish() -> ToolCall {
    ToolCall(name: "finish_task", arguments: ["summary": AnyCodable("done"), "outcome": AnyCodable("done")])
}
