import Foundation

/// Where the family's data lives. Absent key = a family server (everyone who set Benito up
/// before on-device mode existed), so upgrading changes nothing for them.
public enum BenitoMode: String, Sendable {
    case server
    case onDevice = "local"

    public static let defaultsKey = "benito.mode"

    public static func current(_ defaults: UserDefaults = .standard) -> BenitoMode {
        defaults.string(forKey: defaultsKey).flatMap(BenitoMode.init(rawValue:)) ?? .server
    }

    public static func set(_ mode: BenitoMode, _ defaults: UserDefaults = .standard) {
        switch mode {
        case .server: defaults.removeObject(forKey: defaultsKey)
        case .onDevice: defaults.set(mode.rawValue, forKey: defaultsKey)
        }
    }
}

public extension Notification.Name {
    /// Posted after a Siri shortcut or widget changes the on-device store, so the app reloads.
    static let benitoLocalStoreDidChange = Notification.Name("benito.localStoreDidChange")
}
