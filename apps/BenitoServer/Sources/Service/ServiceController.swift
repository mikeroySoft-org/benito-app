import BenitoKit
import Foundation
import Security

/// Installs, updates, starts, stops and restores the server as a LaunchAgent for one home.
///
/// The service is the one `scripts/macos-service.sh` sets up: the same label, plist, program
/// path and `benito.env`. Either tool can therefore take over from the other, and taking over a
/// script install is an in-place update.
actor ServiceController {
    /// The nightly `backup-db.sh` agent of a script install. The server takes its own backups
    /// once `BENITO_BACKUP_DIR` is set, so an update removes this one.
    private static let legacyBackupAgentLabel = "com.mikeroysoft.benito.backup"
    /// The name prefix the server gives its snapshots (`server/src/backup.rs`).
    private static let snapshotPrefix = "benito-"
    private static let startTimeout: Duration = .seconds(15)
    private static let stopTimeout: Duration = .seconds(5)
    private static let pollInterval: Duration = .milliseconds(300)
    /// A snapshot or a restore of a large database takes a while.
    private static let databaseCommandTimeout: Duration = .seconds(300)
    private static let maximumLogBytes: UInt64 = 5 * 1024 * 1024
    private static let newEnvFileHeader = """
        # Settings for the Benito server on this Mac, read by benito-server when it starts.
        # Benito Server.app edits the keys it knows and leaves every other line alone.
        """
    /// Characters the shell takes literally outside quotes.
    private static let bareValueCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-"
    )

    private struct CachedDigest {
        var size: UInt64
        var modified: Date
        var fileNumber: UInt64
        var digest: String
    }

    private let home: ServerHome
    private let client: AdminClient
    private let agent: Launchctl

    private var isChanging = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var digests: [String: CachedDigest] = [:]
    private var cachedBundledVersion: String?

    init(home: ServerHome, client: AdminClient) {
        self.home = home
        self.client = client
        agent = Launchctl(label: home.launchAgentLabel)
    }

    // MARK: - Reading

    func serviceInfo() async -> ServiceInfo {
        let state = await agent.state()
        let bundledVersion = await bundledServerVersion()
        return ServiceInfo(
            isInstalled: home.launchAgentPlistExists,
            isLoaded: state.isLoaded,
            pid: state.pid,
            lastExitStatus: state.lastExitStatus,
            isBinaryCurrent: isInstalledBinaryCurrent(),
            bundledVersion: bundledVersion
        )
    }

    /// The values in `benito.env`; empty when there is no file or it cannot be read.
    func settings() -> [String: String] {
        (try? EnvFile.load(from: home.envFile).values) ?? [:]
    }

    /// Whether the program launchd runs is byte for byte the one inside this app. True as well
    /// when the app has no server inside it: there is nothing to update to.
    func isInstalledBinaryCurrent() -> Bool {
        guard let bundled = ServerBinary.bundled else { return true }
        guard let wanted = digest(of: bundled), let installed = digest(of: home.installedBinary) else {
            return false
        }
        return wanted == installed
    }

    /// The version of the server inside this app, or `nil` when there is none or it will not run.
    func bundledServerVersion() async -> String? {
        if let cachedBundledVersion {
            return cachedBundledVersion
        }
        guard let bundled = ServerBinary.bundled,
              let version = try? await ServerBinary.version(of: bundled)
        else { return nil }
        cachedBundledVersion = version
        return version
    }

    // MARK: - Changing the service

    /// Sets up the service in a home that has none and starts the server. Existing data,
    /// settings and the session secret are kept.
    func install() async throws {
        try await serialized {
            try await performInstall()
        }
    }

    /// Updates a server that `scripts/macos-service.sh` installed, or any installed server whose
    /// program is not the one inside this app. Takes a snapshot first and changes nothing when
    /// that fails.
    /// - Returns: The snapshot taken before the update; `nil` when there was no database yet or
    ///   the snapshot's report could not be read.
    func adopt() async throws -> BackupResult? {
        try await serialized {
            try await performAdopt()
        }
    }

    func start() async throws {
        try await serialized {
            try await performStart()
        }
    }

    /// Stops the server until `start()` or the next login.
    func stop() async throws {
        try await serialized {
            try await performStop()
        }
    }

    func restart() async throws {
        try await serialized {
            try await performRestart()
        }
    }

    /// Replaces the database with `snapshot`. The server is stopped for the restore and started
    /// again afterwards, whether or not the restore worked.
    func restore(snapshot: URL) async throws -> RestoreResult {
        try await serialized {
            try await performRestore(snapshot)
        }
    }

    /// Stops the server and removes its LaunchAgent. The database, `benito.env`, backups, logs
    /// and the installed program all stay.
    func uninstall() async throws {
        try await serialized {
            try await agent.bootout()
            try step("remove the background service") {
                try removeIfPresent(home.launchAgentPlist)
            }
        }
    }

    /// Writes `changes` to `benito.env` (`nil` removes a key) and, when the service is loaded,
    /// restarts the server so it reads them. Does nothing when no value actually changes.
    func applySettings(_ changes: [String: String?]) async throws {
        try await serialized {
            var env = try loadEnv()
            let before = env
            for (key, value) in changes.sorted(by: { $0.key < $1.key }) {
                Self.assign(value, to: key, in: &env)
            }
            guard env != before else { return }
            try save(env)
            guard home.launchAgentPlistExists, await agent.state().isLoaded else { return }
            try await performRestart()
        }
    }

    /// Keeps the log from growing without bound: past 5 MB it is copied to `server.log.1` and
    /// emptied. launchd holds the file open for appending, so the live file has to stay the
    /// same file; renaming it away would leave the server writing into the archive forever.
    func rotateLogIfNeeded() throws {
        let log = home.logFile
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: log.posixPath),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size > Self.maximumLogBytes
        else { return }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        try step("rotate the server log") {
            try AtomicFile.copy(log, to: log.appendingPathExtension("1"), permissions: permissions)
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
        }
    }

    // MARK: - Steps

    private func performInstall() async throws {
        guard let bundled = ServerBinary.bundled else { throw ServiceError.bundledServerMissing }
        var env = try loadEnv()
        let port = try loopbackPort(for: env)
        // Without this the wait below could be answered by somebody else's server.
        if !(await agent.state().isLoaded), LoopbackPort.isInUse(port) {
            throw ServiceError.portInUse(port)
        }
        try applyServiceSettings(to: &env, port: port, generatingSecret: true)

        try createFolders(for: env)
        try installBinary(bundled)
        try save(env)
        try writePlist()
        try await agent.bootout()
        try await agent.bootstrap(plist: home.launchAgentPlist)
        try await waitUntilRunning(replacing: nil)
    }

    private func performAdopt() async throws -> BackupResult? {
        guard let bundled = ServerBinary.bundled else { throw ServiceError.bundledServerMissing }
        var env = try loadEnv()
        let port = try loopbackPort(for: env)
        let wasLoaded = await agent.state().isLoaded
        // A server that launchd does not run cannot be replaced from here, and the new one
        // could not bind the port next to it.
        if !wasLoaded, LoopbackPort.isInUse(port) {
            throw ServiceError.portInUse(port)
        }
        let oldPID = (try? await client.status())?.pid

        let snapshot = try await snapshotBeforeUpdate(using: bundled, env: env)

        let oldEnv = env
        let previousBinary = try keepPreviousBinary()
        let previousPlist = try? Data(contentsOf: home.launchAgentPlist)
        do {
            try applyServiceSettings(to: &env, port: port, generatingSecret: false)
            try createFolders(for: env)
            try installBinary(bundled)
            if env != oldEnv {
                try save(env)
            }
            let plistChanged = try writePlist()
            if wasLoaded, !plistChanged, env == oldEnv {
                // Only the program changed, and the job launchd holds still describes it.
                try await agent.kickstart(killRunning: true)
            } else {
                try await agent.bootout()
                try await agent.bootstrap(plist: home.launchAgentPlist)
            }
            try await waitUntilRunning(replacing: oldPID)
        } catch {
            guard let previousBinary else { throw error }
            let isServerBack = await rollBack(
                to: previousBinary,
                env: oldEnv,
                plist: previousPlist,
                wasLoaded: wasLoaded,
                port: port
            )
            throw ServiceError.updateRolledBack(
                reason: error.localizedDescription,
                wasRunning: wasLoaded,
                isServerBack: isServerBack
            )
        }
        // Only once the new server answers: until then the old nightly job is the family's
        // only backup schedule.
        if home.isDefault {
            try await removeLegacyBackupAgent()
        }
        return snapshot
    }

    /// Copies the program launchd runs today to `benito-server.previous`, so a failed update
    /// has something to go back to. `nil` when nothing is installed yet.
    private func keepPreviousBinary() throws -> URL? {
        let installed = home.installedBinary
        guard FileManager.default.fileExists(atPath: installed.posixPath) else { return nil }
        let previous = installed.appendingPathExtension("previous")
        try step("keep the current server program") {
            try AtomicFile.copy(installed, to: previous, permissions: 0o755)
        }
        return previous
    }

    /// Puts the program, settings and service definition back as they were before an update
    /// that failed, and starts the old server if it was running.
    /// - Returns: Whether something answers on the server's port again. The old server may
    ///   predate the admin API, so the port is the only thing that can be asked.
    private func rollBack(
        to previousBinary: URL,
        env: EnvFile,
        plist: Data?,
        wasLoaded: Bool,
        port: Int
    ) async -> Bool {
        do {
            try ServerBinary.install(previousBinary, to: home.installedBinary)
            if !env.text.isEmpty {
                try env.write(to: home.envFile)
            }
            if let plist {
                try AtomicFile.write(plist, to: home.launchAgentPlist, permissions: 0o644)
            }
            try await agent.bootout()
            guard wasLoaded else { return false }
            try await agent.bootstrap(plist: home.launchAgentPlist)
        } catch {
            return false
        }
        let deadline = ContinuousClock.now + Self.startTimeout
        while ContinuousClock.now < deadline {
            if LoopbackPort.isInUse(port) {
                return true
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return false
    }

    private func performStart() async throws {
        try requireInstalled()
        let state = await agent.state()
        if !state.isLoaded {
            let port = configuredPort()
            if LoopbackPort.isInUse(port) {
                throw ServiceError.portInUse(port)
            }
            try await agent.bootstrap(plist: home.launchAgentPlist)
        } else if state.pid == nil {
            // launchd is waiting out its restart delay after a crash. Whether this nudge is
            // accepted or not, the wait below reports what actually happened.
            try? await agent.kickstart(killRunning: false)
        }
        try await waitUntilRunning(replacing: nil)
    }

    private func performStop() async throws {
        try await agent.bootout()
        let deadline = ContinuousClock.now + Self.stopTimeout
        while (try? await client.status()) != nil {
            guard ContinuousClock.now < deadline else { throw ServiceError.didNotStop }
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    private func performRestart() async throws {
        guard await agent.state().isLoaded else {
            return try await performStart()
        }
        try requireInstalled()
        let oldPID = (try? await client.status())?.pid
        try await agent.kickstart(killRunning: true)
        try await waitUntilRunning(replacing: oldPID)
    }

    private func performRestore(_ snapshot: URL) async throws -> RestoreResult {
        try requireInstalled()
        let outcome: Result<RestoreResult, any Error>
        do {
            try await performStop()
            outcome = .success(try await runRestore(of: snapshot))
        } catch {
            outcome = .failure(error)
        }
        do {
            try await performStart()
        } catch {
            var restoreFailure: String?
            if case .failure(let restoreError) = outcome {
                restoreFailure = restoreError.localizedDescription
            }
            throw ServiceError.notRestartedAfterRestore(
                restoreFailure: restoreFailure,
                startFailure: error.localizedDescription
            )
        }
        return try outcome.get()
    }

    private func runRestore(of snapshot: URL) async throws -> RestoreResult {
        let result = try await runServer(home.installedBinary, arguments: ["restore", snapshot.posixPath])
        guard result.succeeded else {
            throw ServiceError.restoreFailed(result.failureText)
        }
        guard let report: RestoreResult = Self.report(in: result.stdout, decoder: JSONDecoder()) else {
            throw ServiceError.restoreOutputUnreadable(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return report
    }

    /// `benito-server backup` with the new program. It opens the database read-only beside the
    /// running server, so the old server keeps serving phones meanwhile.
    private func snapshotBeforeUpdate(using binary: URL, env: EnvFile) async throws -> BackupResult? {
        guard home.databaseExists else { return nil }
        let folder = Self.backupFolder(in: env) ?? home.backupDirectory.posixPath
        let result: ProcessResult
        do {
            result = try await runServer(binary, arguments: ["backup"], environment: ["BENITO_BACKUP_DIR": folder])
        } catch {
            throw ServiceError.snapshotFailed(error.localizedDescription)
        }
        guard result.succeeded else {
            throw ServiceError.snapshotFailed(result.failureText)
        }
        guard var report: BackupResult = Self.report(in: result.stdout, decoder: BenitoJSON.decoder) else {
            return nil
        }
        // Retention counts and prunes `benito-*.db`. Under another name this snapshot stays
        // until a person deletes it, like the `pre-restore-` copies.
        if report.name.hasPrefix(Self.snapshotPrefix) {
            let kept = "pre-update-" + report.name.dropFirst(Self.snapshotPrefix.count)
            let source = URL(fileURLWithPath: report.path)
            let destination = source.deletingLastPathComponent().appending(path: kept)
            if (try? FileManager.default.moveItem(at: source, to: destination)) != nil {
                report.name = kept
                report.path = destination.posixPath
            }
        }
        return report
    }

    private func removeLegacyBackupAgent() async throws {
        try await Launchctl(label: Self.legacyBackupAgentLabel).bootout()
        try step("remove the old backup agent") {
            try removeIfPresent(ServerHome.launchAgentPlist(label: Self.legacyBackupAgentLabel))
        }
    }

    /// Running means the admin API of a new process answers; a server about to be replaced
    /// can still answer for a moment after the restart was requested.
    private func waitUntilRunning(replacing oldPID: Int?) async throws {
        let deadline = ContinuousClock.now + Self.startTimeout
        while true {
            if home.adminFileExists, let status = try? await client.status(), status.pid != oldPID {
                return
            }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: Self.pollInterval)
        }
        let state = await agent.state()
        throw ServiceError.didNotStart(lastExitStatus: state.pid == nil ? state.lastExitStatus : nil)
    }

    // MARK: - Files

    private func requireInstalled() throws {
        guard home.launchAgentPlistExists else { throw ServiceError.notInstalled }
        let binary = home.installedBinary.posixPath
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw ServiceError.installedBinaryMissing(path: binary)
        }
    }

    private func createFolders(for env: EnvFile) throws {
        var folders = [
            home.dataDirectory,
            home.installedBinary.deletingLastPathComponent(),
            home.logFile.deletingLastPathComponent(),
        ]
        if let backupFolder = Self.backupFolder(in: env) {
            folders.append(URL(fileURLWithPath: backupFolder, isDirectory: true))
        }
        try step("create the server's folders") {
            for folder in folders {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }
    }

    private func installBinary(_ bundled: URL) throws {
        try step("install the server program") {
            try ServerBinary.install(bundled, to: home.installedBinary)
        }
    }

    @discardableResult
    private func writePlist() throws -> Bool {
        try step("write the background service's settings") {
            try LaunchAgentPlist.write(for: home)
        }
    }

    private func loadEnv() throws -> EnvFile {
        try step("read \(home.envFile.posixPath)") {
            try EnvFile.load(from: home.envFile)
        }
    }

    private func save(_ env: EnvFile) throws {
        try step("save \(home.envFile.posixPath)") {
            try env.write(to: home.envFile)
        }
    }

    private func removeIfPresent(_ file: URL) throws {
        do {
            try FileManager.default.removeItem(at: file)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    /// Runs a file-system step so that a failure says which step it was.
    private func step<Value>(_ description: String, _ body: () throws -> Value) throws -> Value {
        do {
            return try body()
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.fileStepFailed(step: description, detail: error.localizedDescription)
        }
    }

    private func digest(of binary: URL) -> String? {
        let path = binary.posixPath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else {
            digests[path] = nil
            return nil
        }
        if let cached = digests[path],
           cached.size == size, cached.modified == modified, cached.fileNumber == fileNumber {
            return cached.digest
        }
        guard let digest = try? ServerBinary.digest(of: binary) else { return nil }
        digests[path] = CachedDigest(size: size, modified: modified, fileNumber: fileNumber, digest: digest)
        return digest
    }

    // MARK: - Settings

    /// The loopback port the server is to listen on. The real install always uses 8080, where
    /// Tailscale Serve expects it; a scratch home keeps the port it has, or gets a free one.
    private func loopbackPort(for env: EnvFile) throws -> Int {
        guard !home.isDefault else { return home.defaultPort }
        if let port = env["BIND_ADDR"].flatMap(BindAddress.loopbackPort(in:)) {
            return port
        }
        guard let port = LoopbackPort.available() else { throw ServiceError.noFreePort }
        return port
    }

    private func configuredPort() -> Int {
        settings()["BIND_ADDR"].flatMap(BindAddress.loopbackPort(in:)) ?? home.defaultPort
    }

    /// The keys the service depends on. Everything else in the file is left as it is, and an
    /// existing session secret is never replaced.
    private func applyServiceSettings(to env: inout EnvFile, port: Int, generatingSecret: Bool) throws {
        if env.text.isEmpty {
            env = EnvFile(text: Self.newEnvFileHeader)
        }
        if generatingSecret, !Self.hasValue("SESSION_SECRET", in: env), !Self.hasValue("SESSION_SECRET_FILE", in: env) {
            let secret = try Self.newSessionSecret()
            Self.assign(secret, to: "SESSION_SECRET", in: &env)
        }
        let lanPort = env["BENITO_LAN_PORT"].flatMap(BindAddress.parsePort)
        Self.assign(home.databaseFile.posixPath, to: "DATABASE_PATH", in: &env)
        Self.assign(BindAddress.list(loopbackPort: port, lanPort: lanPort), to: "BIND_ADDR", in: &env)
        Self.assign("127.0.0.1:0", to: "BENITO_ADMIN_ADDR", in: &env)
        if Self.backupFolder(in: env) == nil {
            Self.assign(home.backupDirectory.posixPath, to: "BENITO_BACKUP_DIR", in: &env)
        }
    }

    private static func backupFolder(in env: EnvFile) -> String? {
        hasValue("BENITO_BACKUP_DIR", in: env) ? env["BENITO_BACKUP_DIR"] : nil
    }

    private static func hasValue(_ key: String, in env: EnvFile) -> Bool {
        env[key]?.isEmpty == false
    }

    /// Sets `key` unless it already has that value, so an unchanged line keeps its spelling.
    private static func assign(_ value: String?, to key: String, in env: inout EnvFile) {
        guard env[key] != value else { return }
        env.set(key, to: value.map(shellSafe))
    }

    /// `scripts/run-server.sh` reads `benito.env` with the shell's `source`, so a value with a
    /// space in it (every path under Application Support) goes in double quotes. The server
    /// and `EnvFile` drop that pair when they read it. A value that would need escaping inside
    /// quotes is written as it is, because neither reader knows escapes.
    private static func shellSafe(_ value: String) -> String {
        let isBare = value.unicodeScalars.allSatisfy { bareValueCharacters.contains($0) }
        let needsEscaping = value.contains { "\"$`\\".contains($0) }
        return isBare || needsEscaping ? value : "\"\(value)\""
    }

    private static func newSessionSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ServiceError.secretNotGenerated
        }
        return Hex.string(bytes)
    }

    // MARK: - Running the server program

    /// Runs a `benito-server` subcommand against this home's `benito.env`.
    ///
    /// The server lets variables that are already set win over the file, so the child gets a
    /// minimal environment instead of this app's: a `DATABASE_PATH` left over in the shell that
    /// launched the app must not point a backup or a restore at another database.
    private func runServer(
        _ binary: URL,
        arguments: [String],
        environment extra: [String: String] = [:]
    ) async throws -> ProcessResult {
        var environment = extra
        environment["BENITO_ENV_FILE"] = home.envFile.posixPath
        let inherited = ProcessInfo.processInfo.environment
        for key in ["HOME", "PATH", "TMPDIR", "USER"] {
            environment[key] = inherited[key]
        }
        return try await ProcessRunner.run(
            binary,
            arguments: arguments,
            environment: environment,
            currentDirectory: home.dataDirectory,
            timeout: Self.databaseCommandTimeout
        )
    }

    /// The last JSON object the server printed, which is the report of a `backup` or `restore`.
    private static func report<Report: Decodable>(in output: String, decoder: JSONDecoder) -> Report? {
        output.split(whereSeparator: \.isNewline)
            .last { $0.hasPrefix("{") }
            .flatMap { try? decoder.decode(Report.self, from: Data($0.utf8)) }
    }

    // MARK: - One change at a time

    /// Runs `change` after every change that was asked for before it has finished. An actor
    /// alone does not give that: its methods interleave at every `await`.
    private func serialized<Value>(_ change: () async throws -> Value) async throws -> Value {
        if isChanging {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isChanging = true
        }
        defer {
            if waiters.isEmpty {
                isChanging = false
            } else {
                // The turn passes straight to the next in line, so `isChanging` stays set.
                waiters.removeFirst().resume()
            }
        }
        return try await change()
    }
}
