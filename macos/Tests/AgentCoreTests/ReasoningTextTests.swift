import XCTest
@testable import AgentCore

final class ReasoningTextTests: XCTestCase {
    func testStripsTaggedBlockAndTrims() {
        XCTAssertEqual(ReasoningText.strip("<think>hmm, the user wants x</think>\n\nHere is x."), "Here is x.")
    }

    func testStripsSeveralBlocks() {
        XCTAssertEqual(ReasoningText.strip("<think>a</think>One <think>b</think>two"), "One two")
    }

    func testClosingTagWithoutOpenerDropsEverythingBeforeIt() {
        XCTAssertEqual(ReasoningText.strip("I should check the file first.</think>The file is fine."), "The file is fine.")
    }

    func testOpenBlockIsHiddenWhileStreaming() {
        XCTAssertEqual(ReasoningText.visible("Hello <think>still thinking about"), "Hello ")
        XCTAssertEqual(ReasoningText.visible("Hello <thi"), "Hello <thi")   // half a tag: wait for the rest
    }

    func testPlainTextIsUntouched() {
        let text = "  Step 2 is done.\n\n- item\n"
        XCTAssertEqual(ReasoningText.visible(text), text)
    }

    // The reported leak: a long monologue beats a short real answer under "longest wins".
    private let monologue = """
        Looking at the goal state: Step 1 is done, Step 2 is submitted and waiting for Bugbot to validate it.

        Actually, wait — let me re-read the instructions. It says to stop if all work is waiting.

        But actually, looking more carefully, I think there might be something I can do. Maybe I should check if Bugbot has already validated it?

        No — the goal state clearly shows Step 2 as submitted. I'm going to wait.

        Actually, I realize I should also check whether anything is pending for Step 3.

        Wait, let me re-read the instructions one more time. It says to stop if all work is waiting.
        """

    func testRecognisesAMonologue() {
        XCTAssertTrue(ReasoningText.looksLikeDeliberation(monologue))
    }

    func testRecognisesARepeatedParagraph() {
        let line = "I'm waiting on Bugbot to validate Step 2 before I can proceed with anything else here."
        XCTAssertTrue(ReasoningText.looksLikeDeliberation("\(line)\n\nOther text in between the repeats goes here.\n\n\(line)\n\nAnd a bit more text so it is not tiny."))
    }

    func testOrdinaryLongReplyIsNotFlagged() {
        let reply = """
            Status update: Step 1 (Flask server) is complete. Step 2 (frontend wiring) was submitted by Tai Lung and is waiting for Bugbot's validation; the commit is fddbc87 on feat/web-interface.

            Steps 3-7 are blocked until Step 2 is validated. Once it is, I'll start on the AI opponent (Step 3) and then hand the test run to Bugbot.

            One thing worth knowing: the frontend now posts every move to the server, so the game state lives there, not in the page.
            """
        XCTAssertFalse(ReasoningText.looksLikeDeliberation(reply))
    }

    func testShortTextIsNeverFlagged() {
        XCTAssertFalse(ReasoningText.looksLikeDeliberation("Actually, wait — hmm, let me re-read."))
    }

    func testPickerPostsTheShortRealAnswerOverALongMonologue() {
        let answer = "Status: Step 2 is waiting on Bugbot's validation; nothing else is unblocked."
        var picker = IsolatedReplyPicker()
        picker.observe(ChatMessage(role: .assistant, content: monologue))
        picker.observe(ChatMessage(role: .assistant, content: answer))
        XCTAssertEqual(picker.result, answer)
    }

    func testPickerPostsNothingWhenOnlyAMonologueExists() {
        var picker = IsolatedReplyPicker()
        picker.observe(ChatMessage(role: .assistant, content: monologue))
        XCTAssertNil(picker.result)
    }

    func testPickerDropsTaggedThinkingFromTheSummary() {
        var picker = IsolatedReplyPicker()
        picker.observe(ChatMessage(role: .assistant, content: "<think>let me work out the wording</think>All tests pass.", isTaskSummary: true))
        XCTAssertEqual(picker.result, "All tests pass.")
    }
}
