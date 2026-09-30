import XCTest
@testable import AgentCore

final class GroupWakePlannerTests: XCTestCase {
    private typealias M = GroupWakePlanner.Message
    private func user(_ mentions: Set<String> = []) -> M { M(authorID: nil, mentionedIDs: mentions) }
    private func bot(_ id: String, _ mentions: Set<String> = []) -> M { M(authorID: id, mentionedIDs: mentions) }
    private func decide(_ id: String, _ messages: [M], seen: Int = 0, cap: Int = 40) -> GroupWakePlanner.Decision {
        GroupWakePlanner.decide(botID: id, messages: messages, seenCount: seen, maxBotMessages: cap)
    }

    func testNothingNewMeansNone() {
        XCTAssertEqual(decide("a", [user()], seen: 1), .none)
        XCTAssertEqual(decide("a", []), .none)
    }

    func testOwnMessagesNeverWakeSelf() {
        XCTAssertEqual(decide("a", [bot("a", ["a"])]), .none)
    }

    func testUserMentionMustReply() {
        XCTAssertEqual(decide("a", [user(["a"])]), .mustReply)
    }

    func testUserMessageWithoutMentionIsOptional() {
        XCTAssertEqual(decide("a", [user(["b"])]), .optional)
        XCTAssertEqual(decide("a", [user()]), .optional)
    }

    /// The reported bug: A @mentions B, B answers @mentioning A — the chain must continue.
    func testBotMentionWakesTargetAndChainContinues() {
        XCTAssertEqual(decide("b", [user(["a"]), bot("a", ["b"])], seen: 1), .mentionedByBot)
        XCTAssertEqual(decide("a", [user(["a"]), bot("a", ["b"]), bot("b", ["a"])], seen: 2), .mentionedByBot)
    }

    func testUserMentionOutranksBotMention() {
        XCTAssertEqual(decide("a", [bot("b", ["a"]), user(["a"])]), .mustReply)
    }

    func testOnlyUnseenMessagesCount() {
        XCTAssertEqual(decide("a", [user(["a"]), bot("b")], seen: 1), .optional)
    }

    func testBotChatterStopsAtCapButUserResetsIt() {
        let chatter = [user()] + (0..<5).map { _ in bot("b", ["a"]) }
        // The opening user message (index 0) was already seen.
        XCTAssertEqual(decide("a", chatter, seen: 1, cap: 5), .none)
        XCTAssertEqual(decide("a", chatter, seen: 1, cap: 6), .mentionedByBot)
        XCTAssertEqual(decide("a", chatter + [user(["a"])], seen: 1, cap: 5), .mustReply)
    }

    func testSeenCountBeyondMessagesIsSafe() {
        XCTAssertEqual(decide("a", [user()], seen: 99), .none)
        XCTAssertEqual(decide("a", [user()], seen: -3), .optional)
    }

    private func sys() -> M { M(authorID: nil, mentionedIDs: [], isSystem: true) }

    func testSystemMessagesNeverWakeOrCount() {
        XCTAssertEqual(decide("a", [sys()]), .none)
        let chatter = [user()] + (0..<3).map { _ in bot("b", ["a"]) } + [sys(), sys()]
        XCTAssertEqual(decide("a", chatter, seen: 1, cap: 4), .mentionedByBot)   // 3 bot msgs < cap 4
        XCTAssertEqual(decide("a", chatter, seen: 1, cap: 3), .none)             // system lines didn't reset the tail
    }

    func testGoalStatusRules() {
        func d(_ status: GroupGoal.Status?, _ m: [M] = [user(), bot("b", ["a"])]) -> GroupWakePlanner.Decision {
            GroupWakePlanner.decide(botID: "a", messages: m, seenCount: 1, maxBotMessages: 1, goalStatus: status)
        }
        XCTAssertEqual(d(nil), .none)                       // flat cap applies with no goal
        XCTAssertEqual(d(.active), .mentionedByBot)         // goal counter replaces the flat cap
        XCTAssertEqual(d(.paused), .none)                   // paused: bots don't wake each other
        XCTAssertEqual(d(.paused, [user(), bot("b"), user()]), .optional)  // ...but a user message wakes them
        XCTAssertEqual(d(.awaitingConfirmation), .mentionedByBot)
        XCTAssertEqual(d(.awaitingConfirmation, [user(), bot("b")]), .none)  // no optional turns while awaiting
    }

    private func friend(_ mentions: Set<String> = []) -> M { M(authorID: nil, mentionedIDs: mentions, isExternal: true) }

    func testFriendMentionMustBeAnswered() {
        XCTAssertEqual(decide("a", [friend(["a"])]), .mustReply)
        XCTAssertEqual(decide("a", [friend()]), .optional)
    }

    func testFriendCannotResumeAPausedGoal() {
        func d(_ m: [M]) -> GroupWakePlanner.Decision {
            GroupWakePlanner.decide(botID: "a", messages: m, seenCount: 0, maxBotMessages: 40, goalStatus: .paused)
        }
        XCTAssertEqual(d([friend(["a"])]), .none, "a friend's message must not un-pause")
        XCTAssertEqual(d([user(["a"])]), .mustReply, "the owner's message does")
        XCTAssertEqual(d([friend(["a"]), user()]), .mustReply, "once the owner speaks, the friend's mention is answered too")
    }

    func testFriendCountsAsHumanForBotChatterCap() {
        let chatter = [friend()] + (0..<5).map { _ in bot("b", ["a"]) }
        XCTAssertEqual(decide("a", chatter, seen: 1, cap: 5), .none)
        XCTAssertEqual(decide("a", chatter + [friend(["a"])], seen: 1, cap: 5), .mustReply)
    }
}
