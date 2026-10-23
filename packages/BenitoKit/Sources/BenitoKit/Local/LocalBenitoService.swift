import Foundation

/// `BenitoService` answered by this device: the same rules as the family server
/// (server/src/routes/{events,timers,summary,export}.rs), over the local store.
/// Failures use the server's status codes so the app treats both the same way.
public actor LocalBenitoService: BenitoService {
    /// Kinds whose timer stops into an `activity` event (server `ACTIVITY_SUBTYPES`).
    static let activitySubtypes: Set<String> = Set(ActivityKind.allCases.map(\.rawValue))

    private let store: any BenitoStore
    private let clock: @Sendable () -> Date

    public init(store: any BenitoStore, clock: @escaping @Sendable () -> Date = { Date.now }) {
        self.store = store
        self.clock = clock
    }

    // MARK: - Setup

    /// First run on this device: the local person, family and baby. Returns what `/me` will.
    ///
    /// One family per device: when a profile already exists (setup submitted twice, or a
    /// second call while the first is still writing) this returns it instead of starting
    /// another family, which would orphan the first baby.
    @discardableResult
    public func createProfile(yourName: String, familyName: String, childName: String) async throws -> MeResponseDTO {
        let task = profileCreation ?? Task {
            try await self.insertProfileIfMissing(yourName: yourName, familyName: familyName, childName: childName)
        }
        profileCreation = task
        let result = await task.result
        if profileCreation == task { profileCreation = nil }
        try result.get()
        return try await me()
    }

    private var profileCreation: Task<Void, Error>?

    private func insertProfileIfMissing(yourName: String, familyName: String, childName: String) async throws {
        if try await LocalProfile.load(from: store) != nil { return }
        let now = clock()
        let profile = LocalProfile(
            userId: UUID(),
            userName: Self.trimmed(yourName, or: "Parent"),
            familyId: UUID(),
            familyName: Self.trimmed(familyName, or: "Our family"),
            createdAt: now
        )
        // Baby first: the saved profile is what marks setup as done.
        try await store.upsertChild(ChildDTO(
            id: UUID(),
            familyId: profile.familyId,
            name: Self.trimmed(childName, or: "Baby"),
            birthdate: nil,
            sex: nil,
            createdAt: now
        ))
        try await profile.save(to: store)
    }

    // MARK: - BenitoService

    public func me() async throws -> MeResponseDTO {
        let profile = try await requireProfile()
        return MeResponseDTO(
            user: UserDTO(id: profile.userId, name: profile.userName, email: "", createdAt: profile.createdAt),
            family: FamilyDTO(id: profile.familyId, name: profile.familyName, inviteCode: "", createdAt: profile.createdAt),
            children: try await children(of: profile),
            role: .parent
        )
    }

    public func state(childId: UUID) async throws -> BabyStateDTO {
        try await requireChild(childId)
        return try await store.localBabyState(childId: childId)
    }

    public func createEvent(_ request: CreateEventRequestDTO) async throws -> EventDTO {
        guard EventType(rawValue: request.type) != nil else {
            throw Self.error(400, "invalid event type '\(request.type)'")
        }
        try Self.validateActivitySubtype(type: request.type, subtype: request.subtype)
        let profile = try await requireChild(request.childId)
        if let id = request.id, let existing = try await store.event(id: id) {
            return existing
        }
        let now = clock()
        let event = EventDTO(
            id: request.id ?? UUID(),
            childId: request.childId,
            type: request.type,
            subtype: request.subtype,
            startedAt: request.startedAt ?? now,
            endedAt: request.endedAt,
            amountValue: request.amountValue,
            amountUnit: request.amountUnit,
            side: request.side,
            notes: request.notes,
            payloadJson: request.payloadJson,
            createdBy: profile.userId,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil
        )
        try await store.upsertEvent(event)
        return event
    }

    public func updateEvent(id: UUID, _ changes: UpdateEventRequestDTO) async throws -> EventDTO {
        guard var event = try await store.event(id: id), event.deletedAt == nil else {
            throw Self.error(404, "event not found")
        }
        try await requireChild(event.childId)
        let now = clock()
        if changes.startedAt != nil || changes.endedAt != nil {
            if let started = changes.startedAt, started > now.addingTimeInterval(5 * 60) {
                throw Self.error(400, "started_at cannot be in the future")
            }
            let started = changes.startedAt ?? event.startedAt
            if let ended = changes.endedAt ?? event.endedAt, ended < started {
                throw Self.error(400, "ended_at cannot be before started_at")
            }
        }
        if changes.subtype != nil {
            try Self.validateActivitySubtype(type: event.type, subtype: changes.subtype)
        }
        event.subtype = changes.subtype ?? event.subtype
        event.startedAt = changes.startedAt ?? event.startedAt
        event.endedAt = changes.endedAt ?? event.endedAt
        event.amountValue = changes.amountValue ?? event.amountValue
        event.amountUnit = changes.amountUnit ?? event.amountUnit
        event.side = changes.side ?? event.side
        event.notes = changes.notes ?? event.notes
        event.updatedAt = now
        try await store.upsertEvent(event)
        return event
    }

    public func deleteEvent(id: UUID) async throws {
        guard let event = try await store.event(id: id), event.deletedAt == nil else {
            throw Self.error(404, "event not found")
        }
        try await requireChild(event.childId)
        try await store.softDeleteEvent(id: id)
    }

    public func startTimer(childId: UUID, kind: String, side: String?, at: Date) async throws -> TimerDTO {
        let now = try actionTime(at)
        let kind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kind.isEmpty else { throw Self.error(400, "kind required (e.g. sleep, feed_breast)") }
        let side = Self.normalizedSide(side)
        if kind == EventType.feedBreast.rawValue, side == nil {
            throw Self.error(400, "feed_breast timers need a side (L, R or BOTH)")
        }
        let profile = try await requireChild(childId)
        let timer = TimerDTO(
            id: UUID(),
            childId: childId,
            kind: kind,
            startedAt: now,
            startedBy: profile.userId,
            state: "running",
            stoppedAt: nil,
            updatedAt: clock(),
            side: side,
            pausedAt: nil,
            pausedSeconds: 0
        )
        try await store.upsertTimer(timer)
        return timer
    }

    public func pauseTimer(id: UUID, at: Date) async throws -> TimerDTO {
        let now = try actionTime(at)
        var timer = try await requireTimer(id)
        guard timer.state == "running" else { throw Self.error(409, "timer is not running") }
        guard now >= timer.startedAt else { throw Self.error(400, "at cannot be before the timer started") }
        timer.state = "paused"
        timer.pausedAt = now
        timer.updatedAt = clock()
        try await store.upsertTimer(timer)
        return timer
    }

    public func resumeTimer(id: UUID, at: Date) async throws -> TimerDTO {
        let now = try actionTime(at)
        var timer = try await requireTimer(id)
        guard timer.state == "paused" else { throw Self.error(409, "timer is not paused") }
        if let pausedAt = timer.pausedAt, now < pausedAt {
            throw Self.error(400, "at cannot be before the timer was paused")
        }
        timer.pausedSeconds += Self.openPauseSeconds(timer, now: now)
        timer.state = "running"
        timer.pausedAt = nil
        timer.updatedAt = clock()
        try await store.upsertTimer(timer)
        return timer
    }

    public func adjustTimerStart(id: UUID, startedAt: Date, at: Date) async throws -> TimerDTO {
        let now = clock()
        var timer = try await requireTimer(id)
        guard timer.isActive else { throw Self.error(409, "timer is not active") }
        if startedAt > now.addingTimeInterval(60) {
            throw Self.error(400, "started_at cannot be in the future")
        }
        if startedAt < now.addingTimeInterval(-24 * 60 * 60) {
            throw Self.error(400, "started_at cannot be more than 24 hours ago")
        }
        if let pausedAt = timer.pausedAt, startedAt > pausedAt {
            throw Self.error(400, "started_at cannot be after the timer was paused")
        }
        timer.startedAt = startedAt
        timer.updatedAt = now
        try await store.upsertTimer(timer)
        return timer
    }

    /// Stops the timer and logs what it timed (sleep, nursing, walk / car ride / crying),
    /// exactly like the server. Stopping an already-stopped timer returns it unchanged.
    public func stopTimer(id: UUID, at: Date) async throws -> TimerDTO {
        let now = try actionTime(at)
        var timer = try await requireTimer(id)
        if timer.state == "stopped" { return timer }
        guard now >= timer.startedAt else { throw Self.error(400, "at cannot be before the timer started") }
        let updatedAt = clock()
        timer.pausedSeconds += Self.openPauseSeconds(timer, now: now)
        timer.state = "stopped"
        timer.stoppedAt = now
        timer.pausedAt = nil
        timer.updatedAt = updatedAt

        if let (type, subtype) = Self.autoEventKind(for: timer.kind) {
            let payload: JSONValue? = timer.pausedSeconds > 0
                ? .object(["paused_seconds": .number(Double(timer.pausedSeconds))])
                : nil
            let profile = try await requireProfile()
            try await store.upsertEvent(EventDTO(
                id: UUID(),
                childId: timer.childId,
                type: type,
                subtype: subtype,
                startedAt: timer.startedAt,
                endedAt: now,
                amountValue: nil,
                amountUnit: nil,
                side: type == EventType.feedBreast.rawValue ? timer.side : nil,
                notes: nil,
                payloadJson: payload,
                createdBy: profile.userId,
                createdAt: updatedAt,
                updatedAt: updatedAt,
                deletedAt: nil
            ))
        }
        try await store.upsertTimer(timer)
        return timer
    }

    public func listTimers(childId: UUID?) async throws -> [TimerDTO] {
        let profile = try await requireProfile()
        var ids = try await children(of: profile).map(\.id)
        if let childId { ids = ids.filter { $0 == childId } }
        var timers: [TimerDTO] = []
        for id in ids {
            timers += try await store.activeTimers(childId: id)
        }
        return timers.sorted { $0.startedAt > $1.startedAt }
    }

    public func exportBundle() async throws -> ExportBundleDTO {
        let me = try await me()
        var events: [EventDTO] = []
        var timers: [TimerDTO] = []
        for child in me.children {
            events += try await allEvents(childId: child.id)
            timers += try await store.activeTimers(childId: child.id)
        }
        return ExportBundleDTO(exportedAt: clock(), family: me.family, children: me.children, events: events, timers: timers)
    }

    /// Same columns as the server's `GET /export.csv`.
    public func exportCSV() async throws -> Data {
        let me = try await me()
        var events: [EventDTO] = []
        for child in me.children {
            events += try await allEvents(childId: child.id)
        }
        events.sort { $0.startedAt < $1.startedAt }
        var csv = "id,child_id,type,subtype,started_at,ended_at,amount_value,amount_unit,side,notes,created_by,created_at\n"
        for e in events {
            let fields: [String] = [
                e.id.uuidString.lowercased(),
                e.childId.uuidString.lowercased(),
                e.type,
                e.subtype ?? "",
                BenitoJSON.string(from: e.startedAt),
                e.endedAt.map(BenitoJSON.string(from:)) ?? "",
                e.amountValue.map(Self.csvNumber) ?? "",
                e.amountUnit ?? "",
                e.side ?? "",
                e.notes ?? "",
                e.createdBy.uuidString.lowercased(),
                BenitoJSON.string(from: e.createdAt),
            ]
            csv += fields.map(Self.csvEscape).joined(separator: ",") + "\n"
        }
        return Data(csv.utf8)
    }

    public func dailySummary(childId: UUID, day: String?, from: Date?, to: Date?) async throws -> DailySummaryDTO {
        let window: (from: Date, to: Date, day: String?)
        do {
            window = try DailySummaryCalculator.window(day: day, from: from, to: to, now: clock())
        } catch DailySummaryCalculator.WindowError.toNotAfterFrom {
            throw Self.error(400, "to must be after from")
        } catch {
            throw Self.error(400, "day must be YYYY-MM-DD")
        }
        try await requireChild(childId)
        let events = try await store.events(childId: childId, from: window.from, to: window.to)
        return DailySummaryCalculator.summarize(
            childId: childId,
            events: events,
            from: window.from,
            to: window.to,
            day: window.day
        )
    }

    // MARK: - Helpers

    private func requireProfile() async throws -> LocalProfile {
        guard let profile = try await LocalProfile.load(from: store) else {
            throw Self.error(404, "Benito isn't set up on this device yet")
        }
        return profile
    }

    @discardableResult
    private func requireChild(_ childId: UUID) async throws -> LocalProfile {
        let profile = try await requireProfile()
        guard try await children(of: profile).contains(where: { $0.id == childId }) else {
            throw Self.error(404, "child not found")
        }
        return profile
    }

    private func requireTimer(_ id: UUID) async throws -> TimerDTO {
        guard let timer = try await store.timer(id: id) else { throw Self.error(404, "timer not found") }
        try await requireChild(timer.childId)
        return timer
    }

    private func children(of profile: LocalProfile) async throws -> [ChildDTO] {
        try await store.children()
            .filter { $0.familyId == profile.familyId }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func allEvents(childId: UUID) async throws -> [EventDTO] {
        try await store.events(childId: childId, from: .distantPast, to: .distantFuture)
    }

    /// The phone's clock within the server's slack: 5 minutes ahead, 24 hours back.
    private func actionTime(_ at: Date) throws -> Date {
        let now = clock()
        if at > now.addingTimeInterval(5 * 60) {
            throw Self.error(400, "at cannot be more than 5 minutes in the future")
        }
        if at < now.addingTimeInterval(-24 * 60 * 60) {
            throw Self.error(400, "at cannot be more than 24 hours ago")
        }
        return at
    }

    static func autoEventKind(for kind: String) -> (type: String, subtype: String?)? {
        switch kind {
        case EventType.sleep.rawValue: (EventType.sleep.rawValue, nil)
        case EventType.feedBreast.rawValue: (EventType.feedBreast.rawValue, nil)
        case let other where activitySubtypes.contains(other): (EventType.activity.rawValue, other)
        default: nil
        }
    }

    static func normalizedSide(_ side: String?) -> String? {
        guard let value = side?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              ["L", "R", "BOTH"].contains(value)
        else { return nil }
        return value
    }

    static func openPauseSeconds(_ timer: TimerDTO, now: Date) -> Int {
        guard timer.state == "paused", let pausedAt = timer.pausedAt else { return 0 }
        return max(0, Int(now.timeIntervalSince(pausedAt).rounded(.towardZero)))
    }

    static func validateActivitySubtype(type: String, subtype: String?) throws {
        guard type == EventType.activity.rawValue else { return }
        guard let subtype, activitySubtypes.contains(subtype) else {
            throw error(400, "activity subtype must be one of walk, car_ride, crying")
        }
    }

    static func error(_ status: Int, _ message: String) -> APIClientError {
        let body = try? JSONSerialization.data(withJSONObject: ["error": message])
        return .httpStatus(status, body)
    }

    private static func trimmed(_ value: String, or fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func csvNumber(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    private static func csvEscape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
