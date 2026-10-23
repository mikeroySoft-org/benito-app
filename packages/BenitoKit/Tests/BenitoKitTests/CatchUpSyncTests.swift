import XCTest
@testable import BenitoKit

/// Serves `GET /events?since=` semantics from memory: `updatedAt > since`, ascending, limited.
private actor FakeChangeFeed: EventChangeFetching {
    struct InjectedFailure: Error {}

    private var rows: [UUID: EventDTO] = [:]
    private(set) var requestedSince: [Date] = []
    /// 1-based fetch number that throws once (nil = never).
    private var failOnFetch: Int?
    private var fetchCount = 0

    func put(_ event: EventDTO) {
        rows[event.id] = event
    }

    func failOnce(onFetch number: Int) {
        failOnFetch = number
        fetchCount = 0
    }

    func eventChanges(childId: UUID, since: Date, limit: Int) async throws -> [EventDTO] {
        fetchCount += 1
        requestedSince.append(since)
        if fetchCount == failOnFetch {
            failOnFetch = nil
            throw InjectedFailure()
        }
        return Array(
            rows.values
                .filter { $0.childId == childId && $0.updatedAt > since }
                .sorted { ($0.updatedAt, $0.id.uuidString) < ($1.updatedAt, $1.id.uuidString) }
                .prefix(limit)
        )
    }
}

final class CatchUpSyncTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 0)

    private func at(_ seconds: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(seconds))
    }

    private func event(
        id: UUID = UUID(),
        childId: UUID,
        subtype: String = "wet",
        updatedAt: Date,
        deletedAt: Date? = nil
    ) -> EventDTO {
        EventDTO(
            id: id,
            childId: childId,
            type: EventType.diaper.rawValue,
            subtype: subtype,
            startedAt: updatedAt,
            endedAt: nil,
            amountValue: nil,
            amountUnit: nil,
            side: nil,
            notes: nil,
            payloadJson: nil,
            createdBy: UUID(),
            createdAt: updatedAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    private func storedCursor(_ store: InMemoryStore, childId: UUID) async throws -> String? {
        try await store.preference(CatchUpSync.cursorKey(childId: childId))
    }

    func testInitialRunStartsAtEpochAndPersistsMaxUpdatedAt() async throws {
        let store = InMemoryStore()
        let feed = FakeChangeFeed()
        let childId = UUID()
        for s in [1, 3, 2] {
            await feed.put(event(childId: childId, updatedAt: at(s)))
        }

        let applied = try await CatchUpSync(store: store, fetcher: feed).run(childId: childId)

        XCTAssertEqual(applied, 3)
        let requested = await feed.requestedSince
        XCTAssertEqual(requested, [epoch])
        let rows = try await store.events(childId: childId, limit: 10)
        XCTAssertEqual(rows.count, 3)
        let cursor = try await storedCursor(store, childId: childId)
        XCTAssertEqual(cursor, BenitoJSON.string(from: at(3)))
    }

    func testSecondRunResumesFromStoredCursor() async throws {
        let store = InMemoryStore()
        let feed = FakeChangeFeed()
        let childId = UUID()
        let editedId = UUID()
        await feed.put(event(id: editedId, childId: childId, subtype: "wet", updatedAt: at(1)))
        await feed.put(event(childId: childId, updatedAt: at(2)))
        let sync = CatchUpSync(store: store, fetcher: feed)
        try await sync.run(childId: childId)

        await feed.put(event(id: editedId, childId: childId, subtype: "dirty", updatedAt: at(5)))
        await feed.put(event(childId: childId, updatedAt: at(4)))
        let applied = try await sync.run(childId: childId)

        XCTAssertEqual(applied, 2)
        let requested = await feed.requestedSince
        XCTAssertEqual(requested, [epoch, at(2)])
        let rows = try await store.events(childId: childId, limit: 10)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first { $0.id == editedId }?.subtype, "dirty")
        let cursor = try await storedCursor(store, childId: childId)
        XCTAssertEqual(cursor, BenitoJSON.string(from: at(5)))
    }

    func testTombstoneRemovesEventFromLocalHistory() async throws {
        let store = InMemoryStore()
        let feed = FakeChangeFeed()
        let childId = UUID()
        let doomedId = UUID()
        await feed.put(event(id: doomedId, childId: childId, updatedAt: at(1)))
        await feed.put(event(childId: childId, updatedAt: at(2)))
        let sync = CatchUpSync(store: store, fetcher: feed)
        try await sync.run(childId: childId)
        let before = try await store.events(childId: childId, limit: 10)
        XCTAssertEqual(before.count, 2)

        await feed.put(event(id: doomedId, childId: childId, updatedAt: at(3), deletedAt: at(3)))
        let applied = try await sync.run(childId: childId)

        XCTAssertEqual(applied, 1)
        let after = try await store.events(childId: childId, limit: 10)
        XCTAssertEqual(after.count, 1)
        XCTAssertFalse(after.contains { $0.id == doomedId })
    }

    func testPagesUntilShortPage() async throws {
        let store = InMemoryStore()
        let feed = FakeChangeFeed()
        let childId = UUID()
        for s in 1...5 {
            await feed.put(event(childId: childId, updatedAt: at(s)))
        }

        let applied = try await CatchUpSync(store: store, fetcher: feed, pageSize: 2).run(childId: childId)

        XCTAssertEqual(applied, 5)
        let requested = await feed.requestedSince
        XCTAssertEqual(requested, [epoch, at(2), at(4)])
        let rows = try await store.events(childId: childId, limit: 10)
        XCTAssertEqual(rows.count, 5)
        let cursor = try await storedCursor(store, childId: childId)
        XCTAssertEqual(cursor, BenitoJSON.string(from: at(5)))
    }

    func testFetchFailureKeepsCursorFromCompletedPagesAndResumes() async throws {
        let store = InMemoryStore()
        let feed = FakeChangeFeed()
        let childId = UUID()
        for s in 1...5 {
            await feed.put(event(childId: childId, updatedAt: at(s)))
        }
        await feed.failOnce(onFetch: 2)
        let sync = CatchUpSync(store: store, fetcher: feed, pageSize: 2)

        do {
            try await sync.run(childId: childId)
            XCTFail("expected injected failure")
        } catch is FakeChangeFeed.InjectedFailure {}

        let partialCursor = try await storedCursor(store, childId: childId)
        XCTAssertEqual(partialCursor, BenitoJSON.string(from: at(2)))
        let partialRows = try await store.events(childId: childId, limit: 10)
        XCTAssertEqual(partialRows.count, 2)

        let applied = try await sync.run(childId: childId)

        XCTAssertEqual(applied, 3)
        let requested = await feed.requestedSince
        XCTAssertEqual(requested, [epoch, at(2), at(2), at(4)])
        let rows = try await store.events(childId: childId, limit: 10)
        XCTAssertEqual(rows.count, 5)
        let cursor = try await storedCursor(store, childId: childId)
        XCTAssertEqual(cursor, BenitoJSON.string(from: at(5)))
    }

    func testCursorIsPerChild() async throws {
        let store = InMemoryStore()
        let feed = FakeChangeFeed()
        let childA = UUID()
        let childB = UUID()
        XCTAssertNotEqual(CatchUpSync.cursorKey(childId: childA), CatchUpSync.cursorKey(childId: childB))
        await feed.put(event(childId: childA, updatedAt: at(10)))
        await feed.put(event(childId: childB, updatedAt: at(1)))
        let sync = CatchUpSync(store: store, fetcher: feed)

        try await sync.run(childId: childA)
        let cursorBBeforeRun = try await storedCursor(store, childId: childB)
        XCTAssertNil(cursorBBeforeRun)

        let appliedB = try await sync.run(childId: childB)

        XCTAssertEqual(appliedB, 1)
        let requested = await feed.requestedSince
        XCTAssertEqual(requested, [epoch, epoch])
        let cursorA = try await storedCursor(store, childId: childA)
        let cursorB = try await storedCursor(store, childId: childB)
        XCTAssertEqual(cursorA, BenitoJSON.string(from: at(10)))
        XCTAssertEqual(cursorB, BenitoJSON.string(from: at(1)))
    }
}
