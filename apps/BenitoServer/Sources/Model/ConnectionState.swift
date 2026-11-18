import Foundation

enum ConnectionState: Equatable, Sendable {
    /// Before the first check has finished.
    case checking
    /// The admin API answers.
    case running
    /// An older server answers on port 8080 but has no admin API.
    case legacy(version: String?)
    /// A server belongs here (there is a service, or data) but nothing answers.
    case stopped
    /// No service, no data, and nothing answers.
    case notInstalled

    var title: String {
        switch self {
        case .checking: "Checking…"
        case .running: "Running"
        case .legacy(let version):
            version.map { "Running version \($0), update needed" } ?? "Running, update needed"
        case .stopped: "Stopped"
        case .notInstalled: "Not installed"
        }
    }

    /// Plain-language explanation shown in place of server details: what is going on, and what
    /// the person can do about it now. `nil` while running.
    func explanation(service: ServiceInfo) -> String? {
        switch self {
        case .running:
            nil
        case .checking:
            "Looking for a Benito server on this Mac."
        case .legacy:
            service.isInstalled
                ? "An older Benito server is running on this Mac, and phones can sync with it. Update it to see backups, people and devices here."
                : "A Benito server that this app did not start is running on this Mac without admin access. Stop it where it was started, then install the server from this app."
        case .stopped:
            Self.stoppedExplanation(service: service)
        case .notInstalled:
            "There is no Benito server on this Mac yet. Install it so the family's phones have something to sync with."
        }
    }

    private static func stoppedExplanation(service: ServiceInfo) -> String {
        if service.isLoaded {
            "The Benito server is not answering, so phones cannot sync. It may still be starting. If this does not change, the Logs pane shows what went wrong."
        } else if service.isInstalled {
            "The Benito server is stopped, so phones cannot sync. They keep new entries and send them once it runs again."
        } else {
            "The Benito server is not running, and no background service is installed to start it. Installing the service keeps the data that is already here."
        }
    }
}
