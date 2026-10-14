import XCTest
@testable import AgentCore

final class LessonLearnerTests: XCTestCase {
    func testOnlyARecoveredOrLongRunIsReviewed() {
        let trail = LessonTrail()
        trail.started("run_shell", argumentsJSON: #"{"command":"python -m pytest"}"#)
        trail.completed("run_shell", resultJSON: #"{"exit_code":127,"stdout":"bash: python: command not found"}"#)
        XCTAssertFalse(trail.worthReviewing, "a failure alone teaches nothing yet")
        trail.started("run_shell", argumentsJSON: #"{"command":"python3 -m unittest"}"#)
        trail.completed("run_shell", resultJSON: #"{"exit_code":0,"stdout":"OK"}"#)
        XCTAssertTrue(trail.worthReviewing)
        XCTAssertTrue(trail.text.contains("FAILED"))
        trail.reset()
        XCTAssertFalse(trail.worthReviewing)
    }

    func testLessonParsing() {
        XCTAssertEqual(LessonLearner.lesson(from: "<think>hm</think>\n- When `python` is missing on the VM, use `python3`."),
                       "When `python` is missing on the VM, use `python3`.")
        XCTAssertNil(LessonLearner.lesson(from: "NONE"))
        XCTAssertNil(LessonLearner.lesson(from: "None of this is new."))
        XCTAssertNil(LessonLearner.lesson(from: "When cloning, use token ghp_abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertNil(LessonLearner.lesson(from: "When logging in, password: hunter2 works"))
        XCTAssertNil(LessonLearner.lesson(from: "ok"))
    }
}

final class GoalEditTests: XCTestCase {
    private func goal() -> GroupGoal {
        var g = GroupGoal(title: "t", ownerBotID: "o", steps: [.init(text: "core"), .init(text: "tests"), .init(text: "ship")], stallLimit: 40)
        g.setDependencies([2: [1], 3: [2]])
        return g
    }

    func testEditAssignReopenAndUserDone() {
        var g = goal()
        let id = g.steps[1].id
        XCTAssertTrue(g.editStep(id: id, text: "Bugbot: write the tests"))
        g.assignStep(id: id, to: "Bugbot")
        XCTAssertEqual(g.steps[1].assigneeName, "Bugbot")
        g.assignStep(id: id, to: "")
        XCTAssertNil(g.steps[1].assigneeName)
        XCTAssertTrue(g.markDoneByUser(id: g.steps[0].id))
        XCTAssertEqual(g.steps[0].status, .done)
        XCTAssertTrue(g.steps[0].verified)
        g.reopenStep(id: g.steps[0].id)
        XCTAssertEqual(g.steps[0].status, .open)
        XCTAssertNil(g.steps[0].evidence)
    }

    func testMovingAndRemovingNeverLeaveForwardOrDanglingDependencies() {
        var g = goal()
        let core = g.steps[0].id, tests = g.steps[1].id
        g.moveStep(id: core, by: 2)   // core now last: tests and ship can't wait on a later step
        XCTAssertEqual(g.steps.last?.id, core)
        XCTAssertNil(g.steps.first { $0.id == tests }?.dependsOn)
        var h = goal()
        h.removeStep(id: h.steps[1].id)
        XCTAssertNil(h.steps[1].dependsOn, "ship no longer waits on the removed step")
    }
}

final class ChatImageStoreTests: XCTestCase {
    func testOnlyRealImagesAreKeptAndIdsCannotEscape() throws {
        // a 1x1 PNG
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        XCTAssertEqual(ChatImageStore.imageExtension(of: png), "png")
        XCTAssertNil(ChatImageStore.imageExtension(of: Data("<html>not an image</html>".utf8)))
        let id = try XCTUnwrap(ChatImageStore.save(png))
        XCTAssertNotNil(ChatImageStore.url(for: id))
        XCTAssertNil(ChatImageStore.url(for: "../../etc/passwd"))
        XCTAssertNil(ChatImageStore.url(for: "../" + id))
        try? FileManager.default.removeItem(at: ChatImageStore.url(for: id)!)
    }
}
