import SwiftUI
import UIKit
import BenitoKit

/// Open nursing session while a breast timer is running.
/// Side switches already persist a segment; frozen totals keep the open clock
/// coherent when the start time moves.
struct NursingLiveSession: Equatable {
    var sessionStart: Date
    var frozenLeft: TimeInterval
    var frozenRight: TimeInterval
    /// Completed segment event ids, oldest first, keyed by `L` / `R`.
    var segmentEvents: [String: [UUID]]
    /// Timer whose live elapsed was folded into frozen and must not be added again.
    var suppressTimerId: UUID?
}

@MainActor
@Observable
final class AppModel {
    var serverURLString: String
    var name = ""
    var email = ""
    var password = ""
    var status = "Not signed in"
    var inviteCode = ""
    var familyName = "Our family"
    var childName = "Baby"
    var childId: UUID?
    var babyState: BabyStateDTO? {
        didSet { pushLiveActivity() }
    }
    var timeline: [EventDTO] = []
    var lastExportSummary = ""
    /// Temp file from the latest Export JSON/CSV tap; Settings presents a share sheet.
    var exportShareItem: ExportShareItem?
    var syncConnected = false
    /// Address `api` and sync use now: the saved Server URL, or a verified fallback to it.
    var route: ServerRoute?
    /// While on a fallback, checks the saved Server URL again until it answers.
    @ObservationIgnored var primaryWatch: Task<Void, Never>?
    @ObservationIgnored var isRouting = false
    var storeLabel = "store: ?"
    var outboxPending = 0
    var isSignedIn = false
    var signedInEmail = ""
    /// Display name from `/me`; shown to the inviting partner during proximity pairing.
    var signedInName = ""
    /// `/sync` only accepts members of a family; don't open it before create/join.
    var hasFamily = false
    /// This account's role in the family (`nil` on servers before device sign-in).
    var role: FamilyRole?
    /// Caregiver access end, when the inviting parent set one.
    var accessExpiresAt: Date?
    /// Account › Sharing: everyone in the family, and invites not yet used.
    var members: [FamilyMemberDTO] = []
    var pendingInvites: [FamilyInviteDTO] = []
    /// An invite link (https or `benito://join`) opened from Messages / AirDrop, waiting for the join sheet.
    var pendingJoinLink: FamilyInviteLink?
    /// False until the launch-time session restore finishes (avoids flashing onboarding).
    var didResolveLaunch = false
    /// This phone's Secure Enclave key: passwordless sign-in and automatic re-auth.
    @ObservationIgnored let deviceIdentity: any DeviceIdentity = KeychainDeviceIdentity()
    /// Server daily summary for the device-local calendar day (D7: from/to local midnight).
    var dailySummary: DailySummaryDTO?
    /// Open nursing session (nil when no breast timer is in progress).
    var nursingLive: NursingLiveSession?
    /// Side switches stop the current timer; keep session books across that stop.
    var nursingPreserveSession = false
    /// Proximity partner pairing over SharePlay; lives as long as the model.
    @ObservationIgnored private(set) lazy var pairing = PairingCoordinator(model: self)

    var api: APIClient?
    var store: any BenitoStore
    /// Data lives only on this phone (no server, no account). Absent for server families.
    var isOnDevice = BenitoMode.current() == .onDevice
    /// Answers the app's data calls in on-device mode, by the server's rules.
    @ObservationIgnored private(set) lazy var localService = LocalBenitoService(store: store)
    /// Progress of a move from this phone to a family server (Account › Connect to a server).
    var serverMove: ServerMoveProgress?
    private var sync: SyncClient?
    let clientId: String
    /// Last `error` envelope from the server; explains the close that follows it.
    private var lastSyncServerError: String?
    let tokenStore: any SessionTokenStore
    /// Bumped when a newer `/state` fetch starts (or a local stop invalidates in-flight ones).
    private var stateFetchGeneration = 0
    /// Serializes `/sync` envelopes so an older timer.upsert cannot land after timer.stop.
    private var syncTail: Task<Void, Never>?

    init(serverURLString: String, tokenStore: any SessionTokenStore = KeychainSessionTokenStore()) {
        self.serverURLString = serverURLString
        self.tokenStore = tokenStore
        if let existing = UserDefaults.standard.string(forKey: "benito.clientId") {
            self.clientId = existing
        } else {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: "benito.clientId")
            self.clientId = id
        }
        let created = LocalStoreFactory.shared
        self.store = created
        #if canImport(GRDB)
        self.storeLabel = (created is GRDBStore) ? "store: GRDB" : "store: memory"
        #else
        self.storeLabel = "store: memory"
        #endif
        Task {
            try? await store.setPreference("server_url", value: serverURLString)
            await refreshOutboxCount()
            await restoreSession()
            didResolveLaunch = true
        }
        observeLocalStoreChanges()
    }

    /// Current Server URL if it is an absolute URL with scheme + host.
    var serverBaseURL: URL? {
        guard let url = URL(string: serverURLString), url.scheme != nil, url.host != nil else {
            return nil
        }
        return url
    }

    /// Call when the user commits a new Server URL — drops HTTP session + WS so the new host is used.
    func applyServerURL(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Redundant commit for the server we're already talking to: keep the session.
        if trimmed == serverURLString, api != nil { return }
        BenitoLog.ui.notice("serverURL committed \(trimmed, privacy: .public)")
        serverURLString = trimmed
        sync?.disconnect()
        sync = nil
        syncConnected = false
        api = nil
        forgetRoute()
        try? await store.setPreference("server_url", value: trimmed)
        isSignedIn = false
        signedInEmail = ""
        status = "Server URL updated — sign in again"
        // Tokens are stored per server origin; pick up the new server's session if we have one.
        await restoreSession()
    }

    /// Rebuilds the API client from the Keychain token saved for the current server origin,
    /// then refreshes family/state, catches up on missed events and reconnects sync.
    func restoreSession() async {
        if isOnDevice {
            await restoreOnDevice()
            return
        }
        guard let url = serverBaseURL else {
            BenitoLog.ui.notice("restore skipped: no valid server URL")
            return
        }
        let saved: String?
        do {
            saved = try tokenStore.token(for: url)
        } catch {
            BenitoLog.ui.error("session token read failed: \(String(describing: error), privacy: .public)")
            status = "Session restore failed"
            return
        }
        guard let saved else {
            if await resumeWithDeviceKey() {
                await restoreSession()
                return
            }
            BenitoLog.ui.notice("restore skipped: no saved session for \(SessionTokenStoreKey.account(for: url), privacy: .public)")
            return
        }
        BenitoLog.ui.notice("restoring session for \(SessionTokenStoreKey.account(for: url), privacy: .public)")
        let created = APIClient(baseURL: url, token: saved, clientId: clientId)
        api = created
        wireStateRefetcher(api: created)
        isSignedIn = true
        status = "Restoring session…"
        // Saved address down (e.g. Tailscale broken)? Use the same server's home-network address.
        await updateRoute()
        guard api === created else { return }
        await refreshMe()
        // Server URL changed or session rejected while /me was in flight.
        guard api === created else { return }
        connectSync()
        await flushOutbox()
        // refreshMe / flushOutbox may have set a richer status; never leave "Restoring…" stuck.
        if status == "Restoring session…" {
            if isSignedIn {
                status = signedInEmail.isEmpty ? "Signed in" : "Signed in as \(signedInEmail)"
            } else {
                status = "Not signed in"
            }
        }
    }

    /// Saves the session token for this client's server origin and flips to signed-in.
    func persistSession(_ res: AuthResponseDTO, client: APIClient) async {
        let baseURL = await client.baseURL
        do {
            try tokenStore.setToken(res.token, for: baseURL)
        } catch {
            BenitoLog.ui.error("session token save failed: \(String(describing: error), privacy: .public)")
        }
        isSignedIn = true
        signedInEmail = res.user.email
        signedInName = res.user.name
        password = ""
    }

    func deleteStoredToken() {
        guard let url = serverBaseURL else { return }
        do {
            try tokenStore.deleteToken(for: url)
        } catch {
            BenitoLog.ui.error("session token delete failed: \(String(describing: error), privacy: .public)")
        }
    }

    func tearDownSession() {
        sync?.disconnect()
        sync = nil
        syncConnected = false
        forgetRoute()
        LiveActivityController.shared.setPushTokenHandler(nil)
        api = nil
        isSignedIn = false
        signedInEmail = ""
        signedInName = ""
        hasFamily = false
        dailySummary = nil
        role = nil
        accessExpiresAt = nil
        members = []
        pendingInvites = []
    }

    /// Server has no logout endpoint: forget the token locally. Local DB stays as the family's cache.
    func signOut() {
        BenitoLog.ui.notice("signOut")
        let apiForTokens = api
        LiveActivityController.shared.setPushTokenHandler(nil)
        Task {
            try? await apiForTokens?.deleteLiveActivityTokens()
        }
        deleteStoredToken()
        forgetDeviceId()
        tearDownSession()
        childId = nil
        babyState = nil
        timeline = []
        dailySummary = nil
        inviteCode = ""
        status = "Signed out"
    }

    /// On HTTP 401 the stored session is invalid/expired: drop it and return to the sign-in form.
    func handleUnauthorized(_ error: Error) -> Bool {
        guard case .httpStatus(401, _)? = error as? APIClientError else { return false }
        BenitoLog.ui.notice("session rejected (401)")
        deleteStoredToken()
        tearDownSession()
        status = "Session expired — sign in again"
        // Sessions expire; this phone's key does not. Get a fresh session without a prompt.
        if storedDeviceId() != nil {
            status = "Reconnecting…"
            Task {
                if await resumeWithDeviceKey() {
                    await restoreSession()
                } else if status == "Reconnecting…" {
                    status = "Session expired — sign in again"
                }
            }
        }
        return true
    }

    func client() throws -> APIClient {
        if let api { return api }
        // On-device families have no server; never build a tokenless client that would sync.
        if isOnDevice { throw APIClientError.invalidURL }
        guard let url = serverBaseURL else {
            throw APIClientError.invalidURL
        }
        let created = APIClient(baseURL: url, clientId: clientId)
        api = created
        wireStateRefetcher(api: created)
        return created
    }

    func wireStateRefetcher(api: APIClient) {
        let refetcher = APIStateRefetcher(api: api)
        #if canImport(GRDB)
        if let grdb = store as? GRDBStore {
            grdb.stateRefetcher = refetcher
        } else if let mem = store as? InMemoryStore {
            Task { await mem.setRefetcher(refetcher) }
        }
        #else
        if let mem = store as? InMemoryStore {
            Task { await mem.setRefetcher(refetcher) }
        }
        #endif
        // Phase 1: sandbox ActivityKit update tokens → server (APNs send stays off until .p8 env).
        LiveActivityController.shared.setPushTokenHandler { [weak self] token, activityId in
            guard let self, let api = self.api else { return }
            Task {
                do {
                    try await api.registerLiveActivityToken(
                        token: token,
                        apnsEnv: "sandbox",
                        activityId: activityId
                    )
                    BenitoLog.ui.notice("liveActivity token registered activity=\(activityId, privacy: .public)")
                } catch {
                    BenitoLog.ui.error(
                        "liveActivity token register failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
    }

    func register() async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEmail.isEmpty {
            status = "Register failed: email required"
            return
        }
        if password.count < 8 {
            status = "Register failed: password min 8 chars"
            return
        }
        do {
            BenitoLog.ui.notice("register")
            let c = try client()
            let res = try await c.register(
                name: name.isEmpty ? "Parent" : name,
                email: trimmedEmail,
                password: password
            )
            await persistSession(res, client: c)
            status = "Signed in as \(res.user.email)"
            await refreshMe()
            connectSync()
            await flushOutbox()
        } catch {
            status = "Register failed: \(error.localizedDescription)"
        }
    }

    func login() async {
        do {
            BenitoLog.ui.notice("login")
            let c = try client()
            let res = try await c.login(email: email, password: password)
            await persistSession(res, client: c)
            status = "Signed in as \(res.user.email)"
            await refreshMe()
            connectSync()
            await flushOutbox()
        } catch {
            status = "Login failed: \(error.localizedDescription)"
        }
    }

    func createFamily() async {
        do {
            let c = try client()
            let res = try await c.createFamily(name: familyName, childName: childName)
            childId = res.child.id
            hasFamily = true
            inviteCode = res.inviteCode
            try await store.upsertChild(res.child)
            status = "Family created. Invite: \(res.inviteCode)"
            await refreshState()
            connectSync()
        } catch {
            status = "Create family failed: \(error)"
        }
    }

    func joinFamily() async {
        do {
            let c = try client()
            _ = try await c.joinFamily(inviteCode: inviteCode)
            status = "Joined family"
            await refreshMe()
            connectSync()
        } catch {
            status = "Join failed: \(error)"
        }
    }

    /// Mints a single-use pairing token to hand to a partner over SharePlay.
    func createPairingToken() async throws -> PairingTokenDTO {
        do {
            return try await client().createPairingToken()
        } catch {
            _ = handleUnauthorized(error)
            throw error
        }
    }

    /// Redeems a partner's pairing token, then loads the family like `joinFamily`.
    func pair(token: String) async throws {
        do {
            _ = try await client().pair(token: token)
        } catch {
            _ = handleUnauthorized(error)
            throw error
        }
        status = "Joined family"
        await refreshMe()
        connectSync()
    }

    /// Troubleshooting / switching families: leave on the server, stop syncing, clear family state.
    func leaveFamily() async {
        do {
            BenitoLog.ui.notice("leaveFamily")
            try await client().leaveFamily()
        } catch {
            if handleUnauthorized(error) { return }
            BenitoLog.ui.error("leaveFamily failed: \(String(describing: error), privacy: .public)")
            status = "Leave family failed: \(Self.message(for: error))"
            return
        }
        sync?.disconnect()
        sync = nil
        syncConnected = false
        hasFamily = false
        inviteCode = ""
        childId = nil
        babyState = nil
        timeline = []
        dailySummary = nil
        nursingLive = nil
        try? await store.replaceChildren([])
        status = "Left family"
    }

    /// Deletes the account on the server, then removes this install's traces of it: session,
    /// device id and signing key, the cached family. The app returns to first-run onboarding.
    func deleteAccount() async {
        guard !isOnDevice else { return }
        do {
            BenitoLog.ui.notice("deleteAccount")
            try await client().deleteAccount()
        } catch {
            if case .httpStatus(let code, _)? = error as? APIClientError, code == 404 || code == 405 {
                BenitoLog.ui.notice("deleteAccount unsupported by server (\(code, privacy: .public))")
                status = "This server is too old to delete accounts from the app. Update Benito on the server, then try again."
                return
            }
            if handleUnauthorized(error) { return }
            BenitoLog.ui.error("deleteAccount failed: \(String(describing: error), privacy: .public)")
            status = "Delete account failed: \(Self.message(for: error))"
            return
        }
        // The same account is reachable at every address of this server (LAN, Tailscale).
        for url in knownEndpoints {
            try? tokenStore.deleteToken(for: url)
            storeDeviceId(nil, for: url)
        }
        deleteStoredToken()
        forgetDeviceId()
        do {
            try (deviceIdentity as? KeychainDeviceIdentity)?.reset()
        } catch {
            BenitoLog.ui.error("device key reset failed: \(String(describing: error), privacy: .public)")
        }
        tearDownSession()
        clearFamilyState()
        do {
            try await store.eraseAll()
        } catch {
            BenitoLog.ui.error("local store erase failed: \(String(describing: error), privacy: .public)")
        }
        outboxPending = 0
        status = "Account deleted"
    }

    /// Forgets the family held in memory and the child cached for Siri / Live Activity buttons.
    /// With `isSignedIn` false this leaves the app at first-run onboarding.
    func clearFamilyState() {
        inviteCode = ""
        childId = nil
        babyState = nil
        timeline = []
        dailySummary = nil
        nursingLive = nil
        nursingPreserveSession = false
        familyName = "Our family"
        childName = "Baby"
        name = ""
        email = ""
        password = ""
        lastExportSummary = ""
        exportShareItem = nil
        UserDefaults.standard.removeObject(forKey: BenitoIntentBackend.childIdKey)
        UserDefaults.standard.removeObject(forKey: BenitoIntentBackend.childNameKey)
    }

    func refreshMe() async {
        do {
            let c = try service()
            let me = try await c.me()
            signedInEmail = me.user.email
            signedInName = me.user.name
            try await store.replaceChildren(me.children)
            if let first = me.children.first {
                childId = first.id
                childName = first.name
            }
            hasFamily = me.family != nil
            role = me.role
            accessExpiresAt = me.accessExpiresAt
            if let family = me.family {
                familyName = family.name
                inviteCode = family.inviteCode
            }
            await ensureDeviceKey(serverSupportsKeys: me.hasDeviceKey != nil)
            await refreshState()
            await catchUp()
        } catch {
            if handleUnauthorized(error) { return }
            BenitoLog.ui.error("me failed: \(String(describing: error), privacy: .public)")
            status = "Me failed: \(error)"
            await loadLocalGlance()
        }
    }

    func refreshState() async {
        guard let childId else { return }
        stateFetchGeneration += 1
        let generation = stateFetchGeneration
        do {
            let c = try service()
            let state = try await c.state(childId: childId)
            guard generation == stateFetchGeneration else {
                BenitoLog.ui.notice("state refresh discarded (stale)")
                return
            }
            try await store.applyBabyState(state)
            guard generation == stateFetchGeneration else {
                BenitoLog.ui.notice("state refresh discarded (stale)")
                return
            }
            babyState = state
            timeline = try await store.events(childId: childId, limit: 40)
            await flushOutbox()
            await refreshOutboxCount()
            await refreshDailySummary()
        } catch {
            guard generation == stateFetchGeneration else { return }
            if handleUnauthorized(error) { return }
            // Couldn't reach the saved address (not a 401/403): try the same server's other route once.
            if ServerRoute.isUnreachable(error), await updateRoute() {
                connectSync()
                await refreshState()
                return
            }
            BenitoLog.ui.error("state failed: \(String(describing: error), privacy: .public)")
            status = "State offline — using local DB"
            await loadLocalGlance()
        }
    }

    /// Pulls every event changed since the stored cursor (incl. deletes) so history includes
    /// what a partner logged while this app was backgrounded or offline.
    func catchUp() async {
        guard let childId, let api else { return }
        do {
            let applied = try await CatchUpSync(store: store, fetcher: api).run(childId: childId)
            if applied > 0 {
                BenitoLog.ui.notice("catch-up applied \(applied, privacy: .public) event(s)")
            }
            timeline = try await store.events(childId: childId, limit: 40)
        } catch {
            if handleUnauthorized(error) { return }
            BenitoLog.ui.error("catch-up failed: \(String(describing: error), privacy: .public)")
            if Self.isTransport(error) { return }
            status = "Catch-up failed: \(error)"
        }
    }

    /// Non-deleted events for the current child overlapping [from, to), from the local store.
    /// Catch-up keeps the store complete, so calendar views can read ranges offline.
    func localEvents(from: Date, to: Date) async -> [EventDTO] {
        guard let childId else { return [] }
        do {
            return try await store.events(childId: childId, from: from, to: to)
        } catch {
            BenitoLog.store.error("range query failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// scenePhase → .active: the socket was likely dropped while suspended; resync everything.
    func appBecameActive() async {
        guard isSignedIn else { return }
        BenitoLog.ui.notice("app active: resync (sync connected=\(self.syncConnected, privacy: .public))")
        if await updateRoute() || sync == nil || sync?.isConnected != true {
            connectSync()
        }
        await refreshState()
        await catchUp()
        await flushOutbox()
        await LiveActivityController.shared.flush()
    }

    private func loadLocalGlance() async {
        guard let childId else { return }
        babyState = try? await store.localBabyState(childId: childId)
        timeline = (try? await store.events(childId: childId, limit: 40)) ?? []
        await refreshOutboxCount()
    }

    /// `at` nil = now; a past date backdates the entry.
    func logDiaper(subtype: String, at: Date? = nil) async {
        await log(type: EventType.diaper.rawValue, subtype: subtype, startedAt: at)
    }

    func logBottle(ounces: Double, milk: BottleMilk, at: Date? = nil) async {
        await log(
            type: EventType.feedBottle.rawValue,
            subtype: milk.rawValue,
            amountValue: ounces,
            amountUnit: "oz",
            startedAt: at
        )
    }

    /// Pump session: `ended_at = start + duration` when a duration is given; ounces optional.
    func logPump(side: PumpSide, ounces: Double?, durationMinutes: Int?, at: Date? = nil) async {
        let start = at ?? Date()
        let end = durationMinutes.flatMap { $0 > 0 ? start.addingTimeInterval(TimeInterval($0 * 60)) : nil }
        await log(
            type: EventType.pump.rawValue,
            side: side.rawValue,
            amountValue: ounces,
            amountUnit: ounces == nil ? nil : "oz",
            startedAt: start,
            endedAt: end
        )
    }

    func logManualSleep(start: Date, end: Date) async {
        await log(type: EventType.sleep.rawValue, startedAt: start, endedAt: end)
    }

    /// Backfill a walk / car ride / crying spell that wasn't timed.
    func logActivity(_ kind: ActivityKind, start: Date, end: Date, note: String? = nil) async {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        await log(
            type: EventType.activity.rawValue,
            subtype: kind.rawValue,
            notes: trimmed?.isEmpty == false ? trimmed : nil,
            startedAt: start,
            endedAt: end
        )
    }

    /// Medicine dose: `subtype` is the display name; amount/unit optional (ml, drops, mg, IU).
    func logMedicine(name: String, dose: Double?, unit: String?, at: Date? = nil) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "Medicine name required"
            return
        }
        await log(
            type: EventType.medicine.rawValue,
            subtype: trimmed,
            amountValue: dose,
            amountUnit: dose == nil ? nil : unit,
            startedAt: at
        )
    }

    /// Last logged medicine name (prefill); empty before the first dose.
    var lastMedicineName: String {
        babyState?.lastMedicine?.subtype?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Most recent bottle amount in ounces (prefill for the bottle sheet); 3 oz before any bottle is logged.
    var lastBottleOunces: Double {
        guard let bottle = lastBottle, let value = bottle.amountValue, value > 0 else { return 3.0 }
        return bottle.amountUnit?.lowercased() == "ml" ? value / 29.5735 : value
    }

    /// Most recent bottle milk (prefill for the bottle sheet); formula before any bottle is logged.
    var lastBottleMilk: BottleMilk {
        lastBottle?.subtype.flatMap(BottleMilk.init(rawValue:)) ?? .formula
    }

    private var lastBottle: EventDTO? {
        timeline
            .filter { $0.type == EventType.feedBottle.rawValue && $0.deletedAt == nil }
            .max { $0.startedAt < $1.startedAt }
    }

    /// PATCH /events/{id}. Offline: queue the PATCH and show the edit locally until it replays.
    func updateEvent(_ event: EventDTO, changes: UpdateEventRequestDTO) async -> Bool {
        BenitoLog.ui.notice("updateEvent \(event.type, privacy: .public)")
        do {
            let c = try service()
            let updated = try await c.updateEvent(id: event.id, changes)
            try await store.upsertEvent(updated)
            status = "Updated \(updated.type)"
            await refreshState()
            return true
        } catch let error where Self.isTransport(error) {
            let body = try? BenitoJSON.encoder.encode(changes)
            _ = try? await store.enqueueOutbox(method: "PATCH", path: "/events/\(event.id.uuidString)", body: body)
            var local = event
            if let startedAt = changes.startedAt { local.startedAt = startedAt }
            if let endedAt = changes.endedAt { local.endedAt = endedAt }
            if let subtype = changes.subtype { local.subtype = subtype }
            if let side = changes.side { local.side = side }
            if let amountValue = changes.amountValue { local.amountValue = amountValue }
            if let amountUnit = changes.amountUnit { local.amountUnit = amountUnit }
            if let notes = changes.notes { local.notes = notes }
            try? await store.upsertEvent(local)
            status = "Edit queued (offline)"
            await loadLocalGlance()
            return true
        } catch {
            if handleUnauthorized(error) { return false }
            BenitoLog.ui.error("updateEvent failed: \(String(describing: error), privacy: .public)")
            status = "Edit failed: \(Self.message(for: error))"
            return false
        }
    }

    /// DELETE /events/{id} (server soft-deletes). Offline: queue the DELETE and hide it locally.
    func deleteEvent(_ event: EventDTO) async -> Bool {
        BenitoLog.ui.notice("deleteEvent \(event.type, privacy: .public)")
        do {
            let c = try service()
            try await c.deleteEvent(id: event.id)
            try await store.softDeleteEvent(id: event.id)
            status = "Deleted \(event.type)"
            await refreshState()
            return true
        } catch let error where Self.isTransport(error) {
            _ = try? await store.enqueueOutbox(method: "DELETE", path: "/events/\(event.id.uuidString)", body: nil)
            try? await store.softDeleteEvent(id: event.id)
            status = "Delete queued (offline)"
            await loadLocalGlance()
            return true
        } catch {
            if handleUnauthorized(error) { return false }
            BenitoLog.ui.error("deleteEvent failed: \(String(describing: error), privacy: .public)")
            status = "Delete failed: \(Self.message(for: error))"
            return false
        }
    }

    /// Moves the running/paused timer's start ("forgot to start it"). Online only: a queued
    /// adjustment could land after the timer was stopped.
    func adjustActiveTimerStart(to date: Date) async -> Bool {
        guard let timer = babyState?.activeTimer, timer.isActive else {
            status = "No active timer"
            return false
        }
        BenitoLog.ui.notice("adjustTimerStart \(timer.kind, privacy: .public)")
        do {
            let c = try service()
            let adjusted = try await c.adjustTimerStart(id: timer.id, startedAt: date)
            await applyLocalTimer(adjusted)
            status = "Timer start updated"
            await refreshState()
            return true
        } catch let error where Self.isTransport(error) {
            status = "Can't adjust the timer while offline"
            return false
        } catch {
            if handleUnauthorized(error) { return false }
            BenitoLog.ui.error("adjustTimerStart failed: \(String(describing: error), privacy: .public)")
            status = "Adjust timer failed: \(Self.message(for: error))"
            return false
        }
    }

    /// Start-time edit for a running timer. Nursing passes a side scope so the
    /// delta lands on Left, Right, or both; sleep (and any other live timer)
    /// moves `startedAt` to `date`. Phone `Date()` is the clock (`at` on PATCH).
    func adjustRunningActivityStart(to date: Date, nursingScope: NursingSideScope?) async -> Bool {
        guard let timer = babyState?.activeTimer, timer.isActive else {
            status = "No active timer"
            return false
        }
        if isBreastTimer(timer), let nursingScope {
            return await adjustNursingSessionStart(to: date, scope: nursingScope, timer: timer)
        }
        return await adjustActiveTimerStart(to: date)
    }

    func ensureNursingSession(for timer: TimerDTO) {
        guard timer.isActive, isBreastTimer(timer) else { return }
        if var books = nursingLive {
            if let suppressed = books.suppressTimerId, suppressed != timer.id {
                books.suppressTimerId = nil
                nursingLive = books
            }
            return
        }
        nursingLive = NursingLiveSession(
            sessionStart: timer.startedAt,
            frozenLeft: 0,
            frozenRight: 0,
            segmentEvents: [:],
            suppressTimerId: nil
        )
    }

    /// Freeze the active side's elapsed before a side switch stops that timer.
    func foldActiveNursingSide(_ timer: TimerDTO) {
        ensureNursingSession(for: timer)
        guard var books = nursingLive else { return }
        if books.suppressTimerId == timer.id { return }
        let elapsed = max(0, timer.elapsed(at: Date()))
        if timer.side?.uppercased() == "R" {
            books.frozenRight += elapsed
        } else {
            books.frozenLeft += elapsed
        }
        books.suppressTimerId = timer.id
        nursingLive = books
    }

    func captureNewNursingSegment(side: String, previousIDs: Set<UUID>) {
        guard var books = nursingLive else { return }
        let side = side.uppercased()
        guard let created = timeline.first(where: { event in
            !previousIDs.contains(event.id)
                && event.deletedAt == nil
                && event.type == EventType.feedBreast.rawValue
                && event.side?.uppercased() == side
        }) else { return }
        var ids = books.segmentEvents[side] ?? []
        if !ids.contains(created.id) { ids.append(created.id) }
        books.segmentEvents[side] = ids
        nursingLive = books
    }

    func nursingStartBounds(now: Date = Date()) -> ClosedRange<Date> {
        let timer = babyState?.activeTimer
        let start = nursingLive?.sessionStart ?? timer?.startedAt ?? now
        let live: TimeInterval = {
            guard let timer, timer.isActive, nursingLive?.suppressTimerId != timer.id else { return 0 }
            return max(0, timer.elapsed(at: now))
        }()
        let total = (nursingLive?.frozenLeft ?? 0) + (nursingLive?.frozenRight ?? 0) + live
        return Self.closedDateRange(
            lower: now.addingTimeInterval(-24 * 60 * 60),
            upper: min(start.addingTimeInterval(max(0, total)), timer?.pausedAt ?? now, now),
            mustInclude: start
        )
    }

    func timerStartBounds(for timer: TimerDTO, now: Date = Date()) -> ClosedRange<Date> {
        let upper = min(timer.pausedAt ?? now, now)
        return Self.closedDateRange(
            lower: now.addingTimeInterval(-24 * 60 * 60),
            upper: upper,
            mustInclude: timer.startedAt
        )
    }

    private static func closedDateRange(lower: Date, upper: Date, mustInclude: Date) -> ClosedRange<Date> {
        let lo = min(lower, upper, mustInclude)
        let hi = max(lower, upper, mustInclude)
        return lo...hi
    }

    private func isBreastTimer(_ timer: TimerDTO) -> Bool {
        let kind = timer.kind.lowercased()
        return kind.contains("breast") || kind == "nursing"
    }

    private func adjustNursingSessionStart(to date: Date, scope: NursingSideScope, timer: TimerDTO) async -> Bool {
        ensureNursingSession(for: timer)
        let books = nursingLive ?? NursingLiveSession(
            sessionStart: timer.startedAt,
            frozenLeft: 0,
            frozenRight: 0,
            segmentEvents: [:],
            suppressTimerId: nil
        )
        let live: TimeInterval = books.suppressTimerId == timer.id ? 0 : max(0, timer.elapsed(at: Date()))
        let active = timer.side?.uppercased() == "R" ? "R" : "L"
        let plan = NursingStartAdjustment.plan(
            sessionStart: books.sessionStart,
            delta: books.sessionStart.timeIntervalSince(date),
            scope: scope,
            books: NursingDurationBooks(
                frozenLeft: books.frozenLeft,
                frozenRight: books.frozenRight,
                live: live,
                activeSide: active
            )
        )
        if abs(plan.appliedDelta) < 0.5 {
            status = "Timer start updated"
            return true
        }

        if abs(plan.liveDelta) >= 0.5 {
            var newTimerStart = timer.startedAt.addingTimeInterval(-plan.liveDelta)
            let ceiling = min(timer.pausedAt ?? Date(), Date())
            let floor = Date().addingTimeInterval(-24 * 60 * 60)
            if newTimerStart > ceiling { newTimerStart = ceiling }
            if newTimerStart < floor { newTimerStart = floor }
            let ok = await adjustActiveTimerStart(to: newTimerStart)
            if !ok { return false }
        }

        var session = books
        var eventsOK = true
        if abs(plan.frozenLeftDelta) >= 0.5 {
            let shifted = await shiftNursingFrozen(
                side: "L",
                delta: plan.frozenLeftDelta,
                oldSessionStart: books.sessionStart,
                session: session
            )
            session = shifted.session
            eventsOK = eventsOK && shifted.ok
        }
        if abs(plan.frozenRightDelta) >= 0.5 {
            let shifted = await shiftNursingFrozen(
                side: "R",
                delta: plan.frozenRightDelta,
                oldSessionStart: books.sessionStart,
                session: session
            )
            session = shifted.session
            eventsOK = eventsOK && shifted.ok
        }
        if !eventsOK && abs(plan.liveDelta) < 0.5 {
            return false
        }
        session.sessionStart = plan.newSessionStart
        session.frozenLeft = plan.frozenLeft
        session.frozenRight = plan.frozenRight
        nursingLive = session
        if !eventsOK {
            status = "Start time updated — a side segment didn't sync"
        } else {
            status = "Timer start updated"
        }
        return true
    }

    private func shiftNursingFrozen(
        side: String,
        delta: TimeInterval,
        oldSessionStart: Date,
        session: NursingLiveSession
    ) async -> (session: NursingLiveSession, ok: Bool) {
        var session = session
        guard abs(delta) >= 0.5 else { return (session, true) }
        var ids = session.segmentEvents[side] ?? []
        if ids.isEmpty {
            ids = discoveredNursingSegments(side: side, notBefore: oldSessionStart)
            if !ids.isEmpty { session.segmentEvents[side] = ids }
        }
        if ids.isEmpty {
            guard delta > 0 else { return (session, true) }
            let end = oldSessionStart
            let start = end.addingTimeInterval(-delta)
            if let id = await insertNursingPrefix(side: side, start: start, end: end) {
                session.segmentEvents[side] = [id]
                return (session, true)
            }
            return (session, false)
        }

        var remaining = delta
        for id in ids.reversed() {
            if abs(remaining) < 0.5 { break }
            guard let event = timeline.first(where: { $0.id == id }),
                  event.deletedAt == nil,
                  let end = event.endedAt
            else { continue }
            var portion = remaining
            if portion < 0 {
                let maxShrink = max(0, end.timeIntervalSince(event.startedAt) - 1)
                if -portion > maxShrink { portion = -maxShrink }
            }
            if abs(portion) < 0.5 { continue }
            let newStart = event.startedAt.addingTimeInterval(-portion)
            let ok = await updateEvent(event, changes: UpdateEventRequestDTO(startedAt: newStart))
            if !ok { return (session, false) }
            remaining -= portion
        }
        if remaining > 0.5 {
            let end = oldSessionStart
            let start = end.addingTimeInterval(-remaining)
            if let id = await insertNursingPrefix(side: side, start: start, end: end) {
                var ids = session.segmentEvents[side] ?? []
                ids.insert(id, at: 0)
                session.segmentEvents[side] = ids
                return (session, true)
            }
            return (session, false)
        }
        if remaining < -0.5 { return (session, false) }
        return (session, true)
    }

    private func discoveredNursingSegments(side: String, notBefore: Date) -> [UUID] {
        let cutoff = notBefore.addingTimeInterval(-2)
        return timeline
            .filter { event in
                event.deletedAt == nil
                    && event.type == EventType.feedBreast.rawValue
                    && event.side?.uppercased() == side
                    && event.endedAt != nil
                    && event.startedAt >= cutoff
            }
            .sorted { $0.startedAt < $1.startedAt }
            .map(\.id)
    }

    private func insertNursingPrefix(side: String, start: Date, end: Date) async -> UUID? {
        guard end.timeIntervalSince(start) >= 1, let childId else { return nil }
        let request = CreateEventRequestDTO(
            childId: childId,
            type: EventType.feedBreast.rawValue,
            startedAt: start,
            endedAt: end,
            side: side
        )
        do {
            let c = try service()
            let event = try await c.createEvent(request)
            try await store.upsertEvent(event)
            await refreshState()
            return event.id
        } catch let error where Self.isTransport(error) {
            let body = try? BenitoJSON.encoder.encode(request)
            _ = try? await store.enqueueOutbox(method: "POST", path: "/events", body: body)
            status = "Side segment queued (offline)"
            return nil
        } catch {
            if handleUnauthorized(error) { return nil }
            status = "Side segment failed: \(Self.message(for: error))"
            return nil
        }
    }

    func startSleepTimer() async {
        await startTimer(kind: "sleep", side: nil)
    }

    /// Shared walk / car-ride / crying timer; the server logs an `activity` event on stop.
    func startActivityTimer(_ kind: ActivityKind) async {
        await startTimer(kind: kind.timerKind, side: nil)
    }

    /// Turns a completed sleep event back into a live timer from its start time
    /// (so elapsed continues rather than resetting to 0). Soft-deletes the event so
    /// stop won't double-log. Online only — needs start + adjustTimerStart.
    func resumeSleepTimer(from event: EventDTO, startedAt: Date) async -> Bool {
        guard event.type == EventType.sleep.rawValue else {
            status = "Only sleep can be resumed as a timer"
            return false
        }
        guard event.endedAt != nil else {
            status = "Sleep is still open-ended"
            return false
        }
        if let active = babyState?.activeTimer, active.isActive {
            status = "Stop the running timer before resuming sleep"
            return false
        }
        guard let childId else {
            status = "No child"
            return false
        }

        // adjustTimerStart rejects starts older than 24h — clamp so resume still works.
        let now = Date()
        let earliest = now.addingTimeInterval(-23 * 60 * 60)
        let resumeStart = min(max(startedAt, earliest), now)
        BenitoLog.ui.notice("resumeSleepFromEvent")

        do {
            let c = try service()
            let timer = try await c.startTimer(childId: childId, kind: EventType.sleep.rawValue, side: nil)
            try await store.upsertTimer(timer)

            let adjusted: TimerDTO
            do {
                adjusted = try await c.adjustTimerStart(id: timer.id, startedAt: resumeStart)
            } catch {
                // Roll back the brand-new timer; stop auto-creates a tiny sleep — delete it if we can.
                if let stopped = try? await c.stopTimer(id: timer.id) {
                    try? await store.upsertTimer(stopped)
                }
                throw error
            }
            await applyLocalTimer(adjusted)

            do {
                try await c.deleteEvent(id: event.id)
                try await store.softDeleteEvent(id: event.id)
            } catch {
                BenitoLog.ui.error("resumeSleep deleteEvent failed: \(String(describing: error), privacy: .public)")
                status = "Sleep timer resumed — remove the old sleep entry if it still shows"
                await refreshState()
                return true
            }

            status = "Sleep timer resumed"
            await refreshState()
            return true
        } catch let error where Self.isTransport(error) {
            status = "Can't resume sleep while offline"
            return false
        } catch {
            if handleUnauthorized(error) { return false }
            BenitoLog.ui.error("resumeSleep failed: \(String(describing: error), privacy: .public)")
            status = "Resume sleep failed: \(Self.message(for: error))"
            return false
        }
    }

    func startBreastTimer(side: String) async {
        await startTimer(kind: "feed_breast", side: side)
    }

    private func startTimer(kind: String, side: String?) async {
        guard let childId else { status = "No child"; return }
        BenitoLog.ui.notice("startTimer \(kind, privacy: .public)")
        do {
            let c = try service()
            let timer = try await c.startTimer(childId: childId, kind: kind, side: side)
            try await store.upsertTimer(timer)
            await refreshState()
        } catch let error where Self.isTransport(error) {
            struct Body: Encodable {
                let child_id: UUID
                let kind: String
                let side: String?
                let at: Date
            }
            let body = try? BenitoJSON.encoder.encode(Body(child_id: childId, kind: kind, side: side, at: Date()))
            _ = try? await store.enqueueOutbox(method: "POST", path: "/timers", body: body)
            status = "Timer queued (offline)"
            await refreshOutboxCount()
        } catch {
            status = "Start timer failed: \(error)"
        }
    }

    func stopActiveTimer() async {
        guard let timer = babyState?.activeTimer else {
            status = "No active timer"
            return
        }
        let preserve = nursingPreserveSession
        let snapshot = babyState
        // Drop in-flight /state responses that still show this timer as running.
        stateFetchGeneration += 1
        // Server mode shows the stop at once; on device the stop itself is instant, and a
        // pre-stopped row would make it skip logging the sleep / feed it timed.
        if !isOnDevice {
            var local = timer
            local.state = "stopped"
            local.stoppedAt = Date()
            try? await store.upsertTimer(local)
        }
        babyState?.activeTimer = nil
        var stoppedCleanly = false
        do {
            let c = try service()
            let stopped = try await c.stopTimer(id: timer.id)
            try await store.upsertTimer(stopped)
            stoppedCleanly = true
            await refreshState()
        } catch let error where Self.isTransport(error) {
            struct Body: Encodable { let at: Date }
            let body = try? BenitoJSON.encoder.encode(Body(at: Date()))
            _ = try? await store.enqueueOutbox(
                method: "POST",
                path: "/timers/\(timer.id.uuidString)/stop",
                body: body
            )
            status = "Stop queued (offline)"
            stoppedCleanly = true
            await refreshOutboxCount()
        } catch {
            if let active = snapshot?.activeTimer {
                try? await store.upsertTimer(active)
            }
            babyState = snapshot
            status = "Stop timer failed: \(error)"
        }
        if stoppedCleanly && !preserve {
            nursingLive = nil
        }
        await LiveActivityController.shared.flush()
    }

    func pauseActiveTimer() async {
        guard let timer = babyState?.activeTimer, timer.isActive else {
            status = "No active timer"
            return
        }
        guard !timer.isPaused else {
            status = "Timer already paused"
            return
        }
        BenitoLog.ui.notice("pauseTimer \(timer.kind, privacy: .public)")
        do {
            let c = try service()
            let paused = try await c.pauseTimer(id: timer.id)
            try await store.upsertTimer(paused)
            await refreshState()
        } catch let error where Self.isTransport(error) {
            let at = Date()
            struct Body: Encodable { let at: Date }
            let body = try? BenitoJSON.encoder.encode(Body(at: at))
            _ = try? await store.enqueueOutbox(
                method: "POST",
                path: "/timers/\(timer.id.uuidString)/pause",
                body: body
            )
            // Freeze the clock locally until the queued pause reaches the server.
            var local = timer
            local.state = "paused"
            local.pausedAt = at
            await applyLocalTimer(local)
            status = "Pause queued (offline)"
            await refreshOutboxCount()
        } catch {
            status = "Pause timer failed: \(error)"
        }
    }

    func resumeActiveTimer() async {
        guard let timer = babyState?.activeTimer, timer.isActive else {
            status = "No active timer"
            return
        }
        guard timer.isPaused else {
            status = "Timer is not paused"
            return
        }
        BenitoLog.ui.notice("resumeTimer \(timer.kind, privacy: .public)")
        do {
            let c = try service()
            let resumed = try await c.resumeTimer(id: timer.id)
            try await store.upsertTimer(resumed)
            await refreshState()
        } catch let error where Self.isTransport(error) {
            let at = Date()
            struct Body: Encodable { let at: Date }
            let body = try? BenitoJSON.encoder.encode(Body(at: at))
            _ = try? await store.enqueueOutbox(
                method: "POST",
                path: "/timers/\(timer.id.uuidString)/resume",
                body: body
            )
            // Restart the clock locally until the queued resume reaches the server.
            var local = timer
            if let pausedAt = local.pausedAt {
                local.pausedSeconds += max(0, Int(at.timeIntervalSince(pausedAt)))
            }
            local.state = "running"
            local.pausedAt = nil
            await applyLocalTimer(local)
            status = "Resume queued (offline)"
            await refreshOutboxCount()
        } catch {
            status = "Resume timer failed: \(error)"
        }
    }

    /// Optimistic offline pause/resume: the server's next state/timer.upsert replaces it.
    private func applyLocalTimer(_ timer: TimerDTO) async {
        try? await store.upsertTimer(timer)
        babyState?.activeTimer = timer
    }

    func exportData() async {
        do {
            let c = try service()
            let bundle = try await c.exportBundle()
            try await store.replaceChildren(bundle.children)
            for event in bundle.events {
                try await store.upsertEvent(event)
            }
            for timer in bundle.timers {
                try await store.upsertTimer(timer)
            }
            let data = try BenitoJSON.encoder.encode(bundle)
            let url = try Self.writeExportFile(data: data, ext: "json")
            exportShareItem = ExportShareItem(url: url)
            lastExportSummary =
                "JSON @ \(bundle.exportedAt): \(bundle.events.count) events, \(bundle.timers.count) timers"
            status = lastExportSummary
            await loadLocalGlance()
        } catch {
            status = "Export failed: \(error)"
        }
    }

    /// Pediatrician-ready CSV (`GET /export.csv`) → temp file + share sheet.
    func exportCSV() async {
        do {
            let c = try service()
            let data = try await c.exportCSV()
            let url = try Self.writeExportFile(data: data, ext: "csv")
            exportShareItem = ExportShareItem(url: url)
            lastExportSummary = "CSV ready (\(data.count) bytes)"
            status = lastExportSummary
        } catch {
            if handleUnauthorized(error) { return }
            status = "CSV export failed: \(error)"
        }
    }

    private static func writeExportFile(data: Data, ext: String) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("benito-export-\(stamp).\(ext)", isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Invalidate the current invite code and replace it (D11). Shows the new code in `inviteCode`.
    func rotateInvite() async {
        do {
            BenitoLog.ui.notice("rotateInvite")
            let c = try client()
            let family = try await c.rotateInvite()
            inviteCode = family.inviteCode
            familyName = family.name
            hasFamily = true
            status = "Invite rotated: \(family.inviteCode)"
        } catch {
            if handleUnauthorized(error) { return }
            BenitoLog.ui.error("rotateInvite failed: \(String(describing: error), privacy: .public)")
            status = "Rotate invite failed: \(error.localizedDescription)"
        }
    }

    /// GET /summary/daily for an explicit local window (Timeline Day mode).
    func dailySummary(from: Date, to: Date) async -> DailySummaryDTO? {
        guard let childId else { return nil }
        do {
            let c = try service()
            return try await c.dailySummary(childId: childId, from: from, to: to)
        } catch {
            if handleUnauthorized(error) { return nil }
            BenitoLog.ui.error("dailySummary(range) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Device-local calendar day bounds → GET /summary/daily (D7).
    func refreshDailySummary() async {
        guard let childId else { return }
        do {
            let c = try service()
            let window = DayWindow(containing: Date())
            let summary = try await c.dailySummary(childId: childId, from: window.start, to: window.end)
            dailySummary = summary
            BenitoLog.ui.notice("dailySummary loaded total=\(summary.totalEvents, privacy: .public)")
        } catch {
            if handleUnauthorized(error) { return }
            // Keep last good summary when offline; don't clobber Home strip.
            BenitoLog.ui.error("dailySummary failed: \(String(describing: error), privacy: .public)")
            if !Self.isTransport(error) {
                status = "Summary failed: \(error.localizedDescription)"
            }
        }
    }

    func probeHealth() async {
        do {
            BenitoLog.ui.notice("probe /health")
            let c = try client()
            let h = try await c.health()
            status = "Health OK: \(h)"
        } catch {
            BenitoLog.ui.error("probe failed: \(error.localizedDescription, privacy: .public)")
            status = "Health failed: \(error) — check Server URL / ATS / Tailscale"
        }
    }

    /// Shared create path. `startedAt` nil = now, resolved here so an entry queued offline keeps
    /// the time it was logged rather than the time the outbox replays.
    private func log(
        type: String,
        subtype: String? = nil,
        side: String? = nil,
        amountValue: Double? = nil,
        amountUnit: String? = nil,
        notes: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) async {
        guard let childId else { status = "No child"; return }
        BenitoLog.ui.notice("log event \(type, privacy: .public)")
        let request = CreateEventRequestDTO(
            childId: childId,
            type: type,
            subtype: subtype,
            startedAt: startedAt ?? Date(),
            endedAt: endedAt,
            amountValue: amountValue,
            amountUnit: amountUnit,
            side: side,
            notes: notes
        )
        do {
            let c = try service()
            let event = try await c.createEvent(request)
            try await store.upsertEvent(event)
            status = "Logged \(type)"
            await refreshState()
        } catch let error where Self.isTransport(error) {
            let body = try? BenitoJSON.encoder.encode(request)
            _ = try? await store.enqueueOutbox(method: "POST", path: "/events", body: body)
            status = "Queued \(type) (offline)"
            await loadLocalGlance()
        } catch {
            if handleUnauthorized(error) { return }
            status = "Log failed: \(Self.message(for: error))"
        }
    }

    func flushOutbox() async {
        guard let api else { return }
        do {
            let n = try await OutboxFlusher(store: store, api: api).flush()
            if n > 0 {
                status = "Flushed \(n) outbox item(s)"
                await refreshState()
            }
            await refreshOutboxCount()
        } catch {
            // Keep quiet — still offline or transient.
        }
    }

    private func refreshOutboxCount() async {
        outboxPending = (try? await store.pendingOutbox().count) ?? 0
    }

    func connectSync() {
        guard hasFamily else {
            BenitoLog.ui.notice("sync skipped: no family yet")
            return
        }
        guard let api else {
            BenitoLog.ui.notice("sync skipped: no API client")
            return
        }
        Task {
            // The current route's address, not necessarily the saved Server URL.
            let url = await api.baseURL
            guard let token = await api.token else {
                BenitoLog.ui.notice("sync skipped: API client has no token")
                return
            }
            await MainActor.run {
                // Signed out or server changed while the token was being read.
                guard self.api === api else { return }
                sync?.disconnect()
                lastSyncServerError = nil
                let client = SyncClient(
                    serverBaseURL: url,
                    token: token,
                    clientId: clientId,
                    onEnvelope: { envelope in
                        Task { @MainActor in
                            self.scheduleSyncIngest(envelope)
                        }
                    },
                    onDisconnect: { reason in
                        Task { @MainActor in
                            self.syncConnected = false
                            // Prefer the server's explanation over URLSession's generic close error.
                            if let message = self.lastSyncServerError ?? reason {
                                self.status = "Sync disconnected: \(message)"
                            }
                            // The server closing on us is not "unreachable"; only a lost connection reroutes.
                            if self.lastSyncServerError == nil {
                                await self.rerouteIfNeeded()
                            }
                        }
                    },
                    onReconnect: {
                        Task { @MainActor in
                            self.status = "Sync reconnected"
                            // Live broadcast only covers events after auth; fetch what was missed.
                            await self.catchUp()
                            await self.flushOutbox()
                        }
                    }
                )
                self.sync = client
                client.connect()
                // SyncClient reports only reconnects; close the gap before this first connect too.
                Task { await self.catchUp() }
            }
        }
    }

    /// Chains sync handling so a slow `timer.upsert` refresh cannot overwrite a later stop.
    private func scheduleSyncIngest(_ envelope: SyncEnvelopeDTO) {
        let previous = syncTail
        syncTail = Task { @MainActor in
            await previous?.value
            await self.ingestSyncEnvelope(envelope)
        }
    }

    private func ingestSyncEnvelope(_ envelope: SyncEnvelopeDTO) async {
        await withSyncBackgroundTime {
            noteSyncEnvelope(envelope)
            try? await store.applySyncEnvelope(envelope)
            adoptTimerEnvelope(envelope)
            let refresh: Set<String> = [
                SyncMessageType.eventUpsert.rawValue,
                SyncMessageType.eventDelete.rawValue,
                SyncMessageType.timerUpsert.rawValue,
                SyncMessageType.timerStop.rawValue,
                SyncMessageType.state.rawValue,
                SyncMessageType.refetchState.rawValue,
            ]
            if refresh.contains(envelope.type) {
                await refreshState()
            }
        }
    }

    /// Applies a timer broadcast to the glance immediately so the island ends before `/state` returns.
    private func adoptTimerEnvelope(_ envelope: SyncEnvelopeDTO) {
        guard envelope.type == SyncMessageType.timerStop.rawValue
            || envelope.type == SyncMessageType.timerUpsert.rawValue
        else { return }
        guard let data = try? BenitoJSON.encoder.encode(envelope.payload),
              let timer = try? BenitoJSON.decoder.decode(TimerDTO.self, from: data)
        else { return }
        guard babyState?.childId == timer.childId || babyState?.activeTimer?.id == timer.id else { return }
        if timer.isActive {
            babyState?.activeTimer = timer
        } else if babyState?.activeTimer?.id == timer.id {
            babyState?.activeTimer = nil
        }
    }

    /// Gives ActivityKit time to end the island if `/sync` arrives while the app is backgrounded.
    private func withSyncBackgroundTime(_ work: () async -> Void) async {
        let app = UIApplication.shared
        var ended = false
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = app.beginBackgroundTask(withName: "benito.sync") {
            guard !ended else { return }
            ended = true
            app.endBackgroundTask(taskID)
        }
        await work()
        await LiveActivityController.shared.flush()
        guard !ended else { return }
        ended = true
        if taskID != .invalid {
            app.endBackgroundTask(taskID)
        }
    }

    /// `@AppStorage` defaults the toggle to on; `bool(forKey:)` would read a missing key as off.
    private var liveActivityEnabled: Bool {
        if UserDefaults.standard.object(forKey: LiveActivitySettings.enabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: LiveActivitySettings.enabledKey)
    }

    private func pushLiveActivity() {
        LiveActivityController.shared.sync(
            state: babyState,
            childName: childName,
            signedIn: isSignedIn,
            enabled: liveActivityEnabled
        )
    }

    /// `hello` = server accepted auth; `error` = server is about to close with this reason.
    private func noteSyncEnvelope(_ envelope: SyncEnvelopeDTO) {
        switch envelope.type {
        case SyncMessageType.hello.rawValue:
            lastSyncServerError = nil
            syncConnected = true
            if let label = route?.label { status = "Synced via \(label)" }
            BenitoLog.sync.notice("server accepted sync (hello)")
        case SyncMessageType.error.rawValue:
            if case .object(let obj) = envelope.payload, case .string(let message)? = obj["message"] {
                BenitoLog.sync.error("server sync error: \(message, privacy: .public)")
                lastSyncServerError = message
                status = "Sync error: \(message)"
            }
        case SyncMessageType.state.rawValue:
            if case .object(let obj) = envelope.payload,
               case .string(let action)? = obj["action"],
               action == "invite_rotated",
               case .string(let code)? = obj["invite_code"] {
                inviteCode = code
                BenitoLog.ui.notice("invite rotated via sync")
                status = "Invite updated: \(code)"
            }
        default:
            break
        }
    }
}


/// Bottle contents; raw value is the `feed_bottle` event subtype.
enum BottleMilk: String, CaseIterable, Identifiable {
    case formula, breastmilk

    var id: String { rawValue }

    var label: String {
        switch self {
        case .formula: return "Formula"
        case .breastmilk: return "Breast milk"
        }
    }
}

/// Common newborn medicines; `label` is stored as the event `subtype`.
enum MedicinePreset: String, CaseIterable, Identifiable {
    case vitaminD = "vitamin_d"
    case gasDrops = "gas_drops"
    case acetaminophen = "acetaminophen"
    case other = "other"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vitaminD: return "Vitamin D"
        case .gasDrops: return "Gas drops"
        case .acetaminophen: return "Acetaminophen"
        case .other: return "Other"
        }
    }

    /// Match a stored subtype back to a preset (label or raw value).
    static func matching(_ subtype: String?) -> MedicinePreset {
        guard let subtype else { return .vitaminD }
        let key = subtype.trimmingCharacters(in: .whitespacesAndNewlines)
        if let byRaw = MedicinePreset(rawValue: key.lowercased().replacingOccurrences(of: " ", with: "_")) {
            return byRaw
        }
        return allCases.first { $0.label.compare(key, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame } ?? .other
    }
}

/// Dose unit for medicine events (`amount_unit`).
enum MedicineDoseUnit: String, CaseIterable, Identifiable {
    case ml, drops, mg, iu = "IU"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ml: return "ml"
        case .drops: return "drops"
        case .mg: return "mg"
        case .iu: return "IU"
        }
    }
}

/// Pumping side; raw value is the `pump` event `side`.
enum PumpSide: String, CaseIterable, Identifiable {
    case left = "L", right = "R", both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .both: return "Both"
        }
    }
}

struct ContentView: View {
    @Binding var serverURLString: String
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init(serverURLString: Binding<String>) {
        _serverURLString = serverURLString
        _model = State(initialValue: AppModel(serverURLString: serverURLString.wrappedValue))
    }

    var body: some View {
        DesignPrototypeRoot(serverURLString: $serverURLString, model: model)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await model.appBecameActive() }
                }
            }
            .benitoLiveActivity(model: model)
            .benitoPartnerPairing(model.pairing)
            .benitoWindowSizeClassSource()
            .benitoOnboarding(model: model)
            .benitoJoinLinks(model: model)
            // Joining from an invite can move this phone to another server address.
            .onChange(of: model.serverURLString) { _, value in
                if serverURLString != value { serverURLString = value }
            }
    }
}

extension AppModel {
    /// Transport / connectivity failures → enqueue outbox instead of failing hard.
    static func isTransport(_ error: Error) -> Bool {
        if case .transport = error as? APIClientError { return true }
        return false
    }

    /// User-facing failure text: the server's `{"error": …}` message when present.
    static func message(for error: Error) -> String {
        if case .httpStatus(_, let data?)? = error as? APIClientError,
           let message = APIClientError.serverErrorMessage(from: data) {
            return message
        }
        return error.localizedDescription
    }
}


#Preview {
    ContentView(serverURLString: .constant(BenitoServerPresets.loopback))
}
