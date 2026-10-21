import XCTest
@testable import AgentCore

final class PointerBusTests: XCTestCase {
    func testThePointerIsShownBeforeTheCallerActs() async {
        final class Box: @unchecked Sendable { var seen: (Int, Int, Bool)?; var at: Date? }
        let box = Box()
        PointerBus.setHandler({ x, y, c in box.seen = (x, y, c); box.at = Date() }, for: "vm-test")
        let start = Date()
        await PointerBus.moveAndWait(sandboxID: "vm-test", x: 10, y: 20, clicked: true)
        XCTAssertEqual(box.seen?.0, 10); XCTAssertEqual(box.seen?.2, true)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), PointerBus.arrival - 0.05, "it waits for the pointer to arrive")
        XCTAssertLessThan(box.at!.timeIntervalSince(start), 0.2, "and shows it straight away")
        PointerBus.setHandler(nil, for: "vm-test")
    }

    func testNothingWatchingMeansNoWait() async {
        let start = Date()
        await PointerBus.moveAndWait(sandboxID: "nobody", x: 1, y: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
    }
}
