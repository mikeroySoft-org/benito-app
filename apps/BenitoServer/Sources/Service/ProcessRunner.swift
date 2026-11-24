import Foundation

/// Runs a command-line tool to completion without blocking the caller, and collects what it
/// printed.
enum ProcessRunner {
    /// How long a child gets to exit after SIGTERM before it is killed.
    private static let terminationGrace: Duration = .seconds(2)

    /// - Parameters:
    ///   - environment: The child's whole environment. `nil` passes on this app's.
    ///   - timeout: After this long the child is terminated and the call throws.
    /// - Returns: The exit status and output, whether or not the tool reported success.
    static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> ProcessResult {
        let command = ([executable.lastPathComponent] + arguments.prefix(1)).joined(separator: " ")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice

        // Both pipes are drained while the child runs: a child that fills one (64 KB) would
        // otherwise block forever on its next write.
        let (stdoutChunks, stdoutEnd) = AsyncStream.makeStream(of: Data.self)
        let (stderrChunks, stderrEnd) = AsyncStream.makeStream(of: Data.self)
        let stdoutPipe = pipe(feeding: stdoutEnd)
        let stderrPipe = pipe(feeding: stderrEnd)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }

        // Sleeps through the launch below, so the child exists by the time this looks at it.
        // Returns whether it had to signal the child.
        let watchdog = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false
            }
            let signalled = process.isRunning
            if signalled {
                process.terminate()
            }
            do {
                try await Task.sleep(for: Self.terminationGrace)
            } catch {
                return signalled
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            // A descendant of the child can still hold the pipes open; stop waiting for it.
            stdoutEnd.finish()
            stderrEnd.finish()
            return signalled
        }

        async let stdout = Self.collect(stdoutChunks)
        async let stderr = Self.collect(stderrChunks)

        let exitCode: Int32
        do {
            exitCode = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    // A process that never launched never calls its termination handler.
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            watchdog.cancel()
            stdoutEnd.finish()
            stderrEnd.finish()
            throw ServiceError.commandNotStarted(command: command, detail: error.localizedDescription)
        }

        let output = await stdout
        let errors = await stderr
        watchdog.cancel()
        if await watchdog.value {
            throw ServiceError.commandTimedOut(command: command, seconds: Int(timeout.components.seconds))
        }
        return ProcessResult(exitCode: exitCode, stdout: output, stderr: errors)
    }

    /// A pipe whose read end hands every chunk to `continuation` and finishes it at end of file.
    private static func pipe(feeding continuation: AsyncStream<Data>.Continuation) -> Pipe {
        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(chunk)
            }
        }
        return pipe
    }

    private static func collect(_ chunks: AsyncStream<Data>) async -> String {
        var data = Data()
        for await chunk in chunks {
            data.append(chunk)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
