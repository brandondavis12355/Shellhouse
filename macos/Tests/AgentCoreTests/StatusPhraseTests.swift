import XCTest
@testable import AgentCore

final class StatusPhraseTests: XCTestCase {
    func testJoinNames() {
        XCTAssertEqual(StatusPhrase.joinNames([]), "")
        XCTAssertEqual(StatusPhrase.joinNames(["Mr. Smith"]), "Mr. Smith")
        XCTAssertEqual(StatusPhrase.joinNames(["Mr. Smith", "Bugbot"]), "Mr. Smith and Bugbot")
        XCTAssertEqual(StatusPhrase.joinNames(["Mr. Smith", "Bugbot", "Tai Lung"]), "Mr. Smith, Bugbot, and Tai Lung")
        XCTAssertEqual(StatusPhrase.joinNames(["A", "B", "C", "D"]), "A, B, C, and D")
    }

    func testVerbAgreesWithCount() {
        XCTAssertEqual(StatusPhrase.sentence(names: ["Cleo"], singular: "is working…", plural: "are working…"), "Cleo is working…")
        XCTAssertEqual(StatusPhrase.sentence(names: ["Cleo", "Bugbot"], singular: "is working…", plural: "are working…"), "Cleo and Bugbot are working…")
        XCTAssertEqual(StatusPhrase.sentence(names: [], singular: "is", plural: "are"), "")
    }

    func testColorIndexAdvancesAndWraps() {
        XCTAssertEqual(StatusPhrase.colorIndex(at: 0, interval: 2.5, count: 3), 0)
        XCTAssertEqual(StatusPhrase.colorIndex(at: 2.4, interval: 2.5, count: 3), 0)
        XCTAssertEqual(StatusPhrase.colorIndex(at: 2.5, interval: 2.5, count: 3), 1)
        XCTAssertEqual(StatusPhrase.colorIndex(at: 7.6, interval: 2.5, count: 3), 0)   // 3rd step wraps
        XCTAssertEqual(StatusPhrase.colorIndex(at: 100, interval: 2.5, count: 1), 0)
        XCTAssertEqual(StatusPhrase.colorIndex(at: 5, interval: 2.5, count: 0), 0)
    }
}
