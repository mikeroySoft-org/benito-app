import BenitoKit
import Foundation

/// Siri-friendly failures for Benito's App Intents. The message is what Siri speaks / shows.
enum IntentError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case noServerURL
    case notSignedIn
    case noChild
    case network
    case noActiveTimer(childName: String)
    case timerAlreadyRunning(childName: String, timerLabel: String)
    case timerChanged
    case invalidAmount
    case medicineNameRequired
    case invalidDose
    case invalidPumpAmount
    case invalidPumpDuration
    case unexpectedResponse
    case server(status: Int)

    var message: String {
        switch self {
        case .noServerURL:
            return "Open Benito and connect to your server first."
        case .notSignedIn:
            return "Open Benito and sign in first."
        case .noChild:
            return "Open Benito and add your baby first."
        case .network:
            return "Couldn't reach your Benito server."
        case .noActiveTimer(let name):
            return "\(name) doesn't have a timer running."
        case .timerAlreadyRunning(let name, let label):
            return "\(name) already has a \(label) timer running — say 'done feeding \(name)' or '\(name) woke up' to stop it."
        case .timerChanged:
            return "That timer just changed on another device. Try again."
        case .invalidAmount:
            return "That doesn't sound like a bottle amount. Try again with the number of ounces."
        case .medicineNameRequired:
            return "Say which medicine to log."
        case .invalidDose:
            return "That doesn't sound like a dose. Try a number up to 40, or zero to skip."
        case .invalidPumpAmount:
            return "That doesn't sound like a pump amount. Try the number of ounces, or zero to skip."
        case .invalidPumpDuration:
            return "That doesn't sound like a pump length. Try the number of minutes, or zero to skip."
        case .unexpectedResponse:
            return "Your Benito server sent an unexpected reply. Make sure it's up to date."
        case .server(let status):
            return "Your Benito server returned an error (\(status))."
        }
    }

    var errorDescription: String? { message }

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// Talks to the Benito server (or, in on-device mode, this phone's store) on behalf of App Intents
/// (Siri, Shortcuts, Live Activity buttons).
/// Independent of the app's `AppModel`: reads the server URL the app saved, the session token
/// from the Keychain, and resolves the child via `GET /me` (cached in `UserDefaults`). After
/// every mutation it re-reads `/state` and refreshes the Live Activity.
struct BenitoIntentBackend: Sendable {
    static let serverURLKey = "serverURL"
    static let childIdKey = ShortcutChildStore.idKey
    static let childNameKey = ShortcutChildStore.nameKey

    let client: any BenitoService
    let childId: UUID
    let childName: String
    /// `/state` as of `connect()`.
    let initialState: BabyStateDTO

    /// The running or paused timer as of `connect()`.
    var activeTimer: TimerDTO? {
        initialState.activeTimer.flatMap { $0.isActive ? $0 : nil }
    }

    // MARK: - Connect

    /// Builds a client for the saved server + session and loads the child's current state.
    static func connect() async throws -> BenitoIntentBackend {
        let client = try makeClient()
        if let cached = cachedChild() {
            do {
                let state = try await client.state(childId: cached.id)
                return BenitoIntentBackend(client: client, childId: cached.id, childName: cached.name, initialState: state)
            } catch APIClientError.httpStatus(let status, _) where [401, 403, 404].contains(status) {
                // The cached child may belong to a previous family/server; re-resolve via /me
                // (which reports a genuinely expired session as 401 → "sign in first").
                BenitoLog.api.notice("intent cached child rejected (\(status, privacy: .public)); refreshing from /me")
                clearCachedChild()
            } catch {
                throw mapped(error)
            }
        }
        let child = try await fetchChild(client)
        let state = try await perform { try await client.state(childId: child.id) }
        return BenitoIntentBackend(client: client, childId: child.id, childName: child.name, initialState: state)
    }

    private static func makeClient() throws -> any BenitoService {
        if BenitoMode.current() == .onDevice {
            // Same store and rules as the app; the app process hears about the change below.
            return LocalBenitoService(store: LocalStoreFactory.shared)
        }
        let raw = UserDefaults.standard.string(forKey: serverURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: raw), url.scheme != nil, url.host != nil else {
            BenitoLog.api.notice("intent: no server URL configured")
            throw IntentError.noServerURL
        }
        let token: String?
        do {
            token = try KeychainSessionTokenStore().token(for: url)
        } catch {
            BenitoLog.api.error("intent: session token unavailable: \(String(describing: error), privacy: .public)")
            throw IntentError.notSignedIn
        }
        guard let token, !token.isEmpty else {
            BenitoLog.api.notice("intent: not signed in")
            throw IntentError.notSignedIn
        }
        // Fresh client id (not the app's) so the app's sync socket receives the change broadcast.
        return APIClient(baseURL: url, token: token)
    }

    private static func cachedChild() -> (id: UUID, name: String)? {
        ShortcutChildStore.load().first.map { ($0.id, $0.name) }
    }

    static func clearCachedChild() {
        ShortcutChildStore.clear()
    }

    /// Same pick as the app: the family's first child.
    private static func fetchChild(_ client: any BenitoService) async throws -> (id: UUID, name: String) {
        let me = try await perform { try await client.me() }
        guard let child = me.children.first else { throw IntentError.noChild }
        let name = displayName(child.name) ?? "Baby"
        ShortcutChildStore.save([ShortcutChild(id: child.id, name: name)])
        BenitoLog.api.notice("intent resolved child \(child.id.uuidString, privacy: .public)")
        return (child.id, name)
    }

    private static func displayName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Reads

    func state() async throws -> BabyStateDTO {
        try await Self.perform { try await client.state(childId: childId) }
    }

    /// The active timer, or `IntentError.noActiveTimer`.
    func requireActiveTimer() throws -> TimerDTO {
        guard let timer = activeTimer else { throw IntentError.noActiveTimer(childName: childName) }
        return timer
    }

    // MARK: - Mutations

    /// Starts a `feed_breast` (side `L`/`R`) or `sleep` timer. Refuses when one is already active
    /// so a second voice command can't leave two timers running.
    @discardableResult
    func startTimer(kind: String, side: String?) async throws -> TimerDTO {
        if let active = activeTimer {
            throw IntentError.timerAlreadyRunning(childName: childName, timerLabel: Self.timerLabel(kind: active.kind))
        }
        BenitoLog.api.notice("intent startTimer \(kind, privacy: .public) side=\(side ?? "-", privacy: .public)")
        let timer = try await Self.perform { try await client.startTimer(childId: childId, kind: kind, side: side) }
        await syncLiveActivity()
        return timer
    }

    /// Live Activity Feed/Sleep buttons: a timer started elsewhere (e.g. by the other parent)
    /// means the buttons were stale, so just refresh the activity instead of failing.
    func startTimerFromButton(kind: String, side: String?) async throws {
        guard activeTimer == nil else {
            BenitoLog.api.notice("intent start ignored: a timer is already active")
            await syncLiveActivity()
            return
        }
        try await startTimer(kind: kind, side: side)
    }

    @discardableResult
    func pause(timerId: UUID) async throws -> TimerDTO {
        BenitoLog.api.notice("intent pauseTimer \(timerId.uuidString, privacy: .public)")
        let timer = try await Self.perform { try await client.pauseTimer(id: timerId) }
        await syncLiveActivity()
        return timer
    }

    @discardableResult
    func resume(timerId: UUID) async throws -> TimerDTO {
        BenitoLog.api.notice("intent resumeTimer \(timerId.uuidString, privacy: .public)")
        let timer = try await Self.perform { try await client.resumeTimer(id: timerId) }
        await syncLiveActivity()
        return timer
    }

    @discardableResult
    func stop(timerId: UUID) async throws -> TimerDTO {
        BenitoLog.api.notice("intent stopTimer \(timerId.uuidString, privacy: .public)")
        let timer = try await Self.perform { try await client.stopTimer(id: timerId) }
        await syncLiveActivity()
        return timer
    }

    @discardableResult
    func createEvent(
        type: String,
        subtype: String? = nil,
        amountValue: Double? = nil,
        amountUnit: String? = nil,
        side: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) async throws -> EventDTO {
        BenitoLog.api.notice("intent createEvent \(type, privacy: .public)")
        let request = CreateEventRequestDTO(
            childId: childId,
            type: type,
            subtype: subtype,
            startedAt: startedAt,
            endedAt: endedAt,
            amountValue: amountValue,
            amountUnit: amountUnit,
            side: side
        )
        let event = try await Self.perform { try await client.createEvent(request) }
        await syncLiveActivity()
        return event
    }

    /// Re-reads `/state` and pushes it to the Live Activity. Best effort: after a mutation that
    /// already succeeded, a failed refresh only leaves the activity behind until the app syncs.
    func syncLiveActivity() async {
        if BenitoMode.current() == .onDevice {
            NotificationCenter.default.post(name: .benitoLocalStoreDidChange, object: nil)
        }
        #if canImport(ActivityKit)
        do {
            let fresh = try await client.state(childId: childId)
            await LiveActivitySync.apply(BenitoActivityAttributes.ContentState.from(state: fresh))
        } catch {
            BenitoLog.api.error("intent state refresh failed: \(String(describing: error), privacy: .public)")
        }
        #endif
    }

    // MARK: - Presentation helpers

    /// Spoken name for a timer kind: "feed" / "nap" / "walk" / "car ride" / "crying".
    static func timerLabel(kind: String) -> String {
        if let activity = ActivityKind(timerKind: kind) { return activity.noun }
        return kind.lowercased().contains("sleep") ? "nap" : "feed"
    }

    /// "14 minutes", "1 hour, 5 minutes", or "less than a minute".
    static func spokenDuration(_ interval: TimeInterval) -> String {
        guard interval >= 60 else { return "less than a minute" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .full
        return formatter.string(from: interval) ?? "\(Int(interval / 60)) minutes"
    }

    // MARK: - Error mapping

    private static func perform<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw mapped(error)
        }
    }

    private static func mapped(_ error: Error) -> Error {
        switch error {
        case is IntentError, is CancellationError:
            return error
        case APIClientError.httpStatus(401, _):
            return IntentError.notSignedIn
        case APIClientError.httpStatus(409, _):
            return IntentError.timerChanged
        case APIClientError.httpStatus(let status, _) where status < 0:
            return IntentError.network
        case APIClientError.httpStatus(let status, _):
            return IntentError.server(status: status)
        case APIClientError.transport:
            return IntentError.network
        case APIClientError.invalidURL:
            return IntentError.noServerURL
        case APIClientError.decoding:
            return IntentError.unexpectedResponse
        default:
            return error
        }
    }
}
