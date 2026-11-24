import Foundation

/// `/bin/launchctl` for one job in the user's GUI domain, which is where LaunchAgents run.
struct Launchctl: Sendable {
    private static let executable = URL(fileURLWithPath: "/bin/launchctl")
    private static let commandTimeout: Duration = .seconds(20)
    /// launchd tears a job down in the background after `bootout` returns.
    private static let unloadTimeout: Duration = .seconds(10)
    private static let unloadPollInterval: Duration = .milliseconds(100)

    let label: String

    private var domain: String { "gui/\(getuid())" }
    private var target: String { "\(domain)/\(label)" }

    /// Whether launchd has the job, and what it knows about its process. A `launchctl` that
    /// cannot be run reads as "not loaded".
    func state() async -> LaunchAgentState {
        guard let result = try? await run(["print", target]), result.succeeded else {
            return .notLoaded
        }
        return LaunchAgentState(printOutput: result.stdout)
    }

    /// Loads the job from its plist. With `RunAtLoad` that also starts it.
    func bootstrap(plist: URL) async throws {
        try await runExpectingSuccess(["bootstrap", domain, plist.posixPath])
    }

    /// Unloads the job, which stops its process, and returns once launchd has let go of it:
    /// `bootstrap` fails until then. A job that is not loaded is not an error.
    func bootout() async throws {
        _ = try await run(["bootout", target])
        let deadline = ContinuousClock.now + Self.unloadTimeout
        while await state().isLoaded {
            guard ContinuousClock.now < deadline else {
                throw ServiceError.didNotUnload(label: label)
            }
            try await Task.sleep(for: Self.unloadPollInterval)
        }
    }

    /// Starts the job's process. With `killRunning`, a running process is killed first, so
    /// the job restarts.
    func kickstart(killRunning: Bool) async throws {
        try await runExpectingSuccess(["kickstart"] + (killRunning ? ["-k"] : []) + [target])
    }

    private func run(_ arguments: [String]) async throws -> ProcessResult {
        try await ProcessRunner.run(Self.executable, arguments: arguments, timeout: Self.commandTimeout)
    }

    private func runExpectingSuccess(_ arguments: [String]) async throws {
        let result = try await run(arguments)
        guard result.succeeded else {
            throw ServiceError.commandFailed(
                command: "launchctl \(arguments[0])",
                detail: result.failureText
            )
        }
    }
}
