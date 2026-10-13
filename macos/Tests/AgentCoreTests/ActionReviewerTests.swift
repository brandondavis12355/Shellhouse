import XCTest
@testable import AgentCore

final class ActionReviewerTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        var reviews = 0
        var approvals: [Approval] = []
    }

    private func gate(taint: [TaintSource] = [], review: ActionReview?, recorder: Recorder) -> ToolGate {
        ToolGate(sandboxID: "t", sandbox: NullBox(), permissions: RunShellPermissions(), config: GuardrailConfig(), limits: RunLimits(),
                 audit: nil, inbox: nil, initialTaint: taint, friendSafeTools: [],
                 reviewer: { _ in recorder.reviews += 1; return review },
                 requestApproval: { approval in recorder.approvals.append(approval); return .approve }, onEvent: { _ in })
    }

    private func shell(_ command: String, secrets: [String] = []) -> ToolCall {
        var args: [String: AnyCodable] = ["command": AnyCodable(command)]
        if !secrets.isEmpty { args["use_secrets"] = AnyCodable(secrets) }
        return ToolCall(name: "run_shell", arguments: args)
    }

    func testApprovedRoutineActionRunsWithoutAskingTheUser() async {
        let recorder = Recorder()
        let outcome = await gate(review: ActionReview(approve: true, reason: "runs the tests"), recorder: recorder).evaluate(shell("pytest -q"))
        guard case .run(_, let asked) = outcome else { return XCTFail("expected run, got \(outcome)") }
        XCTAssertFalse(asked)
        XCTAssertEqual(recorder.reviews, 1)
    }

    func testReviewerDoubtGoesToTheUserWithItsReason() async {
        let recorder = Recorder()
        _ = await gate(review: ActionReview(approve: false, reason: "uploads a file"), recorder: recorder).evaluate(shell("pytest -q"))
        XCTAssertEqual(recorder.approvals.count, 1)
        XCTAssertTrue(recorder.approvals.first?.reasons.first?.contains("uploads a file") == true)
    }

    func testStrictAsksAndFriendsNeverReachTheReviewer() async {
        let strict = Recorder()
        _ = await gate(review: ActionReview(approve: true, reason: ""), recorder: strict).evaluate(shell("echo hi", secrets: ["API_KEY"]))
        XCTAssertEqual(strict.reviews, 0)
        XCTAssertEqual(strict.approvals.count, 1)

        let friend = Recorder()
        _ = await gate(taint: [.friendMessage], review: ActionReview(approve: true, reason: ""), recorder: friend).evaluate(shell("pytest -q"))
        XCTAssertEqual(friend.reviews, 0)
        XCTAssertEqual(friend.approvals.count, 1)
    }

    func testUnavailableReviewAsksTheUser() async {
        let recorder = Recorder()
        _ = await gate(review: nil, recorder: recorder).evaluate(shell("pytest -q"))
        XCTAssertEqual(recorder.approvals.count, 1)
    }

    func testParseIsStrict() {
        XCTAssertEqual(ActionReviewPrompt.parse(#"{"decision":"allow","reason":"ok"}"#), ActionReview(approve: true, reason: "ok"))
        XCTAssertEqual(ActionReviewPrompt.parse(#"<think>x</think>{"decision":"ask","reason":"r"}"#)?.approve, false)
        XCTAssertNil(ActionReviewPrompt.parse("sure, allow it"))
        XCTAssertEqual(ActionReviewPrompt.parse(#"{"decision":"maybe","reason":""}"#)?.approve, false)
    }

    private final class NullBox: SandboxProvider, @unchecked Sendable {
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
}
