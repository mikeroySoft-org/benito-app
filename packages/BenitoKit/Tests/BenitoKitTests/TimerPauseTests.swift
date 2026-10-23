import XCTest
@testable import BenitoKit

final class TimerPauseTests: XCTestCase {
    private func at(_ seconds: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(seconds))
    }

    private func timer(
        id: UUID = UUID(),
        childId: UUID = UUID(),
        state: String = "running",
        startedAt: Int = 0,
        pausedAt: Int? = nil,
        pausedSeconds: Int = 0
    ) -> TimerDTO {
        TimerDTO(
            id: id,
            childId: childId,
            kind: "feed_breast",
            startedAt: at(startedAt),
            startedBy: UUID(),
            state: state,
            stoppedAt: nil,
            updatedAt: at(pausedAt ?? startedAt),
            side: "L",
            pausedAt: pausedAt.map(at),
            pausedSeconds: pausedSeconds
        )
    }

    private func sleepEvent(startedAt: Int, endedAt: Int?, payload: JSONValue?) -> EventDTO {
        EventDTO(
            id: UUID(),
            childId: UUID(),
            type: EventType.sleep.rawValue,
            subtype: nil,
            startedAt: at(startedAt),
            endedAt: endedAt.map(at),
            amountValue: nil,
            amountUnit: nil,
            side: nil,
            notes: nil,
            payloadJson: payload,
            createdBy: UUID(),
            createdAt: at(startedAt),
            updatedAt: at(endedAt ?? startedAt),
            deletedAt: nil
        )
    }


    // MARK: - Decoding

    func testTimerDecodesWithoutPauseKeys() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","child_id":"\(UUID().uuidString)","kind":"sleep",
         "started_at":"2026-01-01T10:00:00Z","started_by":"\(UUID().uuidString)",
         "state":"running","stopped_at":null,"updated_at":"2026-01-01T10:00:00Z"}
        """.utf8)
        let timer = try BenitoJSON.decoder.decode(TimerDTO.self, from: json)
        XCTAssertNil(timer.pausedAt)
        XCTAssertEqual(timer.pausedSeconds, 0)
        XCTAssertFalse(timer.isPaused)
        XCTAssertTrue(timer.isActive)
    }

    func testTimerDecodesPauseKeys() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","child_id":"\(UUID().uuidString)","kind":"feed_breast",
         "started_at":"2026-01-01T10:00:00Z","started_by":"\(UUID().uuidString)",
         "state":"paused","stopped_at":null,"updated_at":"2026-01-01T10:05:00Z","side":"R",
         "paused_at":"2026-01-01T10:05:00Z","paused_seconds":42}
        """.utf8)
        let timer = try BenitoJSON.decoder.decode(TimerDTO.self, from: json)
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T10:00:00Z"))
        XCTAssertEqual(timer.pausedAt, start.addingTimeInterval(300))
        XCTAssertEqual(timer.pausedSeconds, 42)
        XCTAssertTrue(timer.isPaused)
        XCTAssertTrue(timer.isActive)
    }

    func testStoppedTimerIsNotActive() {
        XCTAssertFalse(timer(state: "stopped").isActive)
        XCTAssertFalse(timer(state: "stopped").isPaused)
    }

    func testTimerEncodeDecodeRoundTripKeepsPauseFields() throws {
        let original = timer(state: "paused", pausedAt: 600, pausedSeconds: 30)
        let data = try BenitoJSON.encoder.encode(original)
        let decoded = try BenitoJSON.decoder.decode(TimerDTO.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Elapsed

    func testElapsedRunningWithoutPauses() {
        XCTAssertEqual(timer().elapsed(at: at(120)), 120)
    }

    func testElapsedRunningExcludesCompletedPauses() {
        XCTAssertEqual(timer(pausedSeconds: 50).elapsed(at: at(200)), 150)
    }

    func testElapsedPausedIsFrozenAtPausedAt() {
        let t = timer(state: "paused", pausedAt: 300, pausedSeconds: 60)
        XCTAssertEqual(t.elapsed(at: at(300)), 240)
        XCTAssertEqual(t.elapsed(at: at(10_000)), 240)
    }

    func testElapsedNeverNegative() {
        XCTAssertEqual(timer(startedAt: 100).elapsed(at: at(0)), 0)
        XCTAssertEqual(timer(pausedSeconds: 500).elapsed(at: at(100)), 0)
        XCTAssertEqual(timer(state: "paused", startedAt: 100, pausedAt: 50).elapsed(at: at(200)), 0)
    }

    func testEffectiveStartShiftsByCompletedPauses() {
        XCTAssertEqual(timer().effectiveStart, at(0))
        let t = timer(startedAt: 10, pausedSeconds: 90)
        XCTAssertEqual(t.effectiveStart, at(100))
        // Count-up from effectiveStart matches elapsed for a running timer.
        XCTAssertEqual(at(400).timeIntervalSince(t.effectiveStart), t.elapsed(at: at(400)))
    }


    func testElapsedUsesDeviceNowAgainstPhoneAuthoredTimestamps() {
        // startedAt / pausedAt are phone-local values stored by the server; no skew transform.
        XCTAssertEqual(timer().elapsed(at: at(0)), 0, accuracy: 0.001)
        XCTAssertEqual(timer().elapsed(at: at(120)), 120, accuracy: 0.001)
        let paused = timer(state: "paused", pausedAt: 300, pausedSeconds: 60)
        XCTAssertEqual(paused.elapsed(at: at(10_000)), 240, accuracy: 0.001)
    }

    // MARK: - Event active duration

    func testActiveDurationWithoutPayload() {
        let e = sleepEvent(startedAt: 0, endedAt: 3_600, payload: nil)
        XCTAssertEqual(e.pausedSeconds, 0)
        XCTAssertEqual(e.activeDuration, 3_600)
    }

    func testActiveDurationSubtractsPausedSeconds() {
        let e = sleepEvent(startedAt: 0, endedAt: 3_600, payload: .object(["paused_seconds": .number(600)]))
        XCTAssertEqual(e.pausedSeconds, 600)
        XCTAssertEqual(e.activeDuration, 3_000)
    }

    func testActiveDurationIgnoresUnrelatedPayloadAndOpenEvents() {
        let other = sleepEvent(startedAt: 0, endedAt: 100, payload: .object(["mood": .string("fussy")]))
        XCTAssertEqual(other.pausedSeconds, 0)
        XCTAssertEqual(other.activeDuration, 100)
        XCTAssertEqual(sleepEvent(startedAt: 0, endedAt: 100, payload: .string("x")).activeDuration, 100)
        XCTAssertNil(sleepEvent(startedAt: 0, endedAt: nil, payload: nil).activeDuration)
    }

    func testActiveDurationDecodedFromServerPayload() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","child_id":"\(UUID().uuidString)","type":"feed_breast",
         "started_at":"2026-01-01T10:00:00Z","ended_at":"2026-01-01T10:20:00Z",
         "payload_json":{"paused_seconds":120},"created_by":"\(UUID().uuidString)",
         "created_at":"2026-01-01T10:20:00Z","updated_at":"2026-01-01T10:20:00Z"}
        """.utf8)
        let e = try BenitoJSON.decoder.decode(EventDTO.self, from: json)
        XCTAssertEqual(e.pausedSeconds, 120)
        XCTAssertEqual(e.activeDuration, 1_080)
    }

    // MARK: - Stores

    private func assertPausedTimerIsActiveThenCleared(_ store: any BenitoStore) async throws {
        let childId = UUID()
        let paused = timer(childId: childId, state: "paused", pausedAt: 300, pausedSeconds: 45)
        try await store.upsertTimer(paused)

        let active = try await store.activeTimers(childId: childId)
        XCTAssertEqual(active, [paused])
        let glance = try await store.localBabyState(childId: childId)
        XCTAssertEqual(glance.activeTimer, paused)

        try await store.applyBabyState(
            BabyStateDTO(childId: childId, lastFeed: nil, lastDiaper: nil, activeTimer: nil, lastMedicine: nil)
        )
        let afterClear = try await store.activeTimers(childId: childId)
        XCTAssertTrue(afterClear.isEmpty)
    }

    func testInMemoryStorePausedTimerIsActiveAndClearedByState() async throws {
        try await assertPausedTimerIsActiveThenCleared(InMemoryStore())
    }

    #if canImport(GRDB)
    func testGRDBStorePausedTimerIsActiveAndClearedByState() async throws {
        try await assertPausedTimerIsActiveThenCleared(try GRDBStore(inMemory: ()))
    }

    func testGRDBStoreRoundTripsPauseFields() async throws {
        let store = try GRDBStore(inMemory: ())
        let childId = UUID()
        let id = UUID()
        try await store.upsertTimer(timer(id: id, childId: childId, state: "paused", pausedAt: 300, pausedSeconds: 45))
        var read = try await store.activeTimers(childId: childId)
        XCTAssertEqual(read.first?.pausedAt, at(300))
        XCTAssertEqual(read.first?.pausedSeconds, 45)

        // Resume: upsert clears pausedAt and folds the pause into pausedSeconds.
        try await store.upsertTimer(timer(id: id, childId: childId, state: "running", pausedSeconds: 105))
        read = try await store.activeTimers(childId: childId)
        XCTAssertEqual(read.count, 1)
        XCTAssertNil(read.first?.pausedAt)
        XCTAssertEqual(read.first?.pausedSeconds, 105)
        XCTAssertEqual(read.first?.state, "running")
    }
    #endif
}
