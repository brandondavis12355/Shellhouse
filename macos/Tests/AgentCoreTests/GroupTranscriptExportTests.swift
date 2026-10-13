import XCTest
@testable import AgentCore

final class GroupTranscriptExportTests: XCTestCase {
    func testMarkdownListsSpeakersTimesAndNotices() {
        let t = Date(timeIntervalSince1970: 1_760_000_000)
        let md = GroupTranscriptExport.markdown(groupName: "Team", members: ["You", "Atlas"], lines: [
            .init(time: t, speaker: "You", text: "Clone the repo", kind: .user),
            .init(time: t, speaker: "Atlas", text: "Done.\nTests pass.", kind: .bot),
            .init(time: t, speaker: "", text: "Goal set: ship it", kind: .notice),
            .init(time: t, speaker: "Sam", text: "nice", kind: .friend),
        ], exportedAt: t, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(md.hasPrefix("# Team\n"))
        XCTAssertTrue(md.contains("Members: You, Atlas"))
        XCTAssertTrue(md.contains("**Atlas** (bot) · 2025-10-09 08:53\n\nDone.\nTests pass."))
        XCTAssertTrue(md.contains("*2025-10-09 08:53 · Goal set: ship it*"))
        XCTAssertTrue(md.contains("**Sam** (friend)"))
        XCTAssertTrue(md.contains("4 messages"))
    }

    func testFileNameIsSafe() {
        let name = GroupTranscriptExport.fileName(groupName: "Ops / Q4: review*", date: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertTrue(name.hasPrefix("Ops-Q4-review-transcript-"))
        XCTAssertTrue(name.hasSuffix(".md"))
        XCTAssertFalse(name.contains("/"))
    }
}
