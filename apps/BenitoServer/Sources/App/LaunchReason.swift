import AppKit

/// How this launch came about, read from the Apple event that started the app.
@MainActor
enum LaunchReason {
    /// True when macOS opened the app as a login item, where it should stay in the menu bar
    /// instead of putting a window on screen.
    static var isLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication
        else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
