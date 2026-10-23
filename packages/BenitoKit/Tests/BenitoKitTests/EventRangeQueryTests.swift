import XCTest
@testable import BenitoKit

/// `events(childId:from:to:)`: half-open `[from, to)` overlap with `startedAt ..< (endedAt ?? startedAt)`.
final class EventRangeQueryTests: XCTestCase {
    private let hour: TimeInterval = 3600
    private let from = Date(timeIntervalSince1970: 1_700_000_000)
    private var to: Date { from.addingTimeInterval(24 * hour) }

    private func event(
        _ label: String,
        childId: UUID,
        start: Date,
        end: Date? = nil,
        deleted: Bool = false
    ) -> EventDTO {
        EventDTO(
            id: UUID(),
            childId: childId,
            type: end == nil ? EventType.diaper.rawValue : EventType.sleep.rawValue,
            subtype: nil,
            startedAt: start,
            endedAt: end,
            amountValue: nil,
            amountUnit: nil,
            side: nil,
            notes: label,
            payloadJson: nil,
            createdBy: UUID(),
            createdAt: start,
            updatedAt: start,
            deletedAt: deleted ? start : nil
        )
    }

    private func assertRangeQuery(_ store: any BenitoStore, file: StaticString = #filePath, line: UInt = #line) async throws {
        let child = UUID()
        let otherChild = UUID()
        let rows: [EventDTO] = [
            // Included
            event("overlapEnd", childId: child, start: to.addingTimeInterval(-0.5 * hour), end: to.addingTimeInterval(hour)),
            event("instantInside", childId: child, start: from.addingTimeInterval(hour)),
            event("spanning", childId: child, start: from.addingTimeInterval(-2 * hour), end: to.addingTimeInterval(hour)),
            event("instantAtFrom", childId: child, start: from),
            event("overlapStart", childId: child, start: from.addingTimeInterval(-hour), end: from.addingTimeInterval(0.5 * hour)),
            // Excluded
            event("instantAtTo", childId: child, start: to),
            event("instantBefore", childId: child, start: from.addingTimeInterval(-1)),
            event("instantAfter", childId: child, start: to.addingTimeInterval(hour)),
            event("endsAtFrom", childId: child, start: from.addingTimeInterval(-hour), end: from),
            event("startsAtTo", childId: child, start: to, end: to.addingTimeInterval(hour)),
            event("entirelyBefore", childId: child, start: from.addingTimeInterval(-3 * hour), end: from.addingTimeInterval(-2 * hour)),
            event("entirelyAfter", childId: child, start: to.addingTimeInterval(hour), end: to.addingTimeInterval(2 * hour)),
            event("deletedInside", childId: child, start: from.addingTimeInterval(2 * hour), deleted: true),
            event("deletedRange", childId: child, start: from.addingTimeInterval(3 * hour), end: from.addingTimeInterval(4 * hour), deleted: true),
            event("otherChild", childId: otherChild, start: from.addingTimeInterval(hour)),
        ]
        for row in rows {
            try await store.upsertEvent(row)
        }

        let result = try await store.events(childId: child, from: from, to: to)
        XCTAssertEqual(
            result.map(\.notes),
            ["spanning", "overlapStart", "instantAtFrom", "instantInside", "overlapEnd"],
            file: file,
            line: line
        )
        XCTAssertEqual(result.map(\.startedAt), result.map(\.startedAt).sorted(), file: file, line: line)

        let other = try await store.events(childId: otherChild, from: from, to: to)
        XCTAssertEqual(other.map(\.notes), ["otherChild"], file: file, line: line)

        let emptyWindow = try await store.events(childId: child, from: to.addingTimeInterval(3 * hour), to: to.addingTimeInterval(4 * hour))
        XCTAssertEqual(emptyWindow, [], file: file, line: line)
    }

    func testInMemoryStoreRangeQuery() async throws {
        try await assertRangeQuery(InMemoryStore())
    }

    #if canImport(GRDB)
    func testGRDBStoreRangeQuery() async throws {
        try await assertRangeQuery(try GRDBStore(inMemory: ()))
    }
    #endif
}
