import XCTest
@testable import AgentCore

final class MessageTimeTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    private let locale = Locale(identifier: "en_US")

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func label(_ d: Date, now: Date) -> String {
        MessageTime.label(for: d, now: now, calendar: calendar, locale: locale)
    }

    func testTodayShowsTimeOnly() {
        let now = date(2026, 10, 9, 15, 0)
        let l = label(date(2026, 10, 9, 9, 5), now: now)
        XCTAssertTrue(l.contains("9:05"), l)
        XCTAssertFalse(l.contains("Oct"), l)
        XCTAssertFalse(l.contains("Yesterday"), l)
    }

    func testYesterdayIsNamed() {
        let l = label(date(2026, 10, 8, 23, 30), now: date(2026, 10, 9, 0, 10))
        XCTAssertTrue(l.hasPrefix("Yesterday "), l)
        XCTAssertTrue(l.contains("11:30"), l)
    }

    func testEarlierThisYearShowsMonthAndDay() {
        let l = label(date(2026, 3, 4, 14, 0), now: date(2026, 10, 9, 15, 0))
        XCTAssertTrue(l.contains("Mar") && l.contains("4"), l)
        XCTAssertFalse(l.contains("2026"), l)
    }

    func testPreviousYearIncludesYear() {
        let l = label(date(2025, 12, 31, 8, 0), now: date(2026, 1, 2, 8, 0))
        XCTAssertTrue(l.contains("2025") && l.contains("Dec"), l)
    }
}
