import Foundation

/// Why installing, starting, stopping or restoring the server did not work.
enum ServiceError: LocalizedError, Sendable, Equatable {
    /// This copy of the app has no `benito-server` beside its own executable.
    case bundledServerMissing
    /// There is no LaunchAgent for this home, so there is nothing to start, stop or restart.
    case notInstalled
    case installedBinaryMissing(path: String)
    /// Something that launchd does not run for this home already listens on the server's port.
    case portInUse(Int)
    case noFreePort
    case secretNotGenerated
    case commandNotStarted(command: String, detail: String)
    case commandTimedOut(command: String, seconds: Int)
    case commandFailed(command: String, detail: String)
    /// A file or folder step failed; `step` finishes the sentence "Could not …".
    case fileStepFailed(step: String, detail: String)
    case snapshotFailed(String)
    case didNotStart(lastExitStatus: Int?)
    case didNotStop
    case didNotUnload(label: String)
    case restoreFailed(String)
    case restoreOutputUnreadable(String)
    /// The server stayed down after a restore attempt. `restoreFailure` is `nil` when the
    /// restore itself worked.
    case notRestartedAfterRestore(restoreFailure: String?, startFailure: String)
    /// An update failed after the server program had been replaced, and the previous program,
    /// settings and service were put back.
    case updateRolledBack(reason: String, wasRunning: Bool, isServerBack: Bool)

    var errorDescription: String? {
        switch self {
        case .bundledServerMissing:
            "This copy of Benito Server does not include the server program, so it cannot install or update it. Download the app again."
        case .notInstalled:
            "The background service is not installed on this Mac. Install the server first."
        case .installedBinaryMissing(let path):
            "The server program is missing from \(path). Choose Update Server to put it back."
        case .portInUse(let port):
            "Another program on this Mac is already using port \(port), so the server cannot start there. If it is a Benito server started from a terminal, stop it, then try again."
        case .noFreePort:
            "No free network port could be found for the server."
        case .secretNotGenerated:
            "The Mac could not generate a secret for the server. Nothing was installed."
        case .commandNotStarted(let command, let detail):
            "Could not run \(command): \(detail)"
        case .commandTimedOut(let command, let seconds):
            "\(command) did not finish within \(seconds) seconds and was stopped."
        case .commandFailed(let command, let detail):
            "\(command) failed: \(detail)"
        case .fileStepFailed(let step, let detail):
            "Could not \(step): \(detail)"
        case .snapshotFailed(let detail):
            "The backup that is taken before an update failed, so nothing was changed: \(detail)"
        case .didNotStart(let lastExitStatus):
            lastExitStatus.map { "The server did not start: it exited with status \($0). The Logs pane shows why." }
                ?? "The server was started but is not answering yet. The Logs pane shows what it is doing."
        case .didNotStop:
            "The server is still answering after it was asked to stop."
        case .didNotUnload(let label):
            "macOS did not finish stopping the background service (\(label)). Try again in a moment."
        case .restoreFailed(let detail):
            "The backup was not restored, and the data is unchanged: \(detail)"
        case .restoreOutputUnreadable(let output):
            "The restore finished, but its report could not be read: \(output)"
        case .notRestartedAfterRestore(let restoreFailure, let startFailure):
            restoreFailure.map { "The backup was not restored (\($0)), and the server did not start again: \(startFailure)" }
                ?? "The backup was restored, but the server did not start again: \(startFailure)"
        case .updateRolledBack(let reason, let wasRunning, let isServerBack):
            if isServerBack {
                "The update did not work, so the previous server program was put back and is running again. Nothing was lost. What went wrong: \(reason)"
            } else if wasRunning {
                "The update did not work, and the previous server program was put back but is not answering yet. Choose Start, or look at the Logs pane. What went wrong: \(reason)"
            } else {
                "The update did not work, so the previous server program and settings were put back. What went wrong: \(reason)"
            }
        }
    }
}
