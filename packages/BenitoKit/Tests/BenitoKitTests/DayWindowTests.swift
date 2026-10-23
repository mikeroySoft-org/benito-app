import XCTest
@testable import BenitoKit

final class DayWindowTests: XCTestCase {
    private func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    func testWindowIsLocalMidnightToMidnight() {
        let cal = calendar("America/Los_Angeles")
        let w = DayWindow(containing: date("2026-10-23T18:30:00Z"), calendar: cal)
        XCTAssertEqual(w.start, date("2026-10-23T07:00:00Z"))
        XCTAssertEqual(w.end, date("2026-10-24T07:00:00Z"))
    }

    func testOffsetAcrossDSTIsStill23HourLocalDay() {
        let cal = calendar("America/Los_Angeles")
        let w = DayWindow(offset: -1, from: date("2026-03-09T20:00:00Z"), calendar: cal)
        XCTAssertEqual(w.start, date("2026-03-08T08:00:00Z"))
        XCTAssertEqual(w.end, date("2026-03-09T07:00:00Z"))
    }

    func testTodayCaptionFollowsLocaleClock() {
        let cal = calendar("America/Los_Angeles")
        let now = date("2026-10-23T18:30:00Z")
        let w = DayWindow(containing: now, calendar: cal)
        XCTAssertEqual(normalized(w.coverageLabel(now: now, calendar: cal, locale: Locale(identifier: "en_US"))), "Since 12 AM")
        // 24-hour locales keep minutes and drop AM/PM ("Since 00:00" / "Since 0:00" by OS data).
        let gb = normalized(w.coverageLabel(now: now, calendar: cal, locale: Locale(identifier: "en_GB")))
        XCTAssertTrue(gb.hasPrefix("Since ") && gb.hasSuffix("0:00"), gb)
        XCTAssertFalse(gb.contains("AM"), gb)
    }

    func testPastDayCaptionShowsWholeSpan() {
        let cal = calendar("America/Los_Angeles")
        let now = date("2026-10-23T18:30:00Z")
        let yesterday = DayWindow(offset: -1, from: now, calendar: cal)
        XCTAssertEqual(yesterday.coverageLabel(now: now, calendar: cal, locale: Locale(identifier: "en_US")), "Midnight to midnight")
    }

    func testNonMidnightCutoffIsLabelledFromWindow() {
        let cal = calendar("America/Los_Angeles")
        let w = DayWindow(start: date("2026-10-22T13:00:00Z"), end: date("2026-10-23T13:00:00Z"))
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(normalized(w.sinceLabel(calendar: cal, locale: us)), "Since 6 AM")
        XCTAssertEqual(normalized(w.spanLabel(calendar: cal, locale: us)), "6 AM – 6 AM")
        let half = DayWindow(start: date("2026-10-22T13:30:00Z"), end: date("2026-10-23T13:30:00Z"))
        XCTAssertEqual(normalized(half.sinceLabel(calendar: cal, locale: us)), "Since 6:30 AM")
    }

    /// Foundation separates time and AM/PM with a narrow no-break space.
    private func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
