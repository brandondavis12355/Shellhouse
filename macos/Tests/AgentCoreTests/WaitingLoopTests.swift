import XCTest
@testable import AgentCore

/// From a run where three bots spent half an hour re-fetching and re-reading while waiting on each other.
final class WaitingLoopTests: XCTestCase {
    func testSeenResultsRemembersAcrossCallsAndForgetsLater() {
        let seen = SeenResults(lifetime: 60)
        let now = Date()
        XCTAssertFalse(seen.saw("git|main prism-tests", now: now))
        XCTAssertTrue(seen.saw("git|main prism-tests", now: now.addingTimeInterval(30)), "a later run sees it again")
        XCTAssertFalse(seen.saw("git|main prism-tests", now: now.addingTimeInterval(200)), "old enough to count as new")
    }

    func testSummaryLosesThinking() {
        XCTAssertEqual(ContextBudget.cleanSummary("<think>hmm</think>\nGOAL: ship"), "GOAL: ship")
        XCTAssertEqual(ContextBudget.cleanSummary("GOAL: a\nOPEN: b\n</think>\n\nGOAL: ship"), "GOAL: ship")
        XCTAssertEqual(ContextBudget.cleanSummary("GOAL: ship"), "GOAL: ship")
    }

    func testRecordingTheSameBlockAgainIsRejected() {
        var g = GroupGoal(title: "t", ownerBotID: "owner", steps: [.init(text: "fix it", assigneeName: "Tai Lung")], stallLimit: 40)
        let id = g.steps[0].id
        _ = g.updateStep(id: id, status: .blocked, evidence: "waiting on a decision", assigneeName: nil, turnHadToolCalls: true)
        guard case .rejected(let why) = g.updateStep(id: id, status: .blocked, evidence: "still waiting", assigneeName: nil, turnHadToolCalls: true) else {
            return XCTFail("a repeat block should be rejected")
        }
        XCTAssertTrue(why.contains("decide now"), why)
        if case .rejected = g.updateStep(id: id, status: .inProgress, evidence: nil, assigneeName: nil, turnHadToolCalls: true) {
            XCTFail("a real change still records")
        }
    }

    func testFetchThatBroughtNothingDoesNotTaint() {
        let quiet: [String: Any] = ["stdout": "  main\n* prism-tests\n  remotes/origin/main\n", "stderr": ""]
        XCTAssertTrue(TaintRules.gitBroughtNothingIn("cd /workspace/r && git fetch origin 2>&1 && git branch -a 2>&1", observation: quiet))
        let fetched: [String: Any] = ["stdout": "From https://github.com/someone/r\n * [new branch] x -> origin/x\n", "stderr": ""]
        XCTAssertFalse(TaintRules.gitBroughtNothingIn("git fetch origin", observation: fetched))
        XCTAssertFalse(TaintRules.gitBroughtNothingIn("git fetch https://github.com/someone/r", observation: quiet))
        XCTAssertFalse(TaintRules.gitBroughtNothingIn("git fetch origin && cat README.md", observation: quiet))
    }

    func testConnectionErrorIsNotCalledSuccess() {
        let out = ObservationPolicy.annotate(tool: "run_shell", observation: ["error": "Could not reach sandbox-manager"])
        XCTAssertNil(out["note"])
        let hint = ObservationPolicy.annotate(tool: "run_shell", observation: ["exit_code": 127, "stdout": "bash: line 1: python: command not found\n"])
        XCTAssertEqual(hint["hint"] as? String, "This VM has no `python` command: use `python3`.")
    }
}

final class RunFixesTests: XCTestCase {
    func testPipRefusedByPEP668DoesNotTaint() {
        let refused: [String: Any] = ["stdout": "error: externally-managed-environment\n\n× This environment is externally managed\n", "stderr": ""]
        XCTAssertTrue(TaintRules.failedBeforeAnyRemoteContent(refused))
        let hint = ObservationPolicy.annotate(tool: "run_shell", observation: ["exit_code": 1, "stdout": "error: externally-managed-environment"])
        XCTAssertTrue((hint["hint"] as? String)?.contains(".venv") == true)
    }
}
