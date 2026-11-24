import Foundation

/// The home Wi-Fi choices as they stand in the form, starting from what `benito.env` says.
struct ConnectionDraft: Equatable, Sendable {
    static let defaultBonjourName = "Benito"

    var wifiEnabled: Bool
    var lanPortText: String
    var bonjourName: String

    init(settings: [String: String]) {
        let port = Self.lanPort(in: settings)
        wifiEnabled = port != nil
        lanPortText = String(port ?? LanPortCheck.defaultPort)
        let name = settings["BENITO_BONJOUR_NAME"]?.trimmingCharacters(in: .whitespaces) ?? ""
        bonjourName = name.isEmpty ? Self.defaultBonjourName : name
    }

    /// The port of the first `BIND_ADDR` entry that is not loopback, else `BENITO_LAN_PORT`
    /// (which `scripts/macos-service.sh` turns into such an entry on its next install).
    static func lanPort(in settings: [String: String]) -> Int? {
        let entries = (settings["BIND_ADDR"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for entry in entries {
            guard let separator = entry.lastIndex(of: ":") else { continue }
            let host = entry[..<separator]
            guard !host.hasPrefix("127."), host != "localhost", host != "[::1]" else { continue }
            if let port = Int(entry[entry.index(after: separator)...]) {
                return port
            }
        }
        return settings["BENITO_LAN_PORT"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}
