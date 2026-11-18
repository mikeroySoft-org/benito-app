import Foundation

/// The macOS application firewall's global state.
enum FirewallState: Equatable, Sendable {
    case off
    /// On: macOS asks before an app may accept incoming connections.
    case on
    /// On and refusing every incoming connection.
    case blockingAll
}
