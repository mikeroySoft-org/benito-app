import XCTest
@testable import BenitoKit

final class DailyFedTotalsTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_790_000_000)
    private var dayEnd: Date { day.addingTimeInterval(86_400) }

    private func event(
        _ type: EventType,
        start: TimeInterval,
        end: TimeInterval? = nil,
        amount: Double? = nil,
        unit: String? = nil,
        deleted: Bool = false
    ) -> EventDTO {
        EventDTO(
            id: UUID(),
            childId: UUID(),
            type: type.rawValue,
            subtype: nil,
            startedAt: day.addingTimeInterval(start),
            endedAt: end.map { day.addingTimeInterval($0) },
            amountValue: amount,
            amountUnit: unit,
            side: nil,
            notes: nil,
            payloadJson: nil,
            createdBy: UUID(),
            createdAt: day,
            updatedAt: day,
            deletedAt: deleted ? day : nil
        )
    }

    func testNursingIsClippedToTheDayAndBottlesKeepUnits() {
        let events = [
            // 23:50 the night before → 00:10: only 10 min count.
            event(.feedBreast, start: -600, end: 600),
            event(.feedBreast, start: 3_600, end: 3_600 + 900),
            event(.feedBottle, start: 7_200, amount: 3, unit: "oz"),
            event(.feedBottle, start: 9_000, amount: 60, unit: "ml"),
            event(.feedBottle, start: 9_500, amount: 4, unit: nil),
            event(.feedBottle, start: 10_000, amount: 5, unit: "oz", deleted: true),
            // Starts tomorrow: ignored.
            event(.feedBottle, start: 90_000, amount: 2, unit: "oz"),
        ]
        let totals = DailyFedTotals(events: events, from: day, to: dayEnd)
        XCTAssertEqual(totals.nursingSeconds, 1_500, accuracy: 0.5)
        XCTAssertEqual(totals.bottleOunces, 7)
        XCTAssertEqual(totals.bottleMilliliters, 60)
        XCTAssertEqual(totals.bottleOuncesTotal, 7 + 60 / 29.5735, accuracy: 0.001)
        XCTAssertFalse(totals.isEmpty)
    }

    /// Regression: a nursing log with no end (live row 91f2e5ef, Sep 27) counted as nursing
    /// from midnight until now on every later day, e.g. "12h 12m" on Oct 23.
    func testNursingWithoutEndAddsNoTime() {
        let events = [
            event(.feedBreast, start: -26 * 86_400),
            event(.feedBreast, start: 3_600),
            event(.feedBreast, start: 7_200, end: 7_200 + 900),
        ]
        let totals = DailyFedTotals(events: events, from: day, to: dayEnd)
        XCTAssertEqual(totals.nursingSeconds, 900, accuracy: 0.5)
        XCTAssertFalse(totals.hasBottle)
    }

    func testSummaryDecodesNursingSecondsWhenPresent() throws {
        let json = """
        {"child_id":"\(UUID().uuidString)","from":"2026-10-05T00:00:00Z","to":"2026-10-06T00:00:00Z",
         "feed_breast_count":2,"feed_breast_left":1,"feed_breast_right":1,"feed_bottle_count":1,
         "bottle_oz_total":3,"bottle_ml_total":60,"bottle_oz_equiv":5.03,"feed_solid_count":0,
         "feed_seconds":1800,"nursing_seconds":1500,"diaper_wet":0,"diaper_dirty":0,"diaper_both":0,
         "diaper_other":0,"sleep_event_count":0,"sleep_hours":0,"pump_count":0,"medicine_count":0,
         "total_events":3}
        """
        let summary = try BenitoJSON.decoder.decode(DailySummaryDTO.self, from: Data(json.utf8))
        let totals = DailyFedTotals(summary: summary, fallbackNursingSeconds: 99)
        XCTAssertEqual(totals.nursingSeconds, 1_500)
        XCTAssertEqual(totals.bottleOunces, 3)
        XCTAssertEqual(totals.bottleMilliliters, 60)
    }
}
