import Foundation

/// The LaunchAgent that keeps `benito-server` running for a home. Key for key the plist that
/// `scripts/macos-service.sh` writes, so either tool can take over an install from the other.
enum LaunchAgentPlist {
    static func contents(for home: ServerHome) -> [String: Any] {
        let log = home.logFile.posixPath
        return [
            "Label": home.launchAgentLabel,
            "ProgramArguments": [home.installedBinary.posixPath],
            "EnvironmentVariables": ["BENITO_ENV_FILE": home.envFile.posixPath],
            "WorkingDirectory": home.dataDirectory.posixPath,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ProcessType": "Background",
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
    }

    /// Writes the plist unless the one on disk already says the same thing.
    /// - Returns: Whether the file changed, which is when launchd has to load the job again.
    @discardableResult
    static func write(for home: ServerHome) throws -> Bool {
        let wanted = contents(for: home)
        let destination = home.launchAgentPlist
        if let data = try? Data(contentsOf: destination),
           let existing = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary,
           existing.isEqual(to: wanted) {
            return false
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(fromPropertyList: wanted, format: .xml, options: 0)
        try AtomicFile.write(data, to: destination, permissions: 0o644)
        return true
    }
}
