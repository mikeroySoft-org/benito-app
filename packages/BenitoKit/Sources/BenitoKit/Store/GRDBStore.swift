#if canImport(GRDB)
import Foundation
import GRDB
import OSLog

/// SQLite (GRDB) local-first store. Schema mirrors server concepts needed on device
/// plus prefs + outbox. Auth tokens stay out of SQLite (Keychain stub separately).
public final class GRDBStore: BenitoStore, @unchecked Sendable {
    public static let preferenceServerURL = "server_url"

    private let dbQueue: DatabaseQueue
    /// When set, `state` / `refetch_state` envelopes trigger GET /state and replace local glance rows.
    public var stateRefetcher: (any StateRefetching)?

    public init(path: String, stateRefetcher: (any StateRefetching)? = nil) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        self.stateRefetcher = stateRefetcher
        try migrator.migrate(dbQueue)
    }

    /// In-memory GRDB (unit tests on Apple platforms).
    public init(inMemory: Void, stateRefetcher: (any StateRefetching)? = nil) throws {
        dbQueue = try DatabaseQueue()
        self.stateRefetcher = stateRefetcher
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_local") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS children (
                    id TEXT PRIMARY KEY NOT NULL,
                    family_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    birthdate TEXT,
                    sex TEXT,
                    created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS events (
                    id TEXT PRIMARY KEY NOT NULL,
                    child_id TEXT NOT NULL,
                    type TEXT NOT NULL,
                    subtype TEXT,
                    started_at TEXT NOT NULL,
                    ended_at TEXT,
                    amount_value REAL,
                    amount_unit TEXT,
                    side TEXT,
                    notes TEXT,
                    payload_json TEXT,
                    created_by TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    deleted_at TEXT
                );

                CREATE INDEX IF NOT EXISTS idx_events_child_started
                    ON events(child_id, started_at DESC);

                CREATE TABLE IF NOT EXISTS timers (
                    id TEXT PRIMARY KEY NOT NULL,
                    child_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    started_at TEXT NOT NULL,
                    started_by TEXT NOT NULL,
                    state TEXT NOT NULL DEFAULT 'running',
                    stopped_at TEXT,
                    updated_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_timers_child_state
                    ON timers(child_id, state);

                CREATE TABLE IF NOT EXISTS prefs (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS outbox (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    method TEXT NOT NULL,
                    path TEXT NOT NULL,
                    body BLOB,
                    created_at TEXT NOT NULL
                );
                """)
        }
        migrator.registerMigration("v2_timer_side") { db in
            let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('timers')")
            if !columns.contains("side") {
                try db.execute(sql: "ALTER TABLE timers ADD COLUMN side TEXT")
            }
        }
        migrator.registerMigration("v3_timer_pause") { db in
            let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('timers')")
            if !columns.contains("paused_at") {
                try db.execute(sql: "ALTER TABLE timers ADD COLUMN paused_at TEXT")
            }
            if !columns.contains("paused_seconds") {
                try db.execute(sql: "ALTER TABLE timers ADD COLUMN paused_seconds INTEGER NOT NULL DEFAULT 0")
            }
        }
        return migrator
    }

    // MARK: - Children

    public func upsertChild(_ child: ChildDTO) async throws {
        try await dbQueue.write { db in
            try Self.insertChild(child, db: db)
        }
    }

    public func children() async throws -> [ChildDTO] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM children ORDER BY name")
            return try rows.map { try Self.child(from: $0) }
        }
    }

    public func replaceChildren(_ children: [ChildDTO]) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM children")
            for child in children {
                try Self.insertChild(child, db: db)
            }
        }
    }

    // MARK: - Events

    public func upsertEvent(_ event: EventDTO) async throws {
        try await dbQueue.write { db in
            try Self.insertEvent(event, db: db)
        }
    }

    public func softDeleteEvent(id: UUID) async throws {
        let now = Self.encodeDate(Date())
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE events SET deleted_at = ?, updated_at = ? WHERE id = ?",
                arguments: [now, now, id.uuidString]
            )
        }
    }

    public func events(childId: UUID, limit: Int) async throws -> [EventDTO] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM events
                    WHERE child_id = ? AND deleted_at IS NULL
                    ORDER BY started_at DESC
                    LIMIT ?
                    """,
                arguments: [childId.uuidString, limit]
            )
            return try rows.map { try Self.event(from: $0) }
        }
    }

    public func events(childId: UUID, from: Date, to: Date) async throws -> [EventDTO] {
        // Dates are fixed-width UTC ISO-8601 text (`encodeDate`), so text comparison orders
        // them chronologically. Ranged events overlap when `started_at < to AND ended_at > from`;
        // instants (and zero-length ranges) need `from <= started_at < to`.
        let fromText = Self.encodeDate(from)
        let toText = Self.encodeDate(to)
        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM events
                    WHERE child_id = ? AND deleted_at IS NULL
                      AND started_at < ?
                      AND (COALESCE(ended_at, started_at) > ? OR started_at >= ?)
                    ORDER BY started_at ASC, id ASC
                    """,
                arguments: [childId.uuidString, toText, fromText, fromText]
            )
            return try rows.map { try Self.event(from: $0) }
        }
    }

    // MARK: - Timers

    public func upsertTimer(_ timer: TimerDTO) async throws {
        try await dbQueue.write { db in
            try Self.insertTimer(timer, db: db)
        }
    }

    public func removeTimer(id: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM timers WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func activeTimers(childId: UUID) async throws -> [TimerDTO] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM timers
                    WHERE child_id = ? AND state IN ('running', 'paused')
                    ORDER BY started_at DESC
                    """,
                arguments: [childId.uuidString]
            )
            return try rows.map { try Self.timer(from: $0) }
        }
    }

    // MARK: - Glance / state

    public func localBabyState(childId: UUID) async throws -> BabyStateDTO {
        // Targeted latest-of-type lookups — avoid pulling hundreds of events into memory
        // just to populate glance fields.
        let lastFeed = try await latestEvent(childId: childId, typePrefix: "feed_")
        let lastDiaper = try await latestEvent(childId: childId, type: EventType.diaper.rawValue)
        let lastMedicine = try await latestEvent(childId: childId, type: EventType.medicine.rawValue)
        let active = try await activeTimers(childId: childId).first
        return BabyStateDTO(
            childId: childId,
            lastFeed: lastFeed,
            lastDiaper: lastDiaper,
            activeTimer: active,
            lastMedicine: lastMedicine
        )
    }

    private func latestEvent(childId: UUID, type: String? = nil, typePrefix: String? = nil) async throws -> EventDTO? {
        try await dbQueue.read { db in
            let row: Row?
            if let type {
                row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM events
                        WHERE child_id = ? AND deleted_at IS NULL AND type = ?
                        ORDER BY started_at DESC LIMIT 1
                        """,
                    arguments: [childId.uuidString, type]
                )
            } else if let typePrefix {
                row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM events
                        WHERE child_id = ? AND deleted_at IS NULL AND type LIKE ?
                        ORDER BY started_at DESC LIMIT 1
                        """,
                    arguments: [childId.uuidString, typePrefix + "%"]
                )
            } else {
                row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM events
                        WHERE child_id = ? AND deleted_at IS NULL
                        ORDER BY started_at DESC LIMIT 1
                        """,
                    arguments: [childId.uuidString]
                )
            }
            guard let row else { return nil }
            return try Self.event(from: row)
        }
    }

    public func applyBabyState(_ state: BabyStateDTO) async throws {
        try await dbQueue.write { db in
            if let e = state.lastFeed { try Self.insertEvent(e, db: db) }
            if let e = state.lastDiaper { try Self.insertEvent(e, db: db) }
            if let e = state.lastMedicine { try Self.insertEvent(e, db: db) }
            if let t = state.activeTimer {
                try Self.insertTimer(t, db: db)
            } else {
                let now = Self.encodeDate(Date())
                try db.execute(
                    sql: """
                        UPDATE timers SET state = 'stopped',
                            stopped_at = COALESCE(stopped_at, ?),
                            updated_at = ?
                        WHERE child_id = ? AND state IN ('running', 'paused')
                        """,
                    arguments: [now, now, state.childId.uuidString]
                )
            }
        }
    }

    // MARK: - Sync envelopes

    public func applySyncEnvelope(_ envelope: SyncEnvelopeDTO) async throws {
        BenitoLog.store.debug("apply envelope \(envelope.type, privacy: .public)")
        switch envelope.type {
        case SyncMessageType.eventUpsert.rawValue:
            if let event = Self.decodePayload(EventDTO.self, envelope.payload) {
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
            if let timer = Self.decodePayload(TimerDTO.self, envelope.payload) {
                try await upsertTimer(timer)
            }
        case SyncMessageType.state.rawValue, SyncMessageType.refetchState.rawValue:
            try await handleStateHint(envelope.payload)
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

    // MARK: - Outbox

    public func enqueueOutbox(method: String, path: String, body: Data?) async throws -> Int64 {
        BenitoLog.store.notice("enqueue outbox \(method, privacy: .public) \(path, privacy: .public)")
        return try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO outbox (method, path, body, created_at) VALUES (?, ?, ?, ?)",
                arguments: [method, path, body, Self.encodeDate(Date())]
            )
            return db.lastInsertedRowID
        }
    }

    public func pendingOutbox() async throws -> [OutboxEntry] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, method, path, body, created_at FROM outbox ORDER BY id ASC"
            )
            return try rows.map { row in
                OutboxEntry(
                    id: row["id"],
                    method: row["method"],
                    path: row["path"],
                    body: row["body"],
                    createdAt: try Self.decodeDate(row["created_at"])
                )
            }
        }
    }

    public func deleteOutbox(id: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [id])
        }
    }

    public func pendingSyncPayloads() async throws -> [Data] {
        try await pendingOutbox().compactMap(\.body)
    }

    // MARK: - Prefs

    public func setPreference(_ key: String, value: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO prefs (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [key, value]
            )
        }
    }

    public func preference(_ key: String) async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM prefs WHERE key = ?", arguments: [key])
        }
    }

    // MARK: - Row encode / decode

    private static func insertChild(_ child: ChildDTO, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO children (id, family_id, name, birthdate, sex, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    family_id = excluded.family_id,
                    name = excluded.name,
                    birthdate = excluded.birthdate,
                    sex = excluded.sex,
                    created_at = excluded.created_at
                """,
            arguments: [
                child.id.uuidString,
                child.familyId.uuidString,
                child.name,
                child.birthdate,
                child.sex,
                encodeDate(child.createdAt),
            ]
        )
    }

    private static func insertEvent(_ event: EventDTO, db: Database) throws {
        let payloadText: String? = {
            guard let payload = event.payloadJson,
                  let data = try? BenitoJSON.encoder.encode(payload),
                  let s = String(data: data, encoding: .utf8)
            else { return nil }
            return s
        }()
        try db.execute(
            sql: """
                INSERT INTO events (
                    id, child_id, type, subtype, started_at, ended_at,
                    amount_value, amount_unit, side, notes, payload_json,
                    created_by, created_at, updated_at, deleted_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    child_id = excluded.child_id,
                    type = excluded.type,
                    subtype = excluded.subtype,
                    started_at = excluded.started_at,
                    ended_at = excluded.ended_at,
                    amount_value = excluded.amount_value,
                    amount_unit = excluded.amount_unit,
                    side = excluded.side,
                    notes = excluded.notes,
                    payload_json = excluded.payload_json,
                    created_by = excluded.created_by,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at,
                    deleted_at = excluded.deleted_at
                """,
            arguments: [
                event.id.uuidString,
                event.childId.uuidString,
                event.type,
                event.subtype,
                encodeDate(event.startedAt),
                event.endedAt.map(encodeDate),
                event.amountValue,
                event.amountUnit,
                event.side,
                event.notes,
                payloadText,
                event.createdBy.uuidString,
                encodeDate(event.createdAt),
                encodeDate(event.updatedAt),
                event.deletedAt.map(encodeDate),
            ]
        )
    }

    private static func insertTimer(_ timer: TimerDTO, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO timers (
                    id, child_id, kind, started_at, started_by, state, stopped_at, updated_at, side,
                    paused_at, paused_seconds
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    child_id = excluded.child_id,
                    kind = excluded.kind,
                    started_at = excluded.started_at,
                    started_by = excluded.started_by,
                    state = excluded.state,
                    stopped_at = excluded.stopped_at,
                    updated_at = excluded.updated_at,
                    side = excluded.side,
                    paused_at = excluded.paused_at,
                    paused_seconds = excluded.paused_seconds
                """,
            arguments: [
                timer.id.uuidString,
                timer.childId.uuidString,
                timer.kind,
                encodeDate(timer.startedAt),
                timer.startedBy.uuidString,
                timer.state,
                timer.stoppedAt.map(encodeDate),
                encodeDate(timer.updatedAt),
                timer.side,
                timer.pausedAt.map(encodeDate),
                timer.pausedSeconds,
            ]
        )
    }

    private static func child(from row: Row) throws -> ChildDTO {
        ChildDTO(
            id: try uuid(row["id"]),
            familyId: try uuid(row["family_id"]),
            name: row["name"],
            birthdate: row["birthdate"],
            sex: row["sex"],
            createdAt: try decodeDate(row["created_at"])
        )
    }

    private static func event(from row: Row) throws -> EventDTO {
        let payload: JSONValue? = {
            guard let text: String = row["payload_json"],
                  let data = text.data(using: .utf8)
            else { return nil }
            return try? BenitoJSON.decoder.decode(JSONValue.self, from: data)
        }()
        return EventDTO(
            id: try uuid(row["id"]),
            childId: try uuid(row["child_id"]),
            type: row["type"],
            subtype: row["subtype"],
            startedAt: try decodeDate(row["started_at"]),
            endedAt: try optionalDate(row["ended_at"]),
            amountValue: row["amount_value"],
            amountUnit: row["amount_unit"],
            side: row["side"],
            notes: row["notes"],
            payloadJson: payload,
            createdBy: try uuid(row["created_by"]),
            createdAt: try decodeDate(row["created_at"]),
            updatedAt: try decodeDate(row["updated_at"]),
            deletedAt: try optionalDate(row["deleted_at"])
        )
    }

    private static func timer(from row: Row) throws -> TimerDTO {
        TimerDTO(
            id: try uuid(row["id"]),
            childId: try uuid(row["child_id"]),
            kind: row["kind"],
            startedAt: try decodeDate(row["started_at"]),
            startedBy: try uuid(row["started_by"]),
            state: row["state"],
            stoppedAt: try optionalDate(row["stopped_at"]),
            updatedAt: try decodeDate(row["updated_at"]),
            side: row["side"],
            pausedAt: try optionalDate(row["paused_at"]),
            pausedSeconds: row["paused_seconds"]
        )
    }

    private static func uuid(_ raw: String) throws -> UUID {
        guard let id = UUID(uuidString: raw) else {
            throw GRDBStoreError.invalidUUID(raw)
        }
        return id
    }

    private static func encodeDate(_ date: Date) -> String {
        fractionalISO8601.string(from: date)
    }

    private static func decodeDate(_ raw: String) throws -> Date {
        if let d = fractionalISO8601.date(from: raw) ?? internetISO8601.date(from: raw) {
            return d
        }
        throw GRDBStoreError.invalidDate(raw)
    }

    private static func optionalDate(_ raw: String?) throws -> Date? {
        guard let raw else { return nil }
        return try decodeDate(raw)
    }

    private static func decodePayload<T: Decodable>(_ type: T.Type, _ payload: JSONValue) -> T? {
        guard let data = try? BenitoJSON.encoder.encode(payload) else { return nil }
        return try? BenitoJSON.decoder.decode(T.self, from: data)
    }

    private static let fractionalISO8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let internetISO8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

public enum GRDBStoreError: Error, Sendable {
    case invalidUUID(String)
    case invalidDate(String)
}

#endif
