import Foundation

// MARK: - Date decoding (RFC3339 with optional fractional seconds)

public enum BenitoJSON {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = fractionalISO8601.date(from: s) ?? internetISO8601.date(from: s) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
        }
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(fractionalISO8601.string(from: date))
        }
        return e
    }()

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

    public static func string(from date: Date) -> String {
        fractionalISO8601.string(from: date)
    }
}

public struct UserDTO: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var email: String
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, email
        case createdAt = "created_at"
    }
}

public struct FamilyDTO: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var inviteCode: String
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name
        case inviteCode = "invite_code"
        case createdAt = "created_at"
    }
}

public struct ChildDTO: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var familyId: UUID
    public var name: String
    public var birthdate: String?
    public var sex: String?
    public var createdAt: Date


    public init(
        id: UUID,
        familyId: UUID,
        name: String,
        birthdate: String?,
        sex: String?,
        createdAt: Date
    ) {
        self.id = id
        self.familyId = familyId
        self.name = name
        self.birthdate = birthdate
        self.sex = sex
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, birthdate, sex
        case familyId = "family_id"
        case createdAt = "created_at"
    }
}

/// v1 event types from SPEC (feed/diaper/sleep first).
public enum EventType: String, Codable, Sendable, CaseIterable {
    case feedBreast = "feed_breast"
    case feedBottle = "feed_bottle"
    case feedSolid = "feed_solid"
    case diaper
    case sleep
    case pump
    case medicine
    case temperature
    case growth
    case milestone
    case note
    case custom
    /// Timed span — outing (walk / car ride) or crying; `subtype` is an `ActivityKind` raw value.
    case activity
}

public struct EventDTO: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var childId: UUID
    public var type: String
    public var subtype: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var amountValue: Double?
    public var amountUnit: String?
    public var side: String?
    public var notes: String?
    public var payloadJson: JSONValue?
    public var createdBy: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?


    public init(
        id: UUID,
        childId: UUID,
        type: String,
        subtype: String?,
        startedAt: Date,
        endedAt: Date?,
        amountValue: Double?,
        amountUnit: String?,
        side: String?,
        notes: String?,
        payloadJson: JSONValue?,
        createdBy: UUID,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date?
    ) {
        self.id = id
        self.childId = childId
        self.type = type
        self.subtype = subtype
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.amountValue = amountValue
        self.amountUnit = amountUnit
        self.side = side
        self.notes = notes
        self.payloadJson = payloadJson
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, type, subtype, side, notes
        case childId = "child_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case amountValue = "amount_value"
        case amountUnit = "amount_unit"
        case payloadJson = "payload_json"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    /// Seconds the timer that produced this event spent paused (`payload_json.paused_seconds`), else 0.
    public var pausedSeconds: Int {
        guard case .object(let dict)? = payloadJson,
              case .number(let value)? = dict["paused_seconds"],
              value.isFinite, value > 0
        else { return 0 }
        return Int(value)
    }

    /// Wall-clock duration minus paused time; nil while the event is open-ended.
    public var activeDuration: TimeInterval? {
        guard let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt) - TimeInterval(pausedSeconds))
    }
}

public struct TimerDTO: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var childId: UUID
    public var kind: String
    public var startedAt: Date
    public var startedBy: UUID
    public var state: String
    public var stoppedAt: Date?
    public var updatedAt: Date
    public var side: String?
    /// Start of the pause in progress (state `paused`), else nil.
    public var pausedAt: Date?
    /// Seconds of completed pauses; the pause in progress is `now - pausedAt` and not included.
    public var pausedSeconds: Int


    public init(
        id: UUID,
        childId: UUID,
        kind: String,
        startedAt: Date,
        startedBy: UUID,
        state: String,
        stoppedAt: Date?,
        updatedAt: Date,
        side: String? = nil,
        pausedAt: Date? = nil,
        pausedSeconds: Int = 0
    ) {
        self.id = id
        self.childId = childId
        self.kind = kind
        self.startedAt = startedAt
        self.startedBy = startedBy
        self.state = state
        self.stoppedAt = stoppedAt
        self.updatedAt = updatedAt
        self.side = side
        self.pausedAt = pausedAt
        self.pausedSeconds = pausedSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        childId = try c.decode(UUID.self, forKey: .childId)
        kind = try c.decode(String.self, forKey: .kind)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        startedBy = try c.decode(UUID.self, forKey: .startedBy)
        state = try c.decode(String.self, forKey: .state)
        stoppedAt = try c.decodeIfPresent(Date.self, forKey: .stoppedAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        side = try c.decodeIfPresent(String.self, forKey: .side)
        pausedAt = try c.decodeIfPresent(Date.self, forKey: .pausedAt)
        pausedSeconds = try c.decodeIfPresent(Int.self, forKey: .pausedSeconds) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, state, side
        case childId = "child_id"
        case startedAt = "started_at"
        case startedBy = "started_by"
        case stoppedAt = "stopped_at"
        case updatedAt = "updated_at"
        case pausedAt = "paused_at"
        case pausedSeconds = "paused_seconds"
    }

    public var isPaused: Bool { state == "paused" }

    /// Running or paused (i.e. not stopped).
    public var isActive: Bool { state == "running" || state == "paused" }

    /// Active (unpaused) time so far; frozen at `pausedAt` while paused. Never negative.
    ///
    /// Timestamps are phone-authored (`at` on start/pause/resume/stop) and stored by the server
    /// as-is. Default `now` is device `Date()` / `TimelineView` — same clock domain, so a fresh
    /// start shows ~0:00 without any server-skew correction.
    public func elapsed(at now: Date = Date()) -> TimeInterval {
        let end: Date
        if let pausedAt {
            end = pausedAt
        } else if state == "stopped", let stoppedAt {
            end = stoppedAt
        } else {
            end = now
        }
        return max(0, end.timeIntervalSince(startedAt) - TimeInterval(pausedSeconds))
    }

    /// `startedAt` shifted by completed pauses — for `Text(timerInterval:)` count-ups
    /// (Live Activity / Lock Screen) that tick on the device clock.
    public var effectiveStart: Date {
        startedAt.addingTimeInterval(TimeInterval(pausedSeconds))
    }
}

public struct BabyStateDTO: Codable, Sendable, Hashable {
    public var childId: UUID
    public var lastFeed: EventDTO?
    public var lastDiaper: EventDTO?
    public var activeTimer: TimerDTO?
    public var lastMedicine: EventDTO?


    public init(
        childId: UUID,
        lastFeed: EventDTO?,
        lastDiaper: EventDTO?,
        activeTimer: TimerDTO?,
        lastMedicine: EventDTO?
    ) {
        self.childId = childId
        self.lastFeed = lastFeed
        self.lastDiaper = lastDiaper
        self.activeTimer = activeTimer
        self.lastMedicine = lastMedicine
    }

    enum CodingKeys: String, CodingKey {
        case childId = "child_id"
        case lastFeed = "last_feed"
        case lastDiaper = "last_diaper"
        case activeTimer = "active_timer"
        case lastMedicine = "last_medicine"
    }
}

public struct AuthResponseDTO: Codable, Sendable {
    public var token: String
    public var user: UserDTO
}

public struct CreateFamilyResponseDTO: Codable, Sendable {
    public var family: FamilyDTO
    public var child: ChildDTO
    public var inviteCode: String

    enum CodingKeys: String, CodingKey {
        case family, child
        case inviteCode = "invite_code"
    }
}

/// `POST /families/pairing-tokens`: short-lived, single-use token a partner redeems via `POST /families/pair`.
public struct PairingTokenDTO: Codable, Sendable {
    public var token: String
    public var familyName: String
    public var expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case token
        case familyName = "family_name"
        case expiresAt = "expires_at"
    }
}

public struct MeResponseDTO: Codable, Sendable {
    public var user: UserDTO
    public var family: FamilyDTO?
    public var children: [ChildDTO]
    /// Absent on servers before migration 006.
    public var role: FamilyRole?
    public var accessExpiresAt: Date?
    public var hasDeviceKey: Bool?

    public init(
        user: UserDTO,
        family: FamilyDTO?,
        children: [ChildDTO],
        role: FamilyRole? = nil,
        accessExpiresAt: Date? = nil,
        hasDeviceKey: Bool? = nil
    ) {
        self.user = user
        self.family = family
        self.children = children
        self.role = role
        self.accessExpiresAt = accessExpiresAt
        self.hasDeviceKey = hasDeviceKey
    }

    enum CodingKeys: String, CodingKey {
        case user, family, children, role
        case accessExpiresAt = "access_expires_at"
        case hasDeviceKey = "has_device_key"
    }
}

public struct ExportBundleDTO: Codable, Sendable {
    public var exportedAt: Date
    public var family: FamilyDTO?
    public var children: [ChildDTO]
    public var events: [EventDTO]
    public var timers: [TimerDTO]

    enum CodingKeys: String, CodingKey {
        case family, children, events, timers
        case exportedAt = "exported_at"
    }
}

public struct CreateEventRequestDTO: Codable, Sendable {
    public var childId: UUID
    public var type: String
    public var subtype: String?
    public var startedAt: Date?
    public var endedAt: Date?
    public var amountValue: Double?
    public var amountUnit: String?
    public var side: String?
    public var notes: String?
    public var payloadJson: JSONValue?

    public init(
        childId: UUID,
        type: String,
        subtype: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        amountValue: Double? = nil,
        amountUnit: String? = nil,
        side: String? = nil,
        notes: String? = nil,
        payloadJson: JSONValue? = nil
    ) {
        self.childId = childId
        self.type = type
        self.subtype = subtype
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.amountValue = amountValue
        self.amountUnit = amountUnit
        self.side = side
        self.notes = notes
        self.payloadJson = payloadJson
    }

    enum CodingKeys: String, CodingKey {
        case type, subtype, side, notes
        case childId = "child_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case amountValue = "amount_value"
        case amountUnit = "amount_unit"
        case payloadJson = "payload_json"
    }
}

/// Partial update for `PATCH /events/{id}`. Nil fields are omitted from the body so the server
/// keeps their current values (COALESCE semantics).
public struct UpdateEventRequestDTO: Encodable, Sendable, Equatable {
    public var startedAt: Date?
    public var endedAt: Date?
    public var subtype: String?
    public var side: String?
    public var amountValue: Double?
    public var amountUnit: String?
    public var notes: String?

    public init(
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        subtype: String? = nil,
        side: String? = nil,
        amountValue: Double? = nil,
        amountUnit: String? = nil,
        notes: String? = nil
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.subtype = subtype
        self.side = side
        self.amountValue = amountValue
        self.amountUnit = amountUnit
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case subtype, side, notes
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case amountValue = "amount_value"
        case amountUnit = "amount_unit"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encodeIfPresent(subtype, forKey: .subtype)
        try c.encodeIfPresent(side, forKey: .side)
        try c.encodeIfPresent(amountValue, forKey: .amountValue)
        try c.encodeIfPresent(amountUnit, forKey: .amountUnit)
        try c.encodeIfPresent(notes, forKey: .notes)
    }
}

/// Minimal JSON value for payload_json alignment with server `serde_json::Value`.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// MARK: - Sync protocol

public enum SyncMessageType: String, Codable, Sendable {
    case hello
    case error
    case auth
    case ping
    case pong
    case eventUpsert = "event.upsert"
    case eventDelete = "event.delete"
    case timerUpsert = "timer.upsert"
    case timerStop = "timer.stop"
    case state
    case refetchState = "refetch_state"
}

public struct SyncEnvelopeDTO: Codable, Sendable {
    public var type: String
    public var payload: JSONValue
    public var at: Date
    public var clientId: String?


    public init(type: String, payload: JSONValue, at: Date, clientId: String? = nil) {
        self.type = type
        self.payload = payload
        self.at = at
        self.clientId = clientId
    }

    enum CodingKeys: String, CodingKey {
        case type, payload, at
        case clientId = "client_id"
    }
}

// Public memberwise inits live on the types above (Swift 6 synthesizes
// conflicting extension inits when properties are public).

public struct DailySummaryDTO: Codable, Sendable {
    public var childId: UUID
    public var from: Date
    public var to: Date
    public var day: String?
    public var feedBreastCount: Int
    public var feedBreastLeft: Int
    public var feedBreastRight: Int
    public var feedBottleCount: Int
    public var bottleOzTotal: Double
    public var bottleMlTotal: Double
    public var bottleOzEquiv: Double
    public var feedSolidCount: Int
    /// Sum of timed feed durations in seconds (started_at+ended_at), excluding paused time.
    public var feedSeconds: Double
    /// Nursing seconds clipped to [from, to); nil from servers that predate the field.
    public var nursingSeconds: Double?
    /// Crying (`activity` / `crying`) seconds clipped to [from, to); nil from older servers.
    public var cryingSeconds: Double?
    public var diaperWet: Int
    public var diaperDirty: Int
    public var diaperBoth: Int
    public var diaperOther: Int
    public var sleepEventCount: Int
    public var sleepHours: Double
    public var pumpCount: Int
    public var medicineCount: Int
    public var totalEvents: Int

    enum CodingKeys: String, CodingKey {
        case from, to, day
        case childId = "child_id"
        case feedBreastCount = "feed_breast_count"
        case feedBreastLeft = "feed_breast_left"
        case feedBreastRight = "feed_breast_right"
        case feedBottleCount = "feed_bottle_count"
        case bottleOzTotal = "bottle_oz_total"
        case bottleMlTotal = "bottle_ml_total"
        case bottleOzEquiv = "bottle_oz_equiv"
        case feedSolidCount = "feed_solid_count"
        case feedSeconds = "feed_seconds"
        case nursingSeconds = "nursing_seconds"
        case cryingSeconds = "crying_seconds"
        case diaperWet = "diaper_wet"
        case diaperDirty = "diaper_dirty"
        case diaperBoth = "diaper_both"
        case diaperOther = "diaper_other"
        case sleepEventCount = "sleep_event_count"
        case sleepHours = "sleep_hours"
        case pumpCount = "pump_count"
        case medicineCount = "medicine_count"
        case totalEvents = "total_events"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        childId = try c.decode(UUID.self, forKey: .childId)
        from = try c.decode(Date.self, forKey: .from)
        to = try c.decode(Date.self, forKey: .to)
        day = try c.decodeIfPresent(String.self, forKey: .day)
        feedBreastCount = try c.decode(Int.self, forKey: .feedBreastCount)
        feedBreastLeft = try c.decode(Int.self, forKey: .feedBreastLeft)
        feedBreastRight = try c.decode(Int.self, forKey: .feedBreastRight)
        feedBottleCount = try c.decode(Int.self, forKey: .feedBottleCount)
        bottleOzTotal = try c.decode(Double.self, forKey: .bottleOzTotal)
        bottleMlTotal = try c.decode(Double.self, forKey: .bottleMlTotal)
        bottleOzEquiv = try c.decode(Double.self, forKey: .bottleOzEquiv)
        feedSolidCount = try c.decode(Int.self, forKey: .feedSolidCount)
        feedSeconds = try c.decodeIfPresent(Double.self, forKey: .feedSeconds) ?? 0
        nursingSeconds = try c.decodeIfPresent(Double.self, forKey: .nursingSeconds)
        cryingSeconds = try c.decodeIfPresent(Double.self, forKey: .cryingSeconds)
        diaperWet = try c.decode(Int.self, forKey: .diaperWet)
        diaperDirty = try c.decode(Int.self, forKey: .diaperDirty)
        diaperBoth = try c.decode(Int.self, forKey: .diaperBoth)
        diaperOther = try c.decode(Int.self, forKey: .diaperOther)
        sleepEventCount = try c.decode(Int.self, forKey: .sleepEventCount)
        sleepHours = try c.decode(Double.self, forKey: .sleepHours)
        pumpCount = try c.decode(Int.self, forKey: .pumpCount)
        medicineCount = try c.decode(Int.self, forKey: .medicineCount)
        totalEvents = try c.decode(Int.self, forKey: .totalEvents)
    }
}
