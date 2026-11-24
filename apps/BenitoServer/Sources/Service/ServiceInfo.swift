import Foundation

/// The LaunchAgent that runs the server for a home, as launchd and the disk describe it.
struct ServiceInfo: Sendable, Equatable {
    /// The LaunchAgent plist is in place, so launchd starts the server at login.
    var isInstalled = false
    /// launchd has the job right now. False after Stop, until Start or the next login.
    var isLoaded = false
    var pid: Int?
    /// Exit status of the server's previous process, when launchd has seen one end.
    var lastExitStatus: Int?
    /// The installed server program is the one inside this app. True as well when the app has
    /// no server inside it, because then there is nothing to update to.
    var isBinaryCurrent = true
    var bundledVersion: String?

    var stateTitle: String {
        if !isLoaded {
            isInstalled ? "Stopped" : "Not installed"
        } else if pid != nil {
            "Running"
        } else if let lastExitStatus, lastExitStatus != 0 {
            "Keeps stopping (exit status \(lastExitStatus))"
        } else {
            "Starting"
        }
    }
}
