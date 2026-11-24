import Foundation

/// What Tailscale on this Mac said the last time it was asked.
struct TailscaleSnapshot: Equatable, Sendable {
    var isConnected: Bool
    /// Tailscale's own word for its state, for example `Stopped` or `NeedsLogin`.
    var backendState: String
    /// This Mac's name on the tailnet.
    var name: String?
    var serve: TailscaleServeState
    /// What Serve forwards port 443 to when that is not this server.
    var otherTarget: String?
}
