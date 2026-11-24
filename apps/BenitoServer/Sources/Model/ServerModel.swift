import BenitoKit
import Foundation
import Observation

/// Single source of truth for what the app knows about the server on this Mac.
@MainActor
@Observable
final class ServerModel {
    static let mainWindowID = "main"

    private static let logRotationInterval: Duration = .seconds(3600)

    let home: ServerHome

    private(set) var connection: ConnectionState = .checking
    private(set) var status: ServerStatus?
    private(set) var glance: [ChildGlance] = []
    private(set) var families: [AdminFamily] = []
    private(set) var backups: BackupList?
    private(set) var lastBackupResult: BackupResult?
    private(set) var isBackingUp = false

    /// The LaunchAgent that runs the server for this home, as of the last refresh.
    private(set) var serviceInfo = ServiceInfo()
    /// The values in `benito.env`; empty when there is no file. Refreshed with the status.
    private(set) var settings: [String: String] = [:]
    private(set) var lastRestoreResult: RestoreResult?

    /// Failure of the most recent action or refresh, in words a person can read.
    var lastError: String?

    /// Optional only because the sidebar list binds to an optional selection.
    var selectedPane: MainPane? = .overview
    var isInviteSheetPresented = false

    let client: AdminClient
    private let service: ServiceController
    /// Changes to the service that were asked for and have not finished, oldest first. There is
    /// more than one only when settings are applied while another change is still running.
    private var operations: [ServiceOperation] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastLogRotationCheck: ContinuousClock.Instant?

    init(home: ServerHome = .resolve()) {
        self.home = home
        let client = AdminClient(home: home)
        self.client = client
        service = ServiceController(home: home, client: client)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.poll() else { return }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Derived state

    var isRunning: Bool { connection == .running }

    var indicator: StatusIndicator {
        if isBusy {
            return .working
        }
        let needsAttention = status?.backupNeedsAttention == true || isUpdateAvailable
        return switch connection {
        case .checking: .checking
        case .running: needsAttention ? .needsAttention : .running
        case .legacy: .needsAttention
        case .stopped, .notInstalled: .stopped
        }
    }

    var statusLine: String {
        if let operation {
            return operation.title
        }
        guard isRunning, let status else {
            return connection == .stopped && serviceInfo.isLoaded ? "Not answering" : connection.title
        }
        if let error = status.backup.lastError {
            return "Running, last backup failed: \(error)"
        }
        if status.backup.isOverdue(serverStartedAt: status.startedAt) {
            return "Running, backup overdue"
        }
        if isUpdateAvailable {
            return "Running, an update of the server is ready"
        }
        return connection.title
    }

    /// What to show in place of server details while the server is not answering.
    var explanation: String? {
        operation?.explanation ?? connection.explanation(service: serviceInfo)
    }

    var backupsEnabled: Bool { status?.backup.enabled == true }

    var advertisedURLs: [String] { status?.advertisedUrls ?? [] }

    // MARK: - Service state

    /// The change to the service that is under way, if any.
    var operation: ServiceOperation? { operations.first }

    var isBusy: Bool { !operations.isEmpty }

    /// A LaunchAgent for this home is installed, so the app can start, stop and restart the server.
    var isServiceManaged: Bool { serviceInfo.isInstalled }

    /// The server that answers is not one launchd runs for this home: a developer script
    /// started it, for example. The app can show it but not stop or restart it.
    var isRunningOutsideApp: Bool { isRunning && !serviceInfo.isLoaded }

    /// Start, stop, restart and restore go through launchd and then wait for the admin API. So
    /// the service has to be what runs the server, and the server has to be one with an admin
    /// API: one that `scripts/macos-service.sh` installed needs Update Server first.
    var canControlService: Bool {
        guard isServiceManaged, !isRunningOutsideApp, isAdminAPIConfigured else { return false }
        if case .legacy = connection {
            return false
        }
        return true
    }

    /// The installed server program differs from the one inside this app, and the one inside
    /// the app is not older than what is running.
    var isUpdateAvailable: Bool {
        guard serviceInfo.isInstalled, !serviceInfo.isBinaryCurrent else { return false }
        guard let running = status?.version, let bundled = serviceInfo.bundledVersion else { return true }
        return running.compare(bundled, options: .numeric) != .orderedDescending
    }

    /// The port the server's public API answers on at 127.0.0.1: the one `benito.env` names,
    /// else the one a running server reports, else the default.
    var publicPort: Int {
        if let port = settings["BIND_ADDR"].flatMap(BindAddress.loopbackPort(in:)) {
            return port
        }
        if let listeners = status?.listeners,
           let port = BindAddress.loopbackPort(in: listeners.joined(separator: ",")) {
            return port
        }
        return home.defaultPort
    }

    /// The one step that gets a server going that is not answering or cannot be managed yet.
    var setupAction: ServiceSetupAction? {
        switch connection {
        case .checking, .running: nil
        case .legacy: serviceInfo.isInstalled ? .update : nil
        case .stopped: stoppedSetupAction
        case .notInstalled: .install
        }
    }

    /// `benito.env` is what turns the admin API on. An install by `scripts/macos-service.sh`
    /// does not have the setting until the app updates it.
    private var isAdminAPIConfigured: Bool {
        settings["BENITO_ADMIN_ADDR"]?.isEmpty == false
    }

    private var stoppedSetupAction: ServiceSetupAction {
        guard serviceInfo.isInstalled else { return .install }
        // Starting a server without an admin API would leave the app waiting for an answer
        // that never comes; updating it starts it as well.
        return isAdminAPIConfigured ? .start : .update
    }

    // MARK: - Routing

    func showInvite() {
        selectedPane = .people
        isInviteSheetPresented = true
    }

    // MARK: - Refresh

    /// Loads the service state, status and glance, works out the connection state, and returns
    /// how long to wait before the next poll.
    @discardableResult
    func refresh() async -> Duration {
        await refreshService()
        do {
            status = try await client.status()
            connection = .running
        } catch let error as AdminError where !error.meansNotRunning {
            // Something answered on the admin port, so the server is up even though this call failed.
            connection = .running
            report(error)
            return .seconds(5)
        } catch {
            await resolveNotRunning()
            return .seconds(10)
        }
        do {
            glance = try await client.glance()
        } catch {
            report(error)
        }
        return .seconds(5)
    }

    func refreshPeople() async {
        guard isRunning else { return }
        do {
            families = try await client.people()
        } catch {
            report(error)
        }
    }

    func refreshBackups() async {
        guard isRunning else { return }
        do {
            backups = try await client.backups()
        } catch {
            report(error)
        }
    }

    // MARK: - Mutations

    func backUpNow() async {
        guard !isBackingUp else { return }
        isBackingUp = true
        defer { isBackingUp = false }
        lastError = nil
        do {
            lastBackupResult = try await client.createBackup()
            await refresh()
            await refreshBackups()
        } catch {
            report(error)
        }
    }

    /// Returns the new invite with its one-time secret, or `nil` after setting `lastError`.
    func createInvite(_ request: InviteRequest) async -> FamilyInviteDTO? {
        lastError = nil
        do {
            let invite = try await client.createInvite(request)
            await refreshPeople()
            return invite
        } catch {
            report(error)
            return nil
        }
    }

    func revokeInvite(_ invite: FamilyInviteDTO) async {
        await mutatePeople { try await $0.revokeInvite(id: invite.id) }
    }

    func revokeDevice(_ device: MemberDeviceDTO) async {
        await mutatePeople { try await $0.revokeDevice(id: device.id) }
    }

    func removeMember(_ member: FamilyMemberDTO, from family: AdminFamily) async {
        await mutatePeople { try await $0.removeMember(familyID: family.id, userID: member.userId) }
    }

    // MARK: - Service

    func installServer() async {
        await change(.installing) { try await $0.install() }
    }

    /// Replaces the installed server program with the one inside this app, after a snapshot.
    func updateServer() async {
        let updated = await change(.updating) { service in
            if let snapshot = try await service.adopt() {
                lastBackupResult = snapshot
            }
        }
        if updated {
            await refreshBackups()
        }
    }

    func startServer() async {
        await change(.starting) { try await $0.start() }
    }

    func stopServer() async {
        await change(.stopping) { try await $0.stop() }
    }

    func restartServer() async {
        await change(.restarting) { try await $0.restart() }
    }

    /// Puts the database back to `snapshot`. The outcome lands in `lastRestoreResult` or `lastError`.
    func restoreBackup(_ snapshot: BackupSnapshot) async {
        let restored = await change(.restoring) { service in
            lastRestoreResult = nil
            lastRestoreResult = try await service.restore(snapshot: URL(fileURLWithPath: snapshot.path))
        }
        if restored {
            // Everything the panes loaded belongs to the data that was just replaced.
            await refreshBackups()
            await refreshPeople()
        }
    }

    /// Removes the background service. The data, settings, backups, logs and server program stay.
    func uninstallServer() async {
        await change(.uninstalling) { try await $0.uninstall() }
    }

    func perform(_ action: ServiceSetupAction) async {
        switch action {
        case .install: await installServer()
        case .update: await updateServer()
        case .start: await startServer()
        }
    }

    /// Writes `changes` to `benito.env` (`nil` removes a key), restarts the server when the
    /// service is installed and loaded, and waits until it answers again. Unlike the other
    /// service actions this one waits its turn when another change is running.
    /// - Returns: `false` after setting `lastError` when something failed.
    func applySettings(_ changes: [String: String?]) async -> Bool {
        if case .legacy = connection {
            lastError = "This older server cannot be restarted from the app. Update the server first, then change its settings."
            return false
        }
        return await change(.applyingSettings, waitsForTurn: true) { try await $0.applySettings(changes) }
    }

    // MARK: - Private

    /// Runs one change to the service: progress while it runs, a refresh when it ends, and
    /// the failure, if any, in `lastError`. A change asked for while another runs is dropped
    /// unless it `waitsForTurn`; the buttons that start one are disabled meanwhile.
    @discardableResult
    private func change(
        _ operation: ServiceOperation,
        waitsForTurn: Bool = false,
        _ work: (ServiceController) async throws -> Void
    ) async -> Bool {
        guard waitsForTurn || !isBusy else { return false }
        operations.append(operation)
        lastError = nil
        var failure: String?
        do {
            try await work(service)
        } catch {
            failure = Self.message(for: error)
        }
        await refresh()
        if let index = operations.firstIndex(of: operation) {
            operations.remove(at: index)
        }
        if let failure {
            lastError = failure
        }
        return failure == nil
    }

    private func poll() async -> Duration {
        let interval = await refresh()
        await rotateLogIfDue()
        return interval
    }

    private func rotateLogIfDue() async {
        let now = ContinuousClock.now
        if let lastLogRotationCheck, now - lastLogRotationCheck < Self.logRotationInterval {
            return
        }
        lastLogRotationCheck = now
        // Only launchd's log is known to be safe to truncate in place.
        guard isServiceManaged else { return }
        do {
            try await service.rotateLogIfNeeded()
        } catch {
            report(error)
        }
    }

    private func refreshService() async {
        let info = await service.serviceInfo()
        if info != serviceInfo {
            serviceInfo = info
        }
        let values = await service.settings()
        if values != settings {
            settings = values
        }
    }

    private func mutatePeople(_ operation: @Sendable (AdminClient) async throws -> Void) async {
        lastError = nil
        do {
            try await operation(client)
        } catch {
            report(error)
        }
        await refreshPeople()
        await refresh()
    }

    private func resolveNotRunning() async {
        status = nil
        glance = []
        families = []
        backups = nil
        if let legacy = await client.legacyHealth() {
            connection = .legacy(version: legacy.version)
        } else if serviceInfo.isInstalled || home.adminFileExists || home.databaseExists {
            connection = .stopped
        } else {
            connection = .notInstalled
        }
    }

    private func report(_ error: Error) {
        lastError = Self.message(for: error)
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
