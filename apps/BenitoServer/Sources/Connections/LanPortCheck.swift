import Foundation

/// Whether the text in the home Wi-Fi port field can be used as the LAN listener's port.
enum LanPortCheck: Equatable, Sendable {
    case valid(Int)
    case invalid(String)

    static let defaultPort = 8081
    static let allowedPorts = 1024...65535

    /// `currentLanPort` is the port this server's LAN listener already holds; it is not free, and
    /// that is fine.
    static func evaluate(
        _ text: String,
        loopbackPort: Int,
        currentLanPort: Int?,
        isFree: (Int) -> Bool = PortProbe.isFree
    ) -> LanPortCheck {
        guard let port = Int(text.trimmingCharacters(in: .whitespaces)) else {
            return .invalid("Enter a port number, for example \(defaultPort).")
        }
        guard allowedPorts.contains(port) else {
            return .invalid("Choose a port between \(allowedPorts.lowerBound) and \(allowedPorts.upperBound).")
        }
        guard port != loopbackPort else {
            return .invalid("Port \(port) is the one the server already uses on this Mac itself. Choose a different one.")
        }
        guard port == currentLanPort || isFree(port) else {
            return .invalid("Another app on this Mac is using port \(port). Choose a different one.")
        }
        return .valid(port)
    }
}
