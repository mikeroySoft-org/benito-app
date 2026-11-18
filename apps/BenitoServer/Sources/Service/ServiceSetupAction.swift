import Foundation

/// The one step that gets a server that is not answering, or not manageable, going.
enum ServiceSetupAction: Sendable, Equatable {
    case install
    case update
    case start

    var buttonTitle: String {
        switch self {
        case .install: "Install Server"
        case .update: "Update Server"
        case .start: "Start Server"
        }
    }

    /// What pressing the button does, so nobody has to guess before trying it.
    var details: String {
        switch self {
        case .install:
            "Installs a background service that starts when you log in, creates the database folder, and turns on daily backups."
        case .update:
            "Takes a backup first, then replaces the server program. All data and settings are kept, and phones reconnect by themselves after a few seconds."
        case .start:
            "Starts the background service. Phones reconnect by themselves after a few seconds."
        }
    }
}
