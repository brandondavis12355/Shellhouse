import XCTest
@testable import AgentCore

final class SkillSelectionTests: XCTestCase {
    func testOldSaveWithRemovedAndNewSkills() {
        // Saved before `known` existed: 49 old ids, 2 of which still exist.
        let saved: Set<String> = ["goal-driven-work", "where-to-post", "site-playbooks-ups", "gui-automation"]
        let available: Set<String> = ["goal-driven-work", "where-to-post", "desktop-control", "routines"]
        XCTAssertEqual(SkillLibrary.reconcileSelection(saved: saved, known: nil, available: available), available)
    }

    func testUserTurnedOffStaysOff() {
        let known: Set<String> = ["a", "b", "c"]
        let saved: Set<String> = ["a", "c"]          // user switched off b
        let available: Set<String> = ["a", "b", "c", "d"]  // d is new
        XCTAssertEqual(SkillLibrary.reconcileSelection(saved: saved, known: known, available: available), ["a", "c", "d"])
    }

    func testRemovedSkillsDropOut() {
        XCTAssertEqual(SkillLibrary.reconcileSelection(saved: ["a", "gone"], known: ["a", "gone"], available: ["a"]), ["a"])
    }
}
