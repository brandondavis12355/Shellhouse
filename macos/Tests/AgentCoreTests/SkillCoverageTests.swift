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
            onRemember: { _ in true }, onRecallMemory: { _ in [] },
            onRememberTask: { _ in [:] }, onCompleteTask: { _ in [:] }, onListTasks: { [] },
            onCreateRoutine: { _ in [:] }, onEditRoutine: { _ in [:] }, onRemoveRoutine: { _ in [:] }, onListRoutines: { [] },
            onGetProfile: { [:] }, onListBots: { [] }, onMessageBot: { _, _ in [:] }, onCreateBot: { _, _, _ in [:] },
            onAddBotToGroup: { _, _ in [:] }, onPostToGroup: { _, _ in [:] }, onUpdateUser: { _ in [:] },
            onAskHelpers: { _ in [:] }, onGoalTool: { _, _ in [:] }
        )
        // finish_task / update_plan live in AgentRuntime; final_answer is the smolagents runner's finish tool.
        let tools = Set(registry.schemas.map(\.name)).union(["finish_task", "update_plan", "final_answer"])
        let text = skills.map(\.content).joined(separator: "\n")
        let uncovered = tools.filter { name in text.range(of: "\\b\(name)\\b", options: .regularExpression) == nil }.sorted()
        XCTAssertEqual(uncovered, [], "tools no skill explains: \(uncovered)")
        XCTAssertGreaterThanOrEqual(tools.count, 40, "registry should expose the full tool set here")
    }
}
