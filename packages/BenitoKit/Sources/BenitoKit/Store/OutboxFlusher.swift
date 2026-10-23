import Foundation
import OSLog

/// Flushes the local outbox when the API is reachable.
public actor OutboxFlusher {
    private let store: any BenitoStore
    private let api: APIClient

    public init(store: any BenitoStore, api: APIClient) {
        self.store = store
        self.api = api
    }

    /// Returns number of successfully flushed entries. Stops on first hard failure
    /// (keeps remaining rows for retry). Transport / 5xx / 401 / 429 leave the entry queued.
    /// Definite 4xx client errors (other than 401/429) are dropped as poison pills so the
    /// queue can progress. Unknown errors keep the row (safer than silent drop).
    @discardableResult
    public func flush() async throws -> Int {
        let pending = try await store.pendingOutbox()
        BenitoLog.store.notice("outbox flush pending=\(pending.count, privacy: .public)")
        var done = 0
        for entry in pending {
            do {
                BenitoLog.store.debug("outbox replay \(entry.method, privacy: .public) \(entry.path, privacy: .public)")
                try await api.rawRequest(method: entry.method, path: entry.path, body: entry.body)
                try await store.deleteOutbox(id: entry.id)
                done += 1
            } catch let error as APIClientError {
                switch error {
                case .transport:
                    BenitoLog.store.warning("outbox stop transport after \(done, privacy: .public)")
                    return done
                case .httpStatus(let code, _) where (500..<600).contains(code):
                    BenitoLog.store.warning("outbox stop HTTP \(code, privacy: .public) after \(done, privacy: .public)")
                    return done
                case .httpStatus(401, _), .httpStatus(429, _):
                    // Auth / rate-limit: keep queue intact; caller should re-auth or back off.
                    BenitoLog.store.warning("outbox stop auth/rate-limit after \(done, privacy: .public)")
                    return done
                case .httpStatus(let code, _) where (400..<500).contains(code):
                    // Poison pill (validation, not found, conflict, …).
                    BenitoLog.store.error("outbox poison HTTP \(code, privacy: .public) \(entry.method, privacy: .public) \(entry.path, privacy: .public)")
                    try await store.deleteOutbox(id: entry.id)
                    done += 1
                case .invalidURL, .decoding:
                    // Local/client bug — drop so one bad row cannot stall forever.
                    BenitoLog.store.error("outbox poison local \(entry.method, privacy: .public) \(entry.path, privacy: .public)")
                    try await store.deleteOutbox(id: entry.id)
                    done += 1
                case .httpStatus:
                    return done
                }
            } catch {
                // Unknown error: keep entry for retry (do not poison-drop).
                BenitoLog.store.warning("outbox stop unknown after \(done, privacy: .public)")
                return done
            }
        }
        BenitoLog.store.notice("outbox flush done=\(done, privacy: .public)")
        return done
    }
}

/// Bridges `APIClient.state` into store refetch hooks.
public struct APIStateRefetcher: StateRefetching {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    public func refetchState(childId: UUID) async throws -> BabyStateDTO {
        try await api.state(childId: childId)
    }
}
