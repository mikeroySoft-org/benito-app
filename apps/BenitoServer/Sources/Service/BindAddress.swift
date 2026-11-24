import Foundation

/// `BIND_ADDR`: the server's public listeners as a comma-separated list of `ip:port`.
enum BindAddress {
    /// The loopback listener, plus one on every interface when phones on the home Wi-Fi connect
    /// directly. `scripts/macos-service.sh` composes the same value from `BENITO_LAN_PORT`.
    static func list(loopbackPort: Int, lanPort: Int?) -> String {
        let loopback = "127.0.0.1:\(loopbackPort)"
        return lanPort.map { "\(loopback),0.0.0.0:\($0)" } ?? loopback
    }

    /// The port to use on 127.0.0.1: that of the first loopback listener, else of the first
    /// listener at all (one bound to every interface answers on loopback too).
    static func loopbackPort(in list: String) -> Int? {
        let listeners = list.split(separator: ",").compactMap(listener)
        let loopback = listeners.first { $0.host.hasPrefix("127.") || $0.host == "[::1]" }
        return (loopback ?? listeners.first)?.port
    }

    /// A usable TCP port number, or `nil`.
    static func parsePort(_ text: String) -> Int? {
        guard let port = Int(text.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else {
            return nil
        }
        return port
    }

    private static func listener(_ entry: Substring) -> (host: String, port: Int)? {
        let text = entry.trimmingCharacters(in: .whitespaces)
        guard let colon = text.lastIndex(of: ":"),
              let port = parsePort(String(text[text.index(after: colon)...]))
        else { return nil }
        return (String(text[..<colon]), port)
    }
}
