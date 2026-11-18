import CryptoKit
import Foundation

/// The `benito-server` program: the copy inside the app, and the copy launchd runs.
enum ServerBinary {
    static let name = "benito-server"

    private static let versionTimeout: Duration = .seconds(10)

    /// The server that ships beside the app's own executable. `nil` in a build without one.
    static var bundled: URL? {
        Bundle.main.url(forAuxiliaryExecutable: name)
    }

    /// Copies `source` into place through a temporary file and a rename, so a running server
    /// keeps the program it started with and macOS never sees a half-written executable.
    static func install(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try AtomicFile.copy(source, to: destination, permissions: 0o755)
        // A downloaded app's files are quarantined and a copy inherits the flag. Nothing would
        // ever clear it there, and macOS can refuse a quarantined program that launchd starts.
        removexattr(destination.path(percentEncoded: false), "com.apple.quarantine", 0)
    }

    /// SHA-256 of the file, as hex. Two copies of the same build have the same digest.
    static func digest(of binary: URL) throws -> String {
        Hex.string(SHA256.hash(data: try Data(contentsOf: binary, options: .mappedIfSafe)))
    }

    /// Runs `binary --version`, which prints `benito-server X.Y.Z`, and returns `X.Y.Z`.
    static func version(of binary: URL) async throws -> String {
        let result = try await ProcessRunner.run(binary, arguments: ["--version"], timeout: versionTimeout)
        guard result.succeeded else {
            throw ServiceError.commandFailed(command: "\(name) --version", detail: result.failureText)
        }
        let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix("\(name) ") ? String(line.dropFirst(name.count + 1)) : line
    }
}
