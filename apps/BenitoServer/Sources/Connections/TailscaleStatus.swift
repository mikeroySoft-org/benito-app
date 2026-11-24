import Foundation

/// The parts of `tailscale status --json` this app reads.
struct TailscaleStatus: Decodable, Sendable, Equatable {
    var backendState: String
    var node: Node?

    struct Node: Decodable, Sendable, Equatable {
        var dnsName: String?

        enum CodingKeys: String, CodingKey {
            case dnsName = "DNSName"
        }
    }

    enum CodingKeys: String, CodingKey {
        case backendState = "BackendState"
        case node = "Self"
    }

    var isConnected: Bool { backendState == "Running" }

    /// This Mac's MagicDNS name. Tailscale writes it fully qualified, with a trailing dot.
    var name: String? {
        guard var name = node?.dnsName else { return nil }
        while name.hasSuffix(".") {
            name.removeLast()
        }
        return name.isEmpty ? nil : name
    }
}
