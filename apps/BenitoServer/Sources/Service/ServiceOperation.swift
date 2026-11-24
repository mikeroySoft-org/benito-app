import Foundation

/// A change to the service that is under way, for the progress the app shows meanwhile.
enum ServiceOperation: Sendable, Equatable {
    case installing
    case updating
    case starting
    case stopping
    case restarting
    case restoring
    case uninstalling
    case applyingSettings

    var title: String {
        switch self {
        case .installing: "Installing the server…"
        case .updating: "Updating the server…"
        case .starting: "Starting the server…"
        case .stopping: "Stopping the server…"
        case .restarting: "Restarting the server…"
        case .restoring: "Restoring the backup…"
        case .uninstalling: "Uninstalling the service…"
        case .applyingSettings: "Applying settings…"
        }
    }

    /// What is happening and what, if anything, the person has to do about it.
    var explanation: String {
        switch self {
        case .installing:
            "Setting up the background service and starting the server. This takes a few seconds."
        case .updating:
            "Taking a backup, then replacing the server program. Phones reconnect by themselves when it is back."
        case .starting:
            "Phones reconnect by themselves once the server answers."
        case .stopping:
            "Phones keep new entries and send them when the server runs again."
        case .restarting, .applyingSettings:
            "The server is restarting. Phones reconnect by themselves after a few seconds."
        case .restoring:
            "The server is stopped while the backup is put in place, and starts again by itself."
        case .uninstalling:
            "Stopping the server and removing the background service. The data stays on this Mac."
        }
    }
}
