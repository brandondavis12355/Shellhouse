import XCTest
@testable import AgentCore

final class GoalDependencyTests: XCTestCase {
    private func goal() -> GroupGoal {
        var g = GroupGoal(title: "Tic tac toe", ownerBotID: "owner", steps: [
            .init(text: "Clone the repo"), .init(text: "Write game.py", assigneeName: "Bugbot"),
            .init(text: "Write test_game.py", assigneeName: "Prism"), .init(text: "Write main.py", assigneeName: "Cleo"),
        ], stallLimit: 40)
        g.setDependencies(GroupGoal.dependencyMap(from: AnyCodable([["step": 3, "after": [2]], ["step": 4, "after": [2]], ["step": 2, "after": [2, 3]]])))
        return g
    }

    func testDependenciesOnlyPointAtEarlierSteps() {
        let g = goal()
        XCTAssertNil(g.steps[1].dependsOn, "a step can't wait on itself or a later step")
        XCTAssertEqual(g.steps[2].dependsOn, [g.steps[1].id])
    }

    func testWaitingStepsCantStartOrFinish() {
        var g = goal()
        let tests = g.steps[2].id
        guard case .rejected(let why) = g.updateStep(id: tests, status: .inProgress, evidence: nil, assigneeName: "Prism",
                                                     turnHadToolCalls: true, byOwner: false, actorName: "Prism") else {
            return XCTFail("a waiting step must not start")
        }
        XCTAssertTrue(why.contains("waits on step 2"))
        XCTAssertTrue(g.onlyWaitingWork(for: "Prism"))
        XCTAssertFalse(g.onlyWaitingWork(for: "Bugbot"))

        _ = g.updateStep(id: g.steps[1].id, status: .done, evidence: "pytest -q: 12 passed in game.py", assigneeName: nil, turnHadToolCalls: true)
        XCTAssertFalse(g.onlyWaitingWork(for: "Prism"))
        if case .rejected(let why) = g.updateStep(id: tests, status: .inProgress, evidence: nil, assigneeName: "Prism",
                                                  turnHadToolCalls: true, byOwner: false, actorName: "Prism") {
            XCTFail("unblocked step was rejected: \(why)")
        }
    }

    func testPromptShowsWhatIsWaiting() {
        let block = goal().promptBlock(ownerName: "Mr. Smith")
        XCTAssertTrue(block.contains("[⏸] Write test_game.py"))
        XCTAssertTrue(block.contains("WAITING on step 2"))
        XCTAssertTrue(block.contains("don't write stand-ins"))
    }

    func testAddStepTakesNumbers() {
        var g = goal()
        _ = g.addStep("Push to a branch", dependsOnNumbers: GroupGoal.numbers(from: AnyCodable([2, 3, 4, 9])))
        XCTAssertEqual(g.steps[4].dependsOn?.count, 3)
    }
}

final class OwnerReviewTests: XCTestCase {
    func testOwnerIsToldWhatToValidateUnblockOrClose() {
        var g = GroupGoal(title: "t", ownerBotID: "owner", steps: [.init(text: "Write game.py", assigneeName: "Bugbot"), .init(text: "Write tests")], stallLimit: 40)
        XCTAssertNil(g.ownerReviewWork(), "nothing submitted yet")
        _ = g.updateStep(id: g.steps[0].id, status: .done, evidence: "pytest: 12 passed in game_test.py", assigneeName: nil,
                         turnHadToolCalls: true, byOwner: false, actorName: "Bugbot")
        let work = g.ownerReviewWork()
        XCTAssertTrue(work?.contains("Waiting for your validation: step 1") == true, work ?? "nil")
        XCTAssertTrue(work?.contains("12 passed") == true)
        let before = g.reviewSignature
        _ = g.updateStep(id: g.steps[1].id, status: .blocked, evidence: "pytest missing", assigneeName: nil, turnHadToolCalls: true, byOwner: false, actorName: "Prism")
        XCTAssertNotEqual(g.reviewSignature, before)
        XCTAssertTrue(g.ownerReviewWork()?.contains("Blocked: step 2") == true)
    }

    func testAFinishedGoalAsksTheOwnerToClose() {
        var g = GroupGoal(title: "t", ownerBotID: "owner", steps: [.init(text: "only step")], stallLimit: 40)
        _ = g.updateStep(id: g.steps[0].id, status: .done, evidence: "ran it: output 'ok' printed", assigneeName: nil, turnHadToolCalls: true)
        if g.status == .active {
            XCTAssertTrue(g.ownerReviewWork()?.contains("propose_goal_complete") == true)
        }
    }
}
