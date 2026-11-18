import Foundation

enum AutoLoginProbe {
    private static let domain = "com.apple.loginwindow"
    private static let key = "autoLoginUser"

    /// The short name of the user this Mac logs in by itself after starting up, `nil` when
    /// automatic login is off. Read from `/Library/Preferences/com.apple.loginwindow.plist`.
    static func user() -> String? {
        let value = CFPreferencesCopyValue(
            key as CFString,
            domain as CFString,
            kCFPreferencesAnyUser,
            kCFPreferencesCurrentHost
        ) as? String
        let name = value ?? fromFile()
        return name?.isEmpty == false ? name : nil
    }

    private static func fromFile() -> String? {
        let url = URL(fileURLWithPath: "/Library/Preferences/\(domain).plist")
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist[key] as? String
    }
}
