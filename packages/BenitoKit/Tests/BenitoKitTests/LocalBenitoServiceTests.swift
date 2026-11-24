import XCTest
@testable import BenitoKit

/// On-device mode answers like the family server: same timer rules, same auto-logged events,
/// same status codes (and never 401, which would sign the user out).
final class LocalBenitoServiceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func makeService(_ clock: Clock) throws -> (LocalBenitoService, any BenitoStore) {
        let store = try LocalStoreFactory.makeGRDB(path: ":memory:")
        return (LocalBenitoService(store: store, clock: { clock.now }), store)
    }

    private func status(_ error: Error) -> Int? {
        if case let APIClientError.httpStatus(code, _) = error { return code }
        return nil
    }

    private func assertStatus<T>(_ expected: Int, _ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected HTTP \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(status(error), expected, "\(error)", file: file, line: line)
        }
    }

    func testMeBeforeSetupIs404NotUnauthorized() async throws {
        let (service, _) = try makeService(Clock(t0))
        await assertStatus(404) { try await service.me() }
    }

    func testCreateProfileReturnsParentWithOneChild() async throws {
        let (service, _) = try makeService(Clock(t0))
        let me = try await service.createProfile(yourName: " Mike ", familyName: "Roys", childName: "Benito")
        XCTAssertEqual(me.user.name, "Mike")
        XCTAssertEqual(me.family?.name, "Roys")
        XCTAssertEqual(me.role, .parent)
        XCTAssertEqual(me.children.map(\.name), ["Benito"])
        let again = try await service.me()
        XCTAssertEqual(again.user.id, me.user.id)
        XCTAssertEqual(again.children.first?.id, me.children.first?.id)
    }

    func testCreateProfileTwiceKeepsTheFirstFamilyAndBaby() async throws {
        let (service, store) = try makeService(Clock(t0))
        let first = try await service.createProfile(yourName: "Mike", familyName: "Roys", childName: "Benito")
        let second = try await service.createProfile(yourName: "Other", familyName: "Other", childName: "Other")
        XCTAssertEqual(second.family?.id, first.family?.id)
        XCTAssertEqual(second.children.map(\.id), first.children.map(\.id))
        let stored = try await store.children()
        XCTAssertEqual(stored.count, 1)
    }

    func testConcurrentCreateProfileMakesOneFamily() async throws {
        let (service, store) = try makeService(Clock(t0))
        let families = try await withThrowingTaskGroup(of: UUID?.self) { group in
            for index in 0..<5 {
                group.addTask {
                    try await service.createProfile(yourName: "P\(index)", familyName: "F", childName: "B\(index)").family?.id
                }
            }
            var ids = Set<UUID?>()
            for try await id in group { ids.insert(id) }
            return ids
        }
        XCTAssertEqual(families.count, 1)
        let stored = try await store.children()
        XCTAssertEqual(stored.count, 1)
        let me = try await service.me()
        XCTAssertEqual(me.children.count, 1)
    }

    func testSleepTimerWithPauseStopsIntoSleepEvent() async throws {
        let clock = Clock(t0)
        let (service, _) = try makeService(clock)
        let child = try await service.createProfile(yourName: "M", familyName: "F", childName: "B").children[0].id

        let started = try await service.startTimer(childId: child, kind: " Sleep ", side: nil, at: t0)
        XCTAssertEqual(started.kind, "sleep")
        XCTAssertEqual(started.state, "running")

        clock.now = t0.addingTimeInterval(600)
        let paused = try await service.pauseTimer(id: started.id, at: clock.now)
        XCTAssertEqual(paused.state, "paused")
        await assertStatus(409) { try await service.pauseTimer(id: started.id, at: clock.now) }

        clock.now = t0.addingTimeInterval(900)
        let resumed = try await service.resumeTimer(id: started.id, at: clock.now)
        XCTAssertEqual(resumed.pausedSeconds, 300)
        XCTAssertNil(resumed.pausedAt)

        clock.now = t0.addingTimeInterval(3600)
        let stopped = try await service.stopTimer(id: started.id, at: clock.now)
        XCTAssertEqual(stopped.state, "stopped")
        XCTAssertEqual(stopped.stoppedAt, clock.now)

        let state = try await service.state(childId: child)
        XCTAssertNil(state.activeTimer)
        let events = try await service.exportBundle().events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "sleep")
        XCTAssertEqual(events[0].startedAt, t0)
        XCTAssertEqual(events[0].endedAt, clock.now)
        XCTAssertEqual(events[0].payloadJson, .object(["paused_seconds": .number(300)]))

        let summary = try await service.dailySummary(childId: child, day: nil, from: t0, to: clock.now)
        XCTAssertEqual(summary.sleepEventCount, 1)
        XCTAssertEqual(summary.sleepHours, 0.92) // 55 active minutes

        // Stopping twice is a no-op, like the server; no second event.
        _ = try await service.stopTimer(id: started.id, at: clock.now)
        let after = try await service.exportBundle().events.count
        XCTAssertEqual(after, 1)
    }

    func testStopWhilePausedFoldsOpenPause() async throws {
        let clock = Clock(t0)
        let (service, _) = try makeService(clock)
        let child = try await service.createProfile(yourName: "M", familyName: "F", childName: "B").children[0].id
        let timer = try await service.startTimer(childId: child, kind: "walk", side: nil, at: t0)
        clock.now = t0.addingTimeInterval(60)
        _ = try await service.pauseTimer(id: timer.id, at: clock.now)
        clock.now = t0.addingTimeInterval(180)
        let stopped = try await service.stopTimer(id: timer.id, at: clock.now)
        XCTAssertEqual(stopped.pausedSeconds, 120)
        XCTAssertNil(stopped.pausedAt)
        let event = try await service.exportBundle().events[0]
        XCTAssertEqual(event.type, "activity")
        XCTAssertEqual(event.subtype, "walk")
    }

    func testNursingTimerNeedsSideAndCarriesIt() async throws {
        let clock = Clock(t0)
        let (service, _) = try makeService(clock)
        let child = try await service.createProfile(yourName: "M", familyName: "F", childName: "B").children[0].id
        await assertStatus(400) { try await service.startTimer(childId: child, kind: "feed_breast", side: "middle", at: t0) }
        let timer = try await service.startTimer(childId: child, kind: "feed_breast", side: "l", at: t0)
        XCTAssertEqual(timer.side, "L")
        clock.now = t0.addingTimeInterval(420)
        _ = try await service.stopTimer(id: timer.id, at: clock.now)
        let event = try await service.exportBundle().events[0]
        XCTAssertEqual(event.type, "feed_breast")
        XCTAssertEqual(event.side, "L")
        XCTAssertNil(event.payloadJson)
    }

    func testTimeLimitsAndMissingRows() async throws {
        let clock = Clock(t0)
        let (service, _) = try makeService(clock)
        let child = try await service.createProfile(yourName: "M", familyName: "F", childName: "B").children[0].id
        await assertStatus(400) { try await service.startTimer(childId: child, kind: "sleep", side: nil, at: self.t0.addingTimeInterval(600)) }
        await assertStatus(400) { try await service.startTimer(childId: child, kind: "sleep", side: nil, at: self.t0.addingTimeInterval(-90_000)) }
        await assertStatus(400) { try await service.startTimer(childId: child, kind: "  ", side: nil, at: self.t0) }
        await assertStatus(404) { try await service.startTimer(childId: UUID(), kind: "sleep", side: nil, at: self.t0) }
        await assertStatus(404) { try await service.stopTimer(id: UUID(), at: self.t0) }
        await assertStatus(404) { try await service.deleteEvent(id: UUID()) }

        let timer = try await service.startTimer(childId: child, kind: "sleep", side: nil, at: t0)
        await assertStatus(409) { try await service.resumeTimer(id: timer.id, at: self.t0) }
        await assertStatus(400) { try await service.adjustTimerStart(id: timer.id, startedAt: self.t0.addingTimeInterval(120)) }
        let adjusted = try await service.adjustTimerStart(id: timer.id, startedAt: t0.addingTimeInterval(-900))
        XCTAssertEqual(adjusted.startedAt, t0.addingTimeInterval(-900))
        let listed = try await service.listTimers(childId: nil)
        XCTAssertEqual(listed.map(\.id), [timer.id])
    }

    func testEventsCreateEditDeleteAndIdempotentIds() async throws {
        let clock = Clock(t0)
        let (service, _) = try makeService(clock)
        let child = try await service.createProfile(yourName: "M", familyName: "F", childName: "B").children[0].id

        await assertStatus(400) { try await service.createEvent(CreateEventRequestDTO(childId: child, type: "nap")) }
        await assertStatus(400) { try await service.createEvent(CreateEventRequestDTO(childId: child, type: "activity", subtype: "swim")) }

        let id = UUID()
        let first = try await service.createEvent(CreateEventRequestDTO(childId: child, type: "diaper", subtype: "wet", id: id))
        XCTAssertEqual(first.id, id)
        XCTAssertEqual(first.startedAt, t0)
        let replay = try await service.createEvent(CreateEventRequestDTO(childId: child, type: "diaper", subtype: "dirty", id: id))
        XCTAssertEqual(replay.subtype, "wet", "same id returns the stored entry unchanged")

        await assertStatus(400) {
            try await service.updateEvent(id: id, UpdateEventRequestDTO(startedAt: self.t0.addingTimeInterval(3600)))
        }
        let edited = try await service.updateEvent(id: id, UpdateEventRequestDTO(notes: "blowout"))
        XCTAssertEqual(edited.notes, "blowout")
        XCTAssertEqual(edited.subtype, "wet")

        try await service.deleteEvent(id: id)
        await assertStatus(404) { try await service.deleteEvent(id: id) }
        await assertStatus(404) { try await service.updateEvent(id: id, UpdateEventRequestDTO(notes: "x")) }
        let remaining = try await service.exportBundle().events
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCSVMatchesServerColumns() async throws {
        let clock = Clock(t0)
        let (service, _) = try makeService(clock)
        let child = try await service.createProfile(yourName: "M", familyName: "F", childName: "B").children[0].id
        _ = try await service.createEvent(CreateEventRequestDTO(
            childId: child, type: "feed_bottle", amountValue: 4, amountUnit: "oz", notes: "said \"more\", then slept"
        ))
        let csv = String(decoding: try await service.exportCSV(), as: UTF8.self)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.first, "id,child_id,type,subtype,started_at,ended_at,amount_value,amount_unit,side,notes,created_by,created_at")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains(",feed_bottle,,"))
        XCTAssertTrue(lines[1].contains(",4,oz,,\"said \"\"more\"\", then slept\","))
    }

    func testEraseAllLeavesNoProfileOrHistory() async throws {
        let (service, store) = try makeService(Clock(t0))
        let child = try await service.createProfile(yourName: "M", familyName: "F", childName: "B").children[0].id
        let event = try await service.createEvent(CreateEventRequestDTO(childId: child, type: "feed_bottle"))
        let timer = try await service.startTimer(childId: child, kind: "sleep", side: nil, at: t0)
        _ = try await store.enqueueOutbox(method: "POST", path: "/events", body: nil)

        try await store.eraseAll()

        let profile = try await LocalProfile.load(from: store)
        XCTAssertNil(profile)
        let children = try await store.children()
        XCTAssertTrue(children.isEmpty)
        let storedEvent = try await store.event(id: event.id)
        XCTAssertNil(storedEvent)
        let storedTimer = try await store.timer(id: timer.id)
        XCTAssertNil(storedTimer)
        let outbox = try await store.pendingOutbox()
        XCTAssertTrue(outbox.isEmpty)
        await assertStatus(404) { try await service.me() }
    }
}
