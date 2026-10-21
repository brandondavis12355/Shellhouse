import XCTest
@testable import AgentCore

final class ActivityGroupingTests: XCTestCase {
    private func rows(_ kinds: [TranscriptKind]) -> [TranscriptRow<Int>] {
        ActivityGrouping.rows(kinds.enumerated().map { (id: $0.offset, kind: $0.element) })
    }

    func testAToolHeavyTurnBecomesOneRowAndTheAnswer() {
        // you, narration, tool, narration, tool, narration, tool, answer
        let r = rows([.user, .assistantText, .tool, .assistantText, .tool, .assistantText, .tool, .assistantText])
        XCTAssertEqual(r, [.message(0), .activity([1, 2, 3, 4, 5, 6]), .message(7)])
    }

    func testATurnWithNoToolIsUntouched() {
        XCTAssertEqual(rows([.user, .assistantText, .user, .assistantText]), [.message(0), .message(1), .message(2), .message(3)])
    }

    func testEachTurnGetsItsOwnRow() {
        let r = rows([.user, .tool, .assistantText, .user, .assistantText, .tool, .tool, .summary])
        XCTAssertEqual(r, [.message(0), .activity([1]), .message(2), .message(3), .activity([4, 5, 6]), .message(7)])
    }

    func testTextAfterTheLastToolIsTheAnswerEvenWhileTheRunIsLive() {
        XCTAssertEqual(rows([.user, .assistantText, .tool, .assistantText]), [.message(0), .activity([1, 2]), .message(3)])
        XCTAssertEqual(rows([.user, .assistantText, .tool, .assistantText, .tool]), [.message(0), .activity([1, 2, 3, 4])],
                       "when another tool runs, the text before it moves into the activity row")
    }

    func testStalledNarrationFoldsIntoTheActivityAndNoticesStayVisible() {
        let r = rows([.user, .tool, .assistantText, .assistantText, .assistantText, .notice])
        XCTAssertEqual(r, [.message(0), .activity([1, 2, 3]), .message(4), .message(5)])
    }

    func testWhileLiveTheNewestTurnsTextIsAllActivity() {
        let r = ActivityGrouping.rows([(0, TranscriptKind.user), (1, .tool), (2, .assistantText)], live: true)
        XCTAssertEqual(r, [.message(0), .activity([1, 2])])
    }

    func testANoticeToAnotherBotStaysItsOwnRowAndSplitsTheActivity() {
        let r = rows([.user, .tool, .interBot, .tool, .assistantText])
        XCTAssertEqual(r, [.message(0), .activity([1]), .message(2), .activity([3]), .message(4)])
    }

    func testNothingIsLostOrReordered() {
        let kinds: [TranscriptKind] = [.assistantText, .user, .assistantText, .tool, .tool, .interBot, .summary, .user, .tool, .assistantText]
        var ids: [Int] = []
        for row in rows(kinds) { switch row { case .message(let i): ids.append(i); case .activity(let g): ids += g } }
        XCTAssertEqual(ids, Array(kinds.indices))
        XCTAssertEqual(rows([]), [])
    }
}
