import XCTest
@testable import AgentCore

final class GoalAutoCloseTests: XCTestCase {
    private let evidence = "Ran `gh --version`: gh version 2.46.0"

    private func goal(_ texts: [String]) -> GroupGoal {
        GroupGoal(title: "t", ownerBotID: "o", steps: texts.map { GroupGoal.Step(text: $0) })
    }

    func testClosesWhenTheLastStepIsDone() {
        var g = goal(["a", "b"])
        _ = g.updateStep(id: g.steps[0].id, status: .done, evidence: evidence, assigneeName: nil, turnHadToolCalls: true)
        XCTAssertFalse(g.closeIfComplete())
        _ = g.updateStep(id: g.steps[1].id, status: .done, evidence: evidence, assigneeName: nil, turnHadToolCalls: true)
        XCTAssertTrue(g.closeIfComplete())
        XCTAssertEqual(g.status, .done)
        XCTAssertFalse(g.isLive)
    }

    func testABlockedStepStillNeedsTheUser() {
        var g = goal(["a", "b"])
        _ = g.updateStep(id: g.steps[0].id, status: .done, evidence: evidence, assigneeName: nil, turnHadToolCalls: true)
        _ = g.updateStep(id: g.steps[1].id, status: .blocked, evidence: "no network", assigneeName: nil, turnHadToolCalls: true)
        XCTAssertFalse(g.closeIfComplete())
        XCTAssertEqual(g.proposeComplete(summary: "a done, b blocked"), .recorded)
        XCTAssertEqual(g.status, .awaitingConfirmation)
    }

    func testProposingCompletionWithEverythingDoneClosesAtOnce() {
        var g = goal(["a"])
        _ = g.updateStep(id: g.steps[0].id, status: .done, evidence: evidence, assigneeName: nil, turnHadToolCalls: true)
        XCTAssertEqual(g.proposeComplete(summary: "gh installed everywhere"), .recorded)
        XCTAssertEqual(g.status, .done)
        XCTAssertEqual(g.completionSummary, "gh installed everywhere")
    }

    func testAPerMemberStepClosesTheGoalOnlyWhenEveryoneCheckedIn() {
        var g = GroupGoal(title: "gh", ownerBotID: "o", steps: [GroupGoal.Step(text: "each bot installs gh", requiredMembers: ["A", "B"])])
        _ = g.updateStep(id: g.steps[0].id, status: .done, evidence: evidence, assigneeName: nil, turnHadToolCalls: true, actorName: "A")
        XCTAssertFalse(g.closeIfComplete())
        _ = g.updateStep(id: g.steps[0].id, status: .done, evidence: evidence, assigneeName: nil, turnHadToolCalls: true, actorName: "B")
        XCTAssertTrue(g.closeIfComplete())
    }
}
