import XCTest
@testable import AgentCore

final class SidebarPinsTests: XCTestCase {
    func testTogglePinsAndUnpinsInPinOrder() {
        var pins = SidebarPins()
        XCTAssertTrue(pins.toggle("bot:a"))
        XCTAssertTrue(pins.toggle("group:g"))
        XCTAssertTrue(pins.toggle("bot:b"))
        XCTAssertEqual(pins.ids, ["bot:a", "group:g", "bot:b"])
        XCTAssertFalse(pins.toggle("group:g"))
        XCTAssertEqual(pins.ids, ["bot:a", "bot:b"])
        XCTAssertFalse(pins.contains("group:g"))
    }

    func testDuplicatesInStoredDataAreCollapsed() {
        XCTAssertEqual(SidebarPins(ids: ["bot:a", "bot:b", "bot:a"]).ids, ["bot:a", "bot:b"])
    }

    func testMoveReordersAndIgnoresUnknownIDs() {
        var pins = SidebarPins(ids: ["bot:a", "bot:b", "bot:c"])
        pins.move("bot:c", before: "bot:a")
        XCTAssertEqual(pins.ids, ["bot:c", "bot:a", "bot:b"])
        pins.move("bot:x", before: "bot:a")
        pins.move("bot:a", before: "bot:x")
        pins.move("bot:a", before: "bot:a")
        XCTAssertEqual(pins.ids, ["bot:c", "bot:a", "bot:b"])
    }

    func testPruneDropsDeletedItemsOnly() {
        var pins = SidebarPins(ids: ["bot:a", "group:gone", "bot:b"])
        pins.prune(keeping: ["bot:a", "bot:b", "group:other"])
        XCTAssertEqual(pins.ids, ["bot:a", "bot:b"])
    }

    func testPersistenceRoundTrip() {
        let suite = UserDefaults(suiteName: "pins-test-\(UUID().uuidString)")!
        var pins = SidebarPins()
        pins.toggle(SidebarPins.botID("x")); pins.toggle(SidebarPins.groupID("y"))
        pins.save(to: suite)
        XCTAssertEqual(SidebarPins.load(from: suite), pins)
        XCTAssertEqual(SidebarPins.load(from: UserDefaults(suiteName: "pins-empty-\(UUID().uuidString)")!).ids, [])
    }
}
