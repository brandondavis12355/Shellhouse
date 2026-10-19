import XCTest
@testable import AgentCore

/// Every tool a bot can be offered must be explained in at least one bundled skill, so bots
/// know when and how to call it. Fails when a tool is added without a skill covering it.
final class SkillCoverageTests: XCTestCase {
    func testEveryToolIsCoveredByASkill() throws {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let skills = SkillLibrary.loadDirectory(repoRoot.appendingPathComponent("skills"))
        XCTAssertFalse(skills.isEmpty)
        // Every optional tool switched on.
        let registry = ToolRegistry(
            skills: skills,
            onRemember: { _ in true }, onReplaceMemory: { _, _ in true }, onRecallMemory: { _ in [] },
            onRememberTask: { _ in [:] }, onCompleteTask: { _ in [:] }, onListTasks: { [] },
            onCreateRoutine: { _ in [:] }, onEditRoutine: { _ in [:] }, onRemoveRoutine: { _ in [:] }, onListRoutines: { [] },
            onGetProfile: { [:] }, onListBots: { [] }, onMessageBot: { _, _ in [:] }, onCreateBot: { _, _, _ in [:] },
            onAddBotToGroup: { _, _ in [:] }, onPostToGroup: { _, _ in [:] }, onUpdateUser: { _ in [:] },
            onAskHelpers: { _ in [:] }, onRequestCredentials: { _ in [:] }, onGoalTool: { _, _ in [:] }
        )
        // finish_task / update_plan live in AgentRuntime; final_answer is the smolagents runner's finish tool.
        let tools = Set(registry.schemas.map(\.name)).union(["finish_task", "update_plan", "final_answer"])
        let text = skills.map(\.content).joined(separator: "\n")
        let uncovered = tools.filter { name in text.range(of: "\\b\(name)\\b", options: .regularExpression) == nil }.sorted()
        XCTAssertEqual(uncovered, [], "tools no skill explains: \(uncovered)")
        XCTAssertGreaterThanOrEqual(tools.count, 40, "registry should expose the full tool set here")
    }
}

final class SkillIndexTests: XCTestCase {
    func testTheIndexKeepsEachWhenLine() {
        let skills = [
            Skill(id: "desktop-control", name: "Desktop", description: "Before your first GUI action in a task.", content: ""),
            Skill(id: "sharing-screenshots", name: "Share", description: "When the user should see an image.", content: ""),
        ]
        let index = SkillLibrary.promptIndex(skills)
        XCTAssertTrue(index.contains("- desktop-control: Before your first GUI action in a task."))
        XCTAssertTrue(index.contains("- sharing-screenshots: When the user should see an image."))
    }
}

final class DelegationAndProcessTests: XCTestCase {
    func testAHopStopsAtTheAskerOrABusyBotAndCannotPassOn() {
        XCTAssertEqual(DelegationHop.decision(hop: 0, recipientID: "b", originID: nil, recipientBusy: false), .run(allowFurther: true))
        XCTAssertEqual(DelegationHop.decision(hop: 1, recipientID: "c", originID: "a", recipientBusy: false), .run(allowFurther: false))
        XCTAssertEqual(DelegationHop.decision(hop: 1, recipientID: "a", originID: "a", recipientBusy: false), .skip(.origin))
        XCTAssertEqual(DelegationHop.decision(hop: 1, recipientID: "c", originID: "a", recipientBusy: true), .skip(.busy))
        XCTAssertEqual(DelegationHop.decision(hop: 2, recipientID: "d", originID: "a", recipientBusy: false), .skip(.passedOn))
    }

    func testARepeatableCommandBecomesOneProcessLine() {
        XCTAssertEqual(ProcessNote.command(in: "It was down. I ran `systemctl restart nginx` and it came back."), "systemctl restart nginx")
        XCTAssertNil(ProcessNote.command(in: "Tai said the service is fine."))
    }
}

final class ProgrammingSkillsTests: XCTestCase {
    func testProgrammingSkillsLoadWithDescriptionsAndAttribution() throws {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let skills = Dictionary(uniqueKeysWithValues: SkillLibrary.loadDirectory(repoRoot.appendingPathComponent("skills")).map { ($0.id, $0) })
        let adapted = ["planning-code-work", "test-driven-development", "systematic-debugging", "verification-before-completion",
                       "incremental-implementation", "code-review", "clean-and-secure-code", "git-teamwork"]
        for id in adapted {
            let skill = try XCTUnwrap(skills[id], id)
            XCTAssertFalse(skill.description.isEmpty, id)
            XCTAssertTrue(skill.content.contains("Adapted from") && skill.content.contains("MIT"), "\(id) must keep its license attribution")
        }
        let notices = try String(contentsOf: repoRoot.appendingPathComponent("skills/THIRD-PARTY-NOTICES.txt"), encoding: .utf8)
        XCTAssertTrue(notices.contains("Copyright (c) 2025 Jesse Vincent") && notices.contains("Copyright (c) 2025 Addy Osmani"))
        XCTAssertNil(skills["THIRD-PARTY-NOTICES"], "the notices file must not load as a skill")
    }
}
