import XCTest
@testable import AgentCore

/// Replays the "make sure every bot has gh" goal: a step every member must
/// do on their own VM can't be closed by the owner's check alone.
final class GroupGoalPerMemberTests: XCTestCase {
    private let members = ["Mr. Smith", "Tai Lung", "Bugbot", "Cleo"]
    private let evidence = "Ran `command -v gh`: /usr/bin/gh, gh version 2.46.0"

    private func goal() -> GroupGoal {
        let texts = [
            "Each bot (Mr. Smith, Tai Lung, Bugbot, Cleo) checks whether `gh` is installed on its own VM.",
            "Mr. Smith compiles a final status table.",
        ]
        let steps = texts.map { GroupGoal.Step(text: $0, requiredMembers: GroupGoal.membersRequired(byStepText: $0, memberNames: members)) }
        return GroupGoal(title: "gh everywhere", ownerBotID: "smith", steps: steps)
    }

    func testDetection() {
        XCTAssertEqual(GroupGoal.membersRequired(byStepText: "Each bot checks its VM", memberNames: members), members)
        XCTAssertEqual(GroupGoal.membersRequired(byStepText: "make sure every single VM has it", memberNames: members), members)
        XCTAssertEqual(GroupGoal.membersRequired(byStepText: "Everyone reports their version", memberNames: members), members)
        XCTAssertEqual(GroupGoal.membersRequired(byStepText: "Tai Lung and Cleo install gh", memberNames: members), ["Tai Lung", "Cleo"])
        XCTAssertNil(GroupGoal.membersRequired(byStepText: "Mr. Smith compiles a final status table", memberNames: members))
        XCTAssertNil(GroupGoal.membersRequired(byStepText: "Any bot missing gh installs it", memberNames: members))
        XCTAssertNil(GroupGoal.membersRequired(byStepText: "Each bot checks", memberNames: ["Solo"]))
    }

    func testOwnerAloneCannotCloseIt() {
        var g = goal()
        let id = g.steps[0].id
        let r = g.updateStep(id: id, status: .done, evidence: evidence, assigneeName: nil, turnHadToolCalls: true, byOwner: true, actorName: "Mr. Smith")
        XCTAssertEqual(r, .memberCheckedIn(remaining: ["Tai Lung", "Bugbot", "Cleo"]))
        XCTAssertEqual(g.steps[0].status, .inProgress)
        XCTAssertEqual(g.doneCount, 0)
        XCTAssertTrue(g.promptBlock(ownerName: "Mr. Smith").contains("1/4 checked in; waiting on Tai Lung, Bugbot, Cleo"))
    }

    func testCompletesWhenEveryoneChecksIn() {
        var g = goal()
        let id = g.steps[0].id
        for (i, name) in members.enumerated() {
            let r = g.updateStep(id: id, status: .done, evidence: evidence, assigneeName: nil, turnHadToolCalls: true,
                                 byOwner: name == "Mr. Smith", actorName: name)
            if i < members.count - 1 { XCTAssertEqual(r, .memberCheckedIn(remaining: Array(members[(i + 1)...]))) }
            else { XCTAssertEqual(r, .progress) }
        }
        XCTAssertEqual(g.steps[0].status, .done)
        XCTAssertTrue(g.steps[0].verified)
        XCTAssertEqual(g.doneCount, 1)
    }

    func testNobodyChecksInForSomeoneElse() {
        var g = goal()
        let r = g.updateStep(id: g.steps[0].id, status: .done, evidence: evidence, assigneeName: "Cleo", turnHadToolCalls: true,
                             byOwner: true, actorName: "Dr. EggBot")
        guard case .rejected = r else { return XCTFail("expected rejection, got \(r)") }
        XCTAssertNil(g.steps[0].memberEvidence)
    }

    func testCheckInNeedsToolsAndEvidence() {
        var g = goal()
        let id = g.steps[0].id
        XCTAssertEqual(g.updateStep(id: id, status: .done, evidence: evidence, assigneeName: nil, turnHadToolCalls: false, actorName: "Cleo"), .recorded)
        XCTAssertNil(g.steps[0].memberEvidence)
        guard case .rejected = g.updateStep(id: id, status: .done, evidence: "ok", assigneeName: nil, turnHadToolCalls: true, actorName: "Cleo") else {
            return XCTFail("short evidence should be rejected")
        }
    }

    func testOrdinaryStepsUnchanged() {
        var g = goal()
        let r = g.updateStep(id: g.steps[1].id, status: .done, evidence: "Compiled the table from all four check-ins", assigneeName: nil,
                             turnHadToolCalls: true, byOwner: true, actorName: "Mr. Smith")
        XCTAssertEqual(r, .progress)
    }

    func testOldGoalsStillDecode() throws {
        let json = #"{"id":"g","title":"t","ownerBotID":"o","status":"active","steps":[{"id":"s","text":"x","status":"open","verified":false}],"messagesSinceProgress":0,"stallLimit":40,"createdAt":0}"#
        let g = try JSONDecoder().decode(GroupGoal.self, from: Data(json.utf8))
        XCTAssertFalse(g.steps[0].isPerMember)
    }
}
