import XCTest
@testable import ForefrontQueue

/// ISC-153: the masthead's pure logic — day-part bucketing, weekday naming,
/// count pluralization, and the assembled line. All locale/timezone-pinned so
/// they are deterministic regardless of the machine running them.
final class MastheadTests: XCTestCase {

    /// A calendar pinned to a fixed timezone + Gregorian + en_US so weekday
    /// symbols and hour extraction are deterministic.
    private func fixedCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US")
        return cal
    }

    // MARK: - DayPart boundaries

    func testDayPartBoundaries() {
        XCTAssertEqual(DayPart.from(hour: 5), .morning)
        XCTAssertEqual(DayPart.from(hour: 11), .morning)
        XCTAssertEqual(DayPart.from(hour: 12), .afternoon)
        XCTAssertEqual(DayPart.from(hour: 16), .afternoon)
        XCTAssertEqual(DayPart.from(hour: 17), .evening)
        XCTAssertEqual(DayPart.from(hour: 23), .evening)
        // Pre-dawn small hours read as evening (no "night" bucket).
        XCTAssertEqual(DayPart.from(hour: 0), .evening)
        XCTAssertEqual(DayPart.from(hour: 4), .evening)
    }

    // MARK: - Weekday + day-part greeting

    func testGreetingWeekdayAndDayPart() {
        let cal = fixedCalendar()
        // 2026-07-07 is a Tuesday. 09:00 UTC → morning.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 7; comps.hour = 9
        let date = cal.date(from: comps)!
        let masthead = Masthead(date: date, cardCount: 6, calendar: cal, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(masthead.greeting, "Tuesday morning")
        XCTAssertEqual(masthead.line, "Tuesday morning — 6 cards")
    }

    func testGreetingAfternoonAndEvening() {
        let cal = fixedCalendar()
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 7; comps.hour = 14  // Tuesday afternoon
        let afternoon = Masthead(date: cal.date(from: comps)!, cardCount: 3, calendar: cal, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(afternoon.greeting, "Tuesday afternoon")

        comps.hour = 20  // Tuesday evening
        let evening = Masthead(date: cal.date(from: comps)!, cardCount: 3, calendar: cal, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(evening.greeting, "Tuesday evening")
    }

    // MARK: - Count pluralization

    func testCardCountPluralization() {
        let cal = fixedCalendar()
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 7; comps.hour = 9
        let date = cal.date(from: comps)!
        let locale = Locale(identifier: "en_US")

        XCTAssertEqual(Masthead(date: date, cardCount: 0, calendar: cal, locale: locale).cardCountText, "No cards")
        XCTAssertEqual(Masthead(date: date, cardCount: 1, calendar: cal, locale: locale).cardCountText, "1 card")
        XCTAssertEqual(Masthead(date: date, cardCount: 6, calendar: cal, locale: locale).cardCountText, "6 cards")
    }
}
