import XCTest
@testable import BenitoKit

final class ActivityKindTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_790_000_000)
    private var dayEnd: Date { day.addingTimeInterval(86_400) }

    private func activity(
        _ subtype: String,
        start: TimeInterval,
        end: TimeInterval?,
        pausedSeconds: Double? = nil,
        deleted: Bool = false
    ) -> EventDTO {
        EventDTO(
            id: UUID(),
            childId: UUID(),
            type: EventType.activity.rawValue,
            subtype: subtype,
            startedAt: day.addingTimeInterval(start),
            endedAt: end.map { day.addingTimeInterval($0) },
            amountValue: nil,
            amountUnit: nil,
            side: nil,
            notes: nil,
            payloadJson: pausedSeconds.map { .object(["paused_seconds": .number($0)]) },
            createdBy: UUID(),
            createdAt: day,
            updatedAt: day,
            deletedAt: deleted ? day : nil
        )
    }

    func testTimerKindRoundTrip() {
        for kind in ActivityKind.allCases {
            XCTAssertEqual(ActivityKind(timerKind: kind.timerKind), kind)
        }
        XCTAssertEqual(ActivityKind(timerKind: " Car_Ride "), .carRide)
        XCTAssertEqual(ActivityKind(timerKind: "CRYING"), .crying)
    }

    func testFeedAndSleepTimersAreNotActivities() {
        XCTAssertNil(ActivityKind(timerKind: "sleep"))
        XCTAssertNil(ActivityKind(timerKind: "feed_breast"))
        XCTAssertNil(ActivityKind(timerKind: nil))
    }

    func testOutingsExcludeCrying() {
        XCTAssertEqual(ActivityKind.outings, [.walk, .carRide])
        XCTAssertFalse(ActivityKind.crying.isOuting)
        XCTAssertTrue(ActivityKind.carRide.isOuting)
    }

    func testCryingSecondsClipAtMidnightAndSkipPausesAndOutings() {
        let events = [
            // 23:50 the night before → 00:10: only 10 min count.
            activity("crying", start: -600, end: 600),
            // 30 min wall clock, 10 min paused → 20 min.
            activity("crying", start: 3_600, end: 3_600 + 1_800, pausedSeconds: 600),
            // Walks and deleted spells never count.
            activity("walk", start: 7_200, end: 9_000),
            activity("crying", start: 10_000, end: 11_000, deleted: true),
            // No end recorded: a one-off log, adds no time.
            activity("crying", start: 20_000, end: nil),
        ]
        let seconds = ActivityKind.crying.activeSeconds(in: events, from: day, to: dayEnd)
        XCTAssertEqual(seconds, 600 + 1_200, accuracy: 0.5)
        XCTAssertEqual(ActivityKind.walk.activeSeconds(in: events, from: day, to: dayEnd), 1_800, accuracy: 0.5)
    }

    func testSummaryDecodesCryingSeconds() throws {
        let json = """
        {"child_id":"\(UUID().uuidString)","from":"2026-10-23T07:00:00Z","to":"2026-10-24T07:00:00Z",
         "feed_breast_count":0,"feed_breast_left":0,"feed_breast_right":0,"feed_bottle_count":0,
         "bottle_oz_total":0,"bottle_ml_total":0,"bottle_oz_equiv":0,"feed_solid_count":0,
         "crying_seconds":1500,"diaper_wet":0,"diaper_dirty":0,"diaper_both":0,"diaper_other":0,
         "sleep_event_count":0,"sleep_hours":0,"pump_count":0,"medicine_count":0,"total_events":0}
        """
        let summary = try BenitoJSON.decoder.decode(DailySummaryDTO.self, from: Data(json.utf8))
        XCTAssertEqual(summary.cryingSeconds, 1_500)
        XCTAssertNil(summary.nursingSeconds)
    }
}
