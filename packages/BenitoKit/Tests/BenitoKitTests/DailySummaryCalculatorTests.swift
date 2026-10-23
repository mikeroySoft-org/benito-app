import XCTest
@testable import BenitoKit

/// On-device Day summaries use the server's rules (server/src/routes/summary.rs).
final class DailySummaryCalculatorTests: XCTestCase {
    private let child = UUID()
    private let from = Date(timeIntervalSince1970: 1_760_000_000)

    private func event(_ type: String, subtype: String? = nil, start: TimeInterval, end: TimeInterval? = nil,
                       amount: Double? = nil, unit: String? = nil, side: String? = nil) -> EventDTO {
        EventDTO(id: UUID(), childId: child, type: type, subtype: subtype,
                 startedAt: from.addingTimeInterval(start), endedAt: end.map { from.addingTimeInterval($0) },
                 amountValue: amount, amountUnit: unit, side: side, notes: nil, payloadJson: nil,
                 createdBy: UUID(), createdAt: from, updatedAt: from, deletedAt: nil)
    }

    func testWindowPrecedence() throws {
        let now = from.addingTimeInterval(1000)
        let explicit = try DailySummaryCalculator.window(day: "2026-01-01", from: from, to: now, now: now)
        XCTAssertEqual(explicit.from, from)
        let day = try DailySummaryCalculator.window(day: "2026-10-23", from: nil, to: nil, now: now)
        XCTAssertEqual(day.to.timeIntervalSince(day.from), 86_400)
        XCTAssertEqual(BenitoJSON.string(from: day.from), "2026-10-23T00:00:00.000Z")
        let rolling = try DailySummaryCalculator.window(day: nil, from: nil, to: nil, now: now)
        XCTAssertEqual(rolling.to, now)
        XCTAssertThrowsError(try DailySummaryCalculator.window(day: nil, from: now, to: from, now: now))
        XCTAssertThrowsError(try DailySummaryCalculator.window(day: "23/10/2026", from: nil, to: nil, now: now))
    }

    func testTotals() {
        let events = [
            event("feed_breast", start: 0, end: 600, side: "L"),
            event("feed_bottle", start: 3600, amount: 4, unit: "oz"),
            event("feed_bottle", start: 7200, amount: 60, unit: "ml"),
            event("diaper", subtype: "wet", start: 100),
            event("diaper", subtype: "both", start: 200),
            event("sleep", start: -1800, end: 3600), // clipped to the window: 1 h
        ]
        let s = DailySummaryCalculator.summarize(childId: child, events: events, from: from,
                                                 to: from.addingTimeInterval(86_400), day: nil)
        XCTAssertEqual(s.feedBreastCount, 1)
        XCTAssertEqual(s.feedBreastLeft, 1)
        XCTAssertEqual(s.feedBottleCount, 2)
        XCTAssertEqual(s.bottleOzTotal, 4)
        XCTAssertEqual(s.bottleMlTotal, 60)
        XCTAssertEqual(s.diaperWet, 1)
        XCTAssertEqual(s.diaperBoth, 1)
        XCTAssertEqual(s.sleepEventCount, 1)
        XCTAssertEqual(s.sleepHours, 1)
    }
}
