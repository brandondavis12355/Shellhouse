import XCTest
@testable import AgentCore

final class BuiltInSystemPromptTests: XCTestCase {
    func testBuiltInAloneMigratesToEmpty() {
        XCTAssertEqual(BuiltInSystemPrompt.userPortion(of: BuiltInSystemPrompt.text), "")
    }

    func testUserAdditionSurvives() {
        let saved = BuiltInSystemPrompt.text + "\n\nAlways answer in French."
        XCTAssertEqual(BuiltInSystemPrompt.userPortion(of: saved), "Always answer in French.")
    }

    func testCreateBotStyleRolePromptSurvives() {
        let saved = "You are a QA specialist.\nBe strict.\n\n---\n\n" + BuiltInSystemPrompt.text
        XCTAssertEqual(BuiltInSystemPrompt.userPortion(of: saved), "You are a QA specialist.\nBe strict.")
    }

    func testPlainUserTextUnchangedAndIdempotent() {
        let text = "Focus on Swift.\n\nNever touch prod."
        XCTAssertEqual(BuiltInSystemPrompt.userPortion(of: text), text)
        XCTAssertEqual(BuiltInSystemPrompt.userPortion(of: BuiltInSystemPrompt.userPortion(of: text)), text)
    }

    func testOlderDefaultWithoutVerificationParagraphIsStripped() {
        let paragraphs = BuiltInSystemPrompt.text.components(separatedBy: "\n\n")
        let older = paragraphs.filter { !$0.hasPrefix("Before calling finish_task on any task") }.joined(separator: "\n\n")
        XCTAssertEqual(BuiltInSystemPrompt.userPortion(of: older + "\n\nExtra rule."), "Extra rule.")
    }

    func testBuiltInContainsVerificationRule() {
        XCTAssertTrue(BuiltInSystemPrompt.text.contains(BuiltInSystemPrompt.toolVerification))
    }
}
