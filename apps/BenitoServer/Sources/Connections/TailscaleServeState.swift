import Foundation

/// Whether Tailscale Serve hands HTTPS on port 443 to this server.
enum TailscaleServeState: Equatable, Sendable {
    /// Tailscale could not be asked, so addresses already saved are left alone.
    case unknown
    case notForwarding
    /// `host` is this Mac's name on the tailnet, without a scheme or port.
    case forwarding(host: String)
}
