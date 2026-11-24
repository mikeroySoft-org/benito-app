import Foundation

/// Runs a command-line tool without blocking the caller's actor, and stops it when it takes too
/// long or the calling task is cancelled.
enum ExternalCommand {
    /// Throws only when the tool could not be started; a failing or slow tool is in the output.
    static func run(
        _ executable: URL,
        arguments: [String] = [],
        timeout: Duration
    ) async throws -> CommandOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let (exits, exitContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            exitContinuation.yield(finished.terminationStatus)
            exitContinuation.finish()
        }
        try process.run()

        // Both pipes are drained while the tool runs: one that fills up would block it forever.
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        async let output = drain(outputHandle)
        async let errors = drain(errorHandle)

        let status: Int32? = await withTaskGroup(of: Int32?.self) { group in
            group.addTask {
                for await status in exits {
                    return status
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        // SIGKILL, because a tool that ignored SIGTERM would keep the pipes open and this call
        // would never return.
        if status == nil, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        return CommandOutput(
            exitStatus: status,
            standardOutput: String(decoding: await output, as: UTF8.self),
            standardError: String(decoding: await errors, as: UTF8.self)
        )
    }

    private static func drain(_ handle: FileHandle) async -> Data {
        await Task.detached {
            (try? handle.readToEnd()) ?? Data()
        }.value
    }
}
