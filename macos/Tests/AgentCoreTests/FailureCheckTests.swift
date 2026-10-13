import XCTest
@testable import AgentCore

final class FailureCheckTests: XCTestCase {
    func testKinds() {
        XCTAssertEqual(FailureCheck.kind(["exit_code": 0, "stdout": "ok", "stderr": ""]), .ok)
        XCTAssertEqual(FailureCheck.kind(["exit_code": 1, "stdout": "", "stderr": "make: *** [all] Error 2"]), .failed)
        XCTAssertEqual(FailureCheck.kind(["exit_code": 0, "stdout": "fatal: x", "warning": "exit_code is 0, but…"]), .failed)
        XCTAssertEqual(FailureCheck.kind(["error": "blocked by guardrails: recursive delete."]), .hard)
        XCTAssertEqual(FailureCheck.kind(["error": "denied by user"]), .hard)
        XCTAssertEqual(FailureCheck.kind(["exit_code": 128, "stdout": "fatal: could not read Username for 'https://github.com'", "stderr": ""]), .hard)
    }

    func testNoticeTellsTheBotToStopAndReport() {
        XCTAssertTrue(FailureCheck.stopNotice.contains("finish_task"))
        XCTAssertTrue(FailureCheck.stopNotice.contains("request_credentials"))
    }
}

final class ProposeGoalTaintTests: XCTestCase {
    func testProposeGoalRunsWithoutApprovalInUntrustedRuns() {
        let classification = ActionClassifier.classify(tool: "propose_goal", arguments: [:])
        XCTAssertEqual(classification.verdict(tainted: true), .allow)
        XCTAssertEqual(ActionClassifier.classify(tool: "add_goal_step", arguments: [:]).verdict(tainted: true), .ask)
    }
}
