import Foundation

/// The one server call the upload needs, so tests can stand in for the server.
public protocol ServerEventCreating: Sendable {
    func createEvent(_ request: CreateEventRequestDTO) async throws -> EventDTO
}

extension APIClient: ServerEventCreating {}

/// Copies on-device history to a family server's child.
///
/// Each entry is sent with its own id, so a server that knows `client_event_ids` stores it
/// once no matter how often the upload is retried. Once the server has an entry, the local
/// row becomes the server's copy (re-keyed to the server child), which is what makes a
/// rerun after an interruption skip it. On an older server that ignores the id, the local
/// copy is replaced by the server's, so a rerun still never sends it twice.
public struct LocalToServerUploader: Sendable {
    public struct Progress: Sendable, Equatable {
        public var uploaded: Int
        public var total: Int
    }

    private let store: any BenitoStore
    private let server: any ServerEventCreating

    public init(store: any BenitoStore, server: any ServerEventCreating) {
        self.store = store
        self.server = server
    }

    /// Uploads everything still keyed to `localChildId`. Returns how many entries went up.
    @discardableResult
    public func upload(
        localChildId: UUID,
        serverChildId: UUID,
        progress: (@Sendable (Progress) async -> Void)? = nil
    ) async throws -> Int {
        guard localChildId != serverChildId else { return 0 }
        let pending = try await store.events(childId: localChildId, from: .distantPast, to: .distantFuture)
            .filter { $0.deletedAt == nil }
            .sorted { $0.startedAt < $1.startedAt }
        var uploaded = 0
        await progress?(Progress(uploaded: 0, total: pending.count))
        for event in pending {
            let saved = try await server.createEvent(Self.request(for: event, childId: serverChildId))
            try await store.upsertEvent(saved)
            if saved.id != event.id {
                try await store.softDeleteEvent(id: event.id)
            }
            uploaded += 1
            await progress?(Progress(uploaded: uploaded, total: pending.count))
        }
        return uploaded
    }

    static func request(for event: EventDTO, childId: UUID) -> CreateEventRequestDTO {
        CreateEventRequestDTO(
            childId: childId,
            type: event.type,
            subtype: event.subtype,
            startedAt: event.startedAt,
            endedAt: event.endedAt,
            amountValue: event.amountValue,
            amountUnit: event.amountUnit,
            side: event.side,
            notes: event.notes,
            payloadJson: event.payloadJson,
            id: event.id
        )
    }
}
