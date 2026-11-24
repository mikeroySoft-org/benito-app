import Foundation

/// The Tailscale command-line tool on this Mac. Only ever asked for status and for Serve; never
/// for Funnel, which would put the server on the public internet.
struct TailscaleCLI: Sendable, Equatable {
    static let downloadAddress = "https://tailscale.com/download"

    private static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]
    private static let timeout: Duration = .seconds(15)

    let executable: URL

    static func locate() -> TailscaleCLI? {
        candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { TailscaleCLI(executable: URL(fileURLWithPath: $0)) }
    }

    static func serveArguments(loopbackPort: Int) -> [String] {
        ["serve", "--bg", "--https=443", "http://127.0.0.1:\(loopbackPort)"]
    }

    /// The Serve command as a person would type it, for the confirmation dialog.
    static func serveCommandLine(loopbackPort: Int) -> String {
        (["tailscale"] + serveArguments(loopbackPort: loopbackPort)).joined(separator: " ")
    }

    func snapshot(loopbackPort: Int) async throws -> TailscaleSnapshot {
        let statusOutput = try await run(["status", "--json"])
        guard let status = try? JSONDecoder().decode(TailscaleStatus.self, from: Data(statusOutput.standardOutput.utf8)) else {
            throw failure(of: statusOutput)
        }
        // Serve can be unreadable (signed out, for example) while the status above is fine.
        let serveOutput = try await run(["serve", "status", "--json"])
        let config = try? JSONDecoder().decode(
            TailscaleServeConfig.self,
            from: Data(serveOutput.standardOutput.utf8)
        )
        let serve = config?.state(forLoopbackPort: loopbackPort) ?? .unknown
        return TailscaleSnapshot(
            isConnected: status.isConnected,
            backendState: status.backendState,
            name: status.name,
            serve: serve,
            otherTarget: serve == .notForwarding ? config?.currentTarget : nil
        )
    }

    func turnOnServe(loopbackPort: Int) async throws {
        let output = try await run(Self.serveArguments(loopbackPort: loopbackPort))
        guard output.succeeded else { throw failure(of: output) }
    }

    private func run(_ arguments: [String]) async throws -> CommandOutput {
        do {
            return try await ExternalCommand.run(executable, arguments: arguments, timeout: Self.timeout)
        } catch {
            throw TailscaleError.couldNotStart(error.localizedDescription)
        }
    }

    private func failure(of output: CommandOutput) -> TailscaleError {
        let said = output.complaint
        if output.timedOut {
            return .timedOut(said: said)
        }
        let lowered = said.lowercased()
        if lowered.contains("https"), lowered.contains("enable") || lowered.contains("certificate") {
            return .httpsNotEnabled(said)
        }
        return .failed(said)
    }
}
