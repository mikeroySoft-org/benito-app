import CryptoKit
import Foundation

/// Where a Benito server keeps its files on this Mac, and where its admin handoff lives.
struct ServerHome: Sendable, Equatable {
    static let environmentKey = "BENITO_SERVER_HOME"

    /// The label `scripts/macos-service.sh` uses, so the app and the script manage the same service.
    private static let defaultLaunchAgentLabel = "com.mikeroysoft.benito.server"

    let dataDirectory: URL
    let adminFile: URL
    let logFile: URL
    /// False when `BENITO_SERVER_HOME` points the app at a scratch folder (dev harness).
    let isDefault: Bool

    var databaseFile: URL { dataDirectory.appending(path: "benito.db") }

    var envFile: URL { dataDirectory.appending(path: "benito.env") }

    /// The copy of the server that launchd runs. It lives outside the app so that moving or
    /// updating the app never pulls the program out from under a running server.
    var installedBinary: URL { dataDirectory.appending(path: "bin/benito-server") }

    var backupDirectory: URL {
        isDefault
            ? URL.homeDirectory.appending(path: "Backups/benito", directoryHint: .isDirectory)
            : dataDirectory.appending(path: "backups", directoryHint: .isDirectory)
    }

    /// A scratch home gets a label of its own, derived from its path, so a test install can
    /// never replace or stop the real service.
    var launchAgentLabel: String {
        guard !isDefault else { return Self.defaultLaunchAgentLabel }
        let digest = SHA256.hash(data: Data(dataDirectory.posixPath.utf8))
        return "\(Self.defaultLaunchAgentLabel).dev-\(Hex.string(digest.prefix(4)))"
    }

    var launchAgentPlist: URL { Self.launchAgentPlist(label: launchAgentLabel) }

    /// The loopback port phones reach through Tailscale Serve.
    var defaultPort: Int { 8080 }

    /// Health endpoint of a server installed by `scripts/macos-service.sh`. Only the default home
    /// probes it, and nothing else on that port is ever called.
    var legacyHealthURL: URL? {
        isDefault ? URL(string: "http://127.0.0.1:\(defaultPort)/health") : nil
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ServerHome {
        if let override = environment[environmentKey], !override.isEmpty {
            let home = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            return ServerHome(
                dataDirectory: home,
                adminFile: home.appending(path: "admin.json"),
                logFile: home.appending(path: "logs/server.log"),
                isDefault: false
            )
        }
        let data = URL.applicationSupportDirectory.appending(path: "Benito", directoryHint: .isDirectory)
        return ServerHome(
            dataDirectory: data,
            adminFile: data.appending(path: "admin.json"),
            logFile: URL.libraryDirectory.appending(path: "Logs/Benito/server.log"),
            isDefault: true
        )
    }

    /// Per-user LaunchAgents are always loaded from `~/Library/LaunchAgents`, whatever the home.
    static func launchAgentPlist(label: String) -> URL {
        URL.libraryDirectory.appending(path: "LaunchAgents/\(label).plist")
    }

    var adminFileExists: Bool {
        FileManager.default.fileExists(atPath: adminFile.path(percentEncoded: false))
    }

    var databaseExists: Bool {
        FileManager.default.fileExists(atPath: databaseFile.path(percentEncoded: false))
    }

    var launchAgentPlistExists: Bool {
        FileManager.default.fileExists(atPath: launchAgentPlist.path(percentEncoded: false))
    }
}
