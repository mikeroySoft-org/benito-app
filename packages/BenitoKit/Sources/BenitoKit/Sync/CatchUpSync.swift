import Foundation
import OSLog

/// Source of the server change feed (`GET /events?since=`). `APIClient` conforms; tests fake it.
public protocol EventChangeFetching: Sendable {
    func eventChanges(childId: UUID, since: Date, limit: Int) async throws -> [EventDTO]
}

extension APIClient: EventChangeFetching {}

/// Cursor-based catch-up: pulls every event changed since the last run (including tombstones)
/// into the local store. The WS `/sync` channel is live-only, so run this on sign-in, WS reconnect,
/// and when the app returns to the foreground.
public struct CatchUpSync: Sendable {
    public static func cursorKey(childId: UUID) -> String {
        "events_cursor.\(childId.uuidString.uppercased())"
    }

    private let store: any BenitoStore
    private let fetcher: any EventChangeFetching
    private let pageSize: Int

    public init(store: any BenitoStore, fetcher: any EventChangeFetching, pageSize: Int = 200) {
        self.store = store
        self.fetcher = fetcher
        self.pageSize = max(1, pageSize)
    }

    /// Pull every event changed since the stored cursor (epoch 0 if none), upsert each into the store
    /// (tombstones included: `upsertEvent` with `deletedAt` set), persist the new cursor (max `updatedAt`,
    /// stored via `store.setPreference(cursorKey, BenitoJSON.string(from:))`) after each page. Stop when a
    /// page is shorter than pageSize, empty, or the cursor did not advance. Returns number of events applied.
    @discardableResult
    public func run(childId: UUID) async throws -> Int {
        let key = Self.cursorKey(childId: childId)
        var cursor = try await storedCursor(key: key)
        var applied = 0
        var pages = 0
        while true {
            let page = try await fetcher.eventChanges(childId: childId, since: cursor, limit: pageSize)
            guard let newCursor = page.map(\.updatedAt).max() else { break }
            pages += 1
            for event in page {
                try await store.upsertEvent(event)
            }
            applied += page.count
            guard newCursor > cursor else { break }
            try await store.setPreference(key, value: BenitoJSON.string(from: newCursor))
            cursor = newCursor
            if page.count < pageSize { break }
        }
        BenitoLog.sync.notice("catch-up applied=\(applied, privacy: .public) pages=\(pages, privacy: .public)")
        return applied
    }

    private func storedCursor(key: String) async throws -> Date {
        guard let raw = try await store.preference(key) else { return Date(timeIntervalSince1970: 0) }
        return Self.parseDate(raw) ?? Date(timeIntervalSince1970: 0)
    }

    private static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: string)
    }
}
