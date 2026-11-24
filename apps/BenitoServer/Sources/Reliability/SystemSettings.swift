import AppKit

/// Opens a pane of System Settings by its extension identifier.
@MainActor
enum SystemSettings {
    static let usersAndGroups = "com.apple.Users-Groups-Settings.extension"
    static let energy = "com.apple.Energy-Settings.extension"
    static let notifications = "com.apple.Notifications-Settings.extension"
    static let storage = "com.apple.settings.Storage"

    static func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
