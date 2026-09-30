import XCTest
@testable import AgentCore

final class JoinedGroupLogTests: XCTestCase {
    private func msg(_ seq: Int, _ kind: RelayMessage.Kind = .human, from: String? = "u_other", _ text: String = "t") -> RelayMessage {
        RelayMessage(seq: seq, kind: kind, speakerUserId: from, speakerName: "N", text: text, ts: 0)
    }

    func testDedupesAndSortsAcrossReconnectRedelivery() {
        var log = JoinedGroupLog()
        XCTAssertEqual(log.append(contentsOf: [msg(3), msg(1), msg(2)]), 3)
        XCTAssertEqual(log.messages.map(\.seq), [1, 2, 3])
        XCTAssertEqual(log.append(contentsOf: [msg(2), msg(3), msg(4)]), 1, "only seq 4 is new")
        XCTAssertEqual(log.messages.map(\.seq), [1, 2, 3, 4])
        XCTAssertEqual(log.latestSeq, 4)
    }

    func testBoundedKeepsNewest() {
        var log = JoinedGroupLog(limit: 3)
        log.append(contentsOf: (1...10).map { msg($0) })
        XCTAssertEqual(log.messages.map(\.seq), [8, 9, 10])
    }

    func testEmptyLog() {
        let log = JoinedGroupLog()
        XCTAssertEqual(log.latestSeq, 0)
        XCTAssertEqual(log.unreadCount(after: 0, myUserID: "u_me"), 0)
    }

    func testUnreadIgnoresMyMessagesAndSystemNotices() {
        var log = JoinedGroupLog()
        log.append(contentsOf: [msg(1), msg(2, from: "u_me"), msg(3, .bot, from: "u_owner"), msg(4, .system, from: "u_owner"), msg(5)])
        XCTAssertEqual(log.unreadCount(after: 0, myUserID: "u_me"), 3)   // 1, 3(bot), 5
        XCTAssertEqual(log.unreadCount(after: 3, myUserID: "u_me"), 1)
        XCTAssertEqual(log.unreadCount(after: 5, myUserID: "u_me"), 0)
    }

    func testJoinedExcludesGroupsIOwn() {
        let groups = [
            RelayGroupSummary(groupId: "g1", name: "Mine", ownerId: "u_me"),
            RelayGroupSummary(groupId: "g2", name: "Theirs", ownerId: "u_friend"),
        ]
        XCTAssertEqual(JoinedGroupFilter.joined(groups, myUserID: "u_me").map(\.groupId), ["g2"])
    }
}
