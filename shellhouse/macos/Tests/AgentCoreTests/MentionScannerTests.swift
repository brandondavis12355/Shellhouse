import XCTest
@testable import AgentCore

final class MentionScannerTests: XCTestCase {
    private let known: Set<String> = ["bugbot", "cleo", "tai lung", "dr. eggbot"]
    private func names(_ text: String) -> Set<String> { MentionScanner.matchedNames(in: text, knownNames: known) }

    func testAMentionAfterAParagraphBreakIsRecognized() {
        // Mr. Smith's real message: the first mention follows a blank line.
        let text = "My VM is verified: `gh` is installed, exit 0.\n\n@Bugbot @Cleo @Tai Lung — please confirm `gh` on your own VMs."
        XCTAssertEqual(names(text), ["bugbot", "cleo", "tai lung"])
    }

    func testMentionsAtTheStartOfLinesAndAfterBracketsOrQuotes() {
        XCTAssertEqual(names("Team:\n@Cleo do this\n@Bugbot and that"), ["cleo", "bugbot"])
        XCTAssertEqual(names("(@Cleo) and \"@Bugbot\" please"), ["cleo", "bugbot"])
    }

    func testMultiWordNamesWorkButNeverSpanALineBreak() {
        XCTAssertEqual(names("hi @Dr. EggBot, hello"), ["dr. eggbot"])
        XCTAssertEqual(names("@Tai\nLung is not a mention"), [])
        XCTAssertEqual(names("@Tai Lung\nnext line"), ["tai lung"])
    }

    func testEveryoneAndUnknownNames() {
        XCTAssertEqual(names("@everyone assemble"), ["everyone"])
        XCTAssertEqual(names("@nobody here, and email me@bugbot.com"), [])
    }

    func testLineBreaksSurviveRebuilding() {
        let text = "line one\n\n@Cleo hello\nthird"
        let rebuilt = MentionScanner.segments(for: text, knownNames: known).enumerated().map { index, segment -> String in
            switch segment {
            case .word(let sep, let word): return (index > 0 ? sep : "") + word
            case .mention(let sep, let display, _): return (index > 0 ? sep : "") + display
            }
        }.joined()
        XCTAssertEqual(rebuilt, text)
    }
}
