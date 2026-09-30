import XCTest
@testable import AgentCore

final class IsolatedReplyPickerTests: XCTestCase {
    private func plain(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, content: text) }
    private func summary(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, content: text, isTaskSummary: true) }
    private func withTool(_ text: String, _ tool: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: text, toolCalls: [ToolCall(name: tool, arguments: [:])])
    }
    private func pick(_ messages: [ChatMessage]) -> String? {
        var picker = IsolatedReplyPicker()
        messages.forEach { picker.observe($0) }
        return picker.result
    }

    private let standup = "@everyone Daily Stand-up - 9:00 AM\n\nPlease each give a quick update: status, blockers, and today's focus for the day."

    /// The reported regression: narration turns, then the real message only in the summary.
    func testNarrationThenRealSummaryPostsSummary() {
        let narration = "The routine fired and I'm directed to run the stand-up in the group. I'll post it now."
        XCTAssertEqual(pick([plain(narration), plain(narration), plain(narration), summary(standup)]), standup)
    }

    /// The earlier bug: real reply as plain text, terse recap as summary.
    func testRealReplyThenTerseSummaryPostsReply() {
        let reply = "The meeting is at 3pm in room 204, and lunch is catered."
        XCTAssertEqual(pick([plain(reply), summary("Answered the scheduling question.")]), reply)
    }

    func testSummaryOnlyIsUsed() {
        XCTAssertEqual(pick([summary(standup)]), standup)
    }

    func testTieGoesToSummary() {
        XCTAssertEqual(pick([plain("same text"), summary("same text")]), "same text")
    }

    /// Working narration next to a tool call must never be a candidate.
    func testTextBesideNonFinishToolCallIsIgnored() {
        let longNarration = String(repeating: "Let me look into that and run some commands. ", count: 10)
        XCTAssertEqual(pick([withTool(longNarration, "run_shell"), summary("Done: 3 files updated.")]), "Done: 3 files updated.")
    }

    func testTextBesideFinishToolCallCounts() {
        let reply = "Here is the full answer with all the detail the user wanted."
        XCTAssertEqual(pick([withTool(reply, "finish_task"), summary("Answered.")]), reply)
    }

    func testEmptyRunHasNoResult() {
        XCTAssertNil(pick([]))
        XCTAssertNil(pick([plain("   "), summary("")]))
    }

    func testNonAssistantIgnored() {
        XCTAssertEqual(pick([ChatMessage(role: .tool, content: String(repeating: "x", count: 500)), summary("ok result")]), "ok result")
    }
}
