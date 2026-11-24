import Foundation

/// Outbound mutation waiting for the API (offline queue).
public struct OutboxEntry: Sendable, Identifiable, Hashable {
    public let id: Int64
    public var method: String
    public var path: String
    public var body: Data?
    public var createdAt: Date

    public init(id: Int64, method: String, path: String, body: Data?, createdAt: Date) {
        self.id = id
        self.method = method
        self.path = path
        self.body = body
        self.createdAt = createdAt
    }
}

/// Local-first store. Prefer `GRDBStore` on device; `InMemoryStore` for tests / previews.
public protocol BenitoStore: Sendable {
    func upsertChild(_ child: ChildDTO) async throws
    func children() async throws -> [ChildDTO]

    func upsertEvent(_ event: EventDTO) async throws
    func softDeleteEvent(id: UUID) async throws
    /// One event by id, including soft-deleted ones (nil when unknown).
    func event(id: UUID) async throws -> EventDTO?
    func events(childId: UUID, limit: Int) async throws -> [EventDTO]
    /// Non-deleted events whose interval `startedAt ..< (endedAt ?? startedAt)` overlaps `[from, to)`.
    /// Instants (no `endedAt`) match when `from <= startedAt < to`. Sorted by `startedAt` ascending.
    func events(childId: UUID, from: Date, to: Date) async throws -> [EventDTO]

    func upsertTimer(_ timer: TimerDTO) async throws
    func removeTimer(id: UUID) async throws
    /// One timer by id in any state (nil when unknown).
    func timer(id: UUID) async throws -> TimerDTO?
    func activeTimers(childId: UUID) async throws -> [TimerDTO]

    /// Build a home-glance snapshot from local rows (last feed / diaper / medicine + running timer).
    func localBabyState(childId: UUID) async throws -> BabyStateDTO

    /// Upsert glance rows from a server `BabyStateDTO` (after GET /state or export).
    func applyBabyState(_ state: BabyStateDTO) async throws

    /// Replace children list (e.g. after `/me` or export).
    func replaceChildren(_ children: [ChildDTO]) async throws

    func applySyncEnvelope(_ envelope: SyncEnvelopeDTO) async throws

    // MARK: Outbox

    func enqueueOutbox(method: String, path: String, body: Data?) async throws -> Int64
    func pendingOutbox() async throws -> [OutboxEntry]
    func deleteOutbox(id: Int64) async throws
    /// Encoded outbox bodies (legacy / diagnostics). Prefer `pendingOutbox`.
    func pendingSyncPayloads() async throws -> [Data]

    // MARK: Prefs (server URL etc.; auth token stays Keychain-stub / memory)

    func setPreference(_ key: String, value: String) async throws
    func preference(_ key: String) async throws -> String?

    /// Deletes every row: children, events, timers, the outbox and preferences.
    func eraseAll() async throws
}

/// Optional hook so `state` / `refetch_state` envelopes can HTTP-refetch and replace local rows.
public protocol StateRefetching: Sendable {
    func refetchState(childId: UUID) async throws -> BabyStateDTO
}

// MARK: - In-memory (tests / Linux / previews)

public actor InMemoryStore: BenitoStore {
    private var childRows: [UUID: ChildDTO] = [:]
    private var events: [UUID: EventDTO] = [:]
    private var timers: [UUID: TimerDTO] = [:]
    private var outbox: [OutboxEntry] = []
    private var prefs: [String: String] = [:]
    private var nextOutboxId: Int64 = 1
    public var stateRefetcher: (any StateRefetching)?

    public init(stateRefetcher: (any StateRefetching)? = nil) {
        self.stateRefetcher = stateRefetcher
    }

    public func setRefetcher(_ refetcher: (any StateRefetching)?) {
        self.stateRefetcher = refetcher
    }

    public func upsertChild(_ child: ChildDTO) async throws {
        childRows[child.id] = child
    }

    public func children() async throws -> [ChildDTO] {
        Array(childRows.values).sorted { $0.name < $1.name }
    }

    public func replaceChildren(_ children: [ChildDTO]) async throws {
        childRows = Dictionary(uniqueKeysWithValues: children.map { ($0.id, $0) })
    }

    public func upsertEvent(_ event: EventDTO) async throws {
        events[event.id] = event
    }

    public func softDeleteEvent(id: UUID) async throws {
        guard var e = events[id] else { return }
        e.deletedAt = Date()
        events[id] = e
    }

    public func event(id: UUID) async throws -> EventDTO? {
        events[id]
    }

    public func events(childId: UUID, limit: Int) async throws -> [EventDTO] {
        Array(
            events.values
                .filter { $0.childId == childId && $0.deletedAt == nil }
                .sorted { $0.startedAt > $1.startedAt }
                .prefix(limit)
        )
    }

    public func events(childId: UUID, from: Date, to: Date) async throws -> [EventDTO] {
        events.values
            .filter { e in
                guard e.childId == childId, e.deletedAt == nil, e.startedAt < to else { return false }
                // Same predicate as GRDBStore: ranged events overlap when they end after `from`;
                // instants (and zero-length ranges) need `startedAt >= from`.
                return (e.endedAt ?? e.startedAt) > from || e.startedAt >= from
            }
            .sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
    }

    public func upsertTimer(_ timer: TimerDTO) async throws {
        timers[timer.id] = timer
    }

    public func removeTimer(id: UUID) async throws {
        timers.removeValue(forKey: id)
    }

    public func timer(id: UUID) async throws -> TimerDTO? {
        timers[id]
    }

    public func activeTimers(childId: UUID) async throws -> [TimerDTO] {
        timers.values.filter { $0.childId == childId && $0.isActive }
    }

    public func localBabyState(childId: UUID) async throws -> BabyStateDTO {
        let live = try await events(childId: childId, limit: 200)
        let lastFeed = live.first { $0.type.hasPrefix("feed_") }
        let lastDiaper = live.first { $0.type == EventType.diaper.rawValue }
        let lastMedicine = live.first { $0.type == EventType.medicine.rawValue }
        let active = try await activeTimers(childId: childId).first
        return BabyStateDTO(
            childId: childId,
            lastFeed: lastFeed,
            lastDiaper: lastDiaper,
            activeTimer: active,
            lastMedicine: lastMedicine
        )
    }

    public func applyBabyState(_ state: BabyStateDTO) async throws {
        if let e = state.lastFeed { try await upsertEvent(e) }
        if let e = state.lastDiaper { try await upsertEvent(e) }
        if let e = state.lastMedicine { try await upsertEvent(e) }
        if let t = state.activeTimer {
            try await upsertTimer(t)
        } else {
            for t in try await activeTimers(childId: state.childId) {
                var stopped = t
                stopped.state = "stopped"
                stopped.stoppedAt = stopped.stoppedAt ?? Date()
                try await upsertTimer(stopped)
            }
        }
    }

    public func enqueueOutbox(method: String, path: String, body: Data?) async throws -> Int64 {
        let id = nextOutboxId
        nextOutboxId += 1
        outbox.append(OutboxEntry(id: id, method: method, path: path, body: body, createdAt: Date()))
        return id
    }

    public func pendingOutbox() async throws -> [OutboxEntry] {
        outbox.sorted { $0.id < $1.id }
    }

    public func deleteOutbox(id: Int64) async throws {
        outbox.removeAll { $0.id == id }
    }

    public func pendingSyncPayloads() async throws -> [Data] {
        try await pendingOutbox().compactMap(\.body)
    }

    public func setPreference(_ key: String, value: String) async throws {
        prefs[key] = value
    }

    public func preference(_ key: String) async throws -> String? {
        prefs[key]
    }

    public func eraseAll() async throws {
        childRows = [:]
        events = [:]
        timers = [:]
        outbox = []
        prefs = [:]
    }

    public func applySyncEnvelope(_ envelope: SyncEnvelopeDTO) async throws {
        switch envelope.type {
        case SyncMessageType.eventUpsert.rawValue:
            if let event = decodePayload(EventDTO.self, envelope.payload) {
                try await upsertEvent(event)
            }
        case SyncMessageType.eventDelete.rawValue:
            if case .object(let obj) = envelope.payload,
               case .string(let idStr) = obj["id"],
               let id = UUID(uuidString: idStr)
            {
                try await softDeleteEvent(id: id)
            }
        case SyncMessageType.timerUpsert.rawValue, SyncMessageType.timerStop.rawValue:
            if let timer = decodePayload(TimerDTO.self, envelope.payload) {
                try await upsertTimer(timer)
            }
        case SyncMessageType.state.rawValue, SyncMessageType.refetchState.rawValue:
            try await handleStateHint(envelope.payload)
        case SyncMessageType.hello.rawValue, SyncMessageType.error.rawValue, SyncMessageType.pong.rawValue:
            break
        default:
            break
        }
    }

    private func handleStateHint(_ payload: JSONValue) async throws {
        guard case .object(let obj) = payload else { return }
        let childId: UUID? = {
            if case .string(let s) = obj["child_id"] { return UUID(uuidString: s) }
            return nil
        }()
        guard let childId, let refetcher = stateRefetcher else { return }
        let state = try await refetcher.refetchState(childId: childId)
        try await applyBabyState(state)
    }

    private func decodePayload<T: Decodable>(_ type: T.Type, _ payload: JSONValue) -> T? {
        guard let data = try? BenitoJSON.encoder.encode(payload) else { return nil }
        return try? BenitoJSON.decoder.decode(T.self, from: data)
    }
}
