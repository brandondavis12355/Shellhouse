import XCTest
@testable import AgentCore

final class GroupGoalTests: XCTestCase {
    private func goal(limit: Int = 3, steps: [String] = ["a", "b"]) -> GroupGoal {
        GroupGoal(title: "T", ownerBotID: "owner", steps: steps.map { GroupGoal.Step(text: $0) }, stallLimit: limit)
    }
    private let evidence = "ran the test suite and all 12 tests passed"

    func testVerifiedCompletionIsProgressAndResetsCounter() {
        var g = goal()
        g.noteBotMessage(); g.noteBotMessage()
        XCTAssertEqual(g.updateStep(id: g.steps[0].id, status: .done, evidence: evidence, assigneeName: "X", turnHadToolCalls: true), .progress)
        XCTAssertEqual(g.messagesSinceProgress, 0)
        XCTAssertEqual(g.doneCount, 1)
        XCTAssertTrue(g.steps[0].verified)
    }

    func testUnverifiedCompletionIsRecordedButNotProgress() {
        var g = goal()
        g.noteBotMessage()
        XCTAssertEqual(g.updateStep(id: g.steps[0].id, status: .done, evidence: evidence, assigneeName: nil, turnHadToolCalls: false), .recorded)
        XCTAssertEqual(g.messagesSinceProgress, 1)
        XCTAssertFalse(g.steps[0].verified)
    }

    func testDoneNeedsEvidence() {
        var g = goal()
        if case .rejected = g.updateStep(id: g.steps[0].id, status: .done, evidence: "ok", assigneeName: nil, turnHadToolCalls: true) {} else { XCTFail() }
        XCTAssertEqual(g.steps[0].status, .open)
    }

    func testRedoingADoneStepDoesNotFarmProgress() {
        var g = goal()
        _ = g.updateStep(id: g.steps[0].id, status: .done, evidence: evidence, assigneeName: nil, turnHadToolCalls: true)
        g.noteBotMessage()
        XCTAssertEqual(g.updateStep(id: g.steps[0].id, status: .done, evidence: evidence + "!", assigneeName: nil, turnHadToolCalls: true), .recorded)
        XCTAssertEqual(g.messagesSinceProgress, 1)
    }

    func testStallPausesAtLimitAndOnlyOnce() {
        var g = goal(limit: 3)
        XCTAssertFalse(g.noteBotMessage()); XCTAssertFalse(g.noteBotMessage())
        XCTAssertTrue(g.noteBotMessage())
        XCTAssertEqual(g.status, .paused)
        XCTAssertFalse(g.noteBotMessage())
    }

    func testUserActivityUnpausesAndResets() {
        var g = goal(limit: 1)
        g.noteBotMessage()
        XCTAssertEqual(g.status, .paused)
        g.noteUserActivity()
        XCTAssertEqual(g.status, .active)
        XCTAssertEqual(g.messagesSinceProgress, 0)
    }

    func testCompletionRequiresAllStepsHandled() {
        var g = goal()
        if case .rejected = g.proposeComplete(summary: "done") {} else { XCTFail() }
        _ = g.updateStep(id: g.steps[0].id, status: .done, evidence: evidence, assigneeName: nil, turnHadToolCalls: true)
        _ = g.updateStep(id: g.steps[1].id, status: .blocked, evidence: "needs root access we don't have", assigneeName: nil, turnHadToolCalls: false)
        XCTAssertEqual(g.proposeComplete(summary: "all handled"), .recorded)
        XCTAssertEqual(g.status, .awaitingConfirmation)
    }

    func testConfirmRejectAndTimeout() {
        var g = GroupGoal(title: "T", ownerBotID: "o", steps: [])
        _ = g.proposeComplete(summary: "s", now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(g.confirmationTimedOut(timeout: 60, now: Date(timeIntervalSince1970: 61)))
        XCTAssertFalse(g.confirmationTimedOut(timeout: 60, now: Date(timeIntervalSince1970: 30)))
        var rejected = g; rejected.rejectCompletion()
        XCTAssertEqual(rejected.status, .active)
        g.confirmComplete()
        XCTAssertEqual(g.status, .done)
        XCTAssertFalse(g.isLive)
    }

    func testStepsCannotChangeWhenNotActive() {
        var g = goal(); g.cancel()
        if case .rejected = g.updateStep(id: g.steps[0].id, status: .inProgress, evidence: nil, assigneeName: nil, turnHadToolCalls: true) {} else { XCTFail() }
        XCTAssertNil(g.addStep("late"))
    }

    func testPromptBlockListsStepsAndProgress() {
        var g = goal()
        _ = g.updateStep(id: g.steps[0].id, status: .done, evidence: evidence, assigneeName: "Tai Lung", turnHadToolCalls: true)
        let block = g.promptBlock(ownerName: "Mr. Smith")
        XCTAssertTrue(block.contains("[x]") && block.contains("[ ]") && block.contains("1/2 steps done") && block.contains("Mr. Smith"))
    }
}

final class GoalValidationTests: XCTestCase {
    private let evidence = "ran `gh --version` and it printed 2.46.0 on the shared sandbox"

    private func goal() -> GroupGoal {
        GroupGoal(title: "Install gh", ownerBotID: "owner", steps: [GroupGoal.Step(text: "check"), GroupGoal.Step(text: "install")])
    }

    func testAMemberCanOnlySubmitNeverCompleteAStep() {
        var g = goal()
        let id = g.steps[0].id
        XCTAssertEqual(g.updateStep(id: id, status: .done, evidence: evidence, assigneeName: "Bugbot", turnHadToolCalls: true, byOwner: false), .submitted)
        XCTAssertEqual(g.steps[0].status, .review)
        XCTAssertEqual(g.doneCount, 0)
        XCTAssertEqual(g.messagesSinceProgress, 0)
        XCTAssertFalse(g.steps[0].verified)
    }

    func testOnlyTheOwnerValidatesAndItNeedsTheirOwnToolRun() {
        var g = goal()
        let id = g.steps[0].id
        _ = g.updateStep(id: id, status: .done, evidence: evidence, assigneeName: "Bugbot", turnHadToolCalls: true, byOwner: false)
        // Owner rubber-stamping without running anything is refused.
        if case .rejected = g.updateStep(id: id, status: .done, evidence: evidence, assigneeName: nil, turnHadToolCalls: false, byOwner: true) {} else { XCTFail("must validate first") }
        XCTAssertEqual(g.steps[0].status, .review)
        // After the owner re-checks, it counts.
        XCTAssertEqual(g.updateStep(id: id, status: .done, evidence: "re-ran gh --version myself: 2.46.0", assigneeName: nil, turnHadToolCalls: true, byOwner: true), .progress)
        XCTAssertEqual(g.steps[0].status, .done)
        XCTAssertTrue(g.steps[0].verified)
    }

    func testMembersCannotTouchAStepUnderReviewOrDone() {
        var g = goal()
        let id = g.steps[0].id
        _ = g.updateStep(id: id, status: .done, evidence: evidence, assigneeName: "Bugbot", turnHadToolCalls: true, byOwner: false)
        for status in [GroupGoal.StepStatus.done, .inProgress, .blocked] {
            if case .rejected = g.updateStep(id: id, status: status, evidence: evidence, assigneeName: "Cleo", turnHadToolCalls: true, byOwner: false) {} else { XCTFail("\(status)") }
        }
        _ = g.updateStep(id: id, status: .done, evidence: "owner check: gh --version -> 2.46.0 confirmed", assigneeName: nil, turnHadToolCalls: true, byOwner: true)
        if case .rejected = g.updateStep(id: id, status: .inProgress, evidence: nil, assigneeName: "Cleo", turnHadToolCalls: true, byOwner: false) {} else { XCTFail("done is final for members") }
    }

    func testRejectionOfASubmittedStepNamesWhoValidates() {
        var g = goal()
        g.validatorName = "Bugbot"
        let id = g.steps[0].id
        _ = g.updateStep(id: id, status: .done, evidence: evidence, assigneeName: "Tai Lung", turnHadToolCalls: true, byOwner: false)
        guard case .rejected(let message) = g.updateStep(id: id, status: .done, evidence: evidence, assigneeName: nil, turnHadToolCalls: true, byOwner: false) else { return XCTFail() }
        XCTAssertTrue(message.contains("Bugbot"), message)
        XCTAssertFalse(message.contains("only the owner can change it"), "must not tell the owner they can't")
    }

    func testOwnerCanSendASubmissionBack() {
        var g = goal()
        let id = g.steps[0].id
        _ = g.updateStep(id: id, status: .done, evidence: evidence, assigneeName: "Bugbot", turnHadToolCalls: true, byOwner: false)
        XCTAssertEqual(g.updateStep(id: id, status: .inProgress, evidence: "output does not show a version", assigneeName: nil, turnHadToolCalls: false, byOwner: true), .recorded)
        XCTAssertEqual(g.steps[0].status, .inProgress)
    }

    func testMembersCanStillClaimAndBlock() {
        var g = goal()
        let id = g.steps[1].id
        XCTAssertEqual(g.updateStep(id: id, status: .inProgress, evidence: nil, assigneeName: "Cleo", turnHadToolCalls: false, byOwner: false), .recorded)
        XCTAssertEqual(g.updateStep(id: id, status: .blocked, evidence: "needs root access", assigneeName: "Cleo", turnHadToolCalls: false, byOwner: false), .recorded)
    }

    func testCompletionCannotBeProposedWhileAStepAwaitsValidation() {
        var g = goal()
        _ = g.updateStep(id: g.steps[0].id, status: .done, evidence: evidence, assigneeName: "Bugbot", turnHadToolCalls: true, byOwner: false)
        _ = g.updateStep(id: g.steps[1].id, status: .blocked, evidence: "needs root access we do not have", assigneeName: nil, turnHadToolCalls: false)
        if case .rejected = g.proposeComplete(summary: "all done") {} else { XCTFail("an unvalidated step must block completion") }
    }

    func testReviewIsNotSettableDirectly() {
        var g = goal()
        if case .rejected = g.updateStep(id: g.steps[0].id, status: .review, evidence: evidence, assigneeName: nil, turnHadToolCalls: true) {} else { XCTFail() }
    }
}
