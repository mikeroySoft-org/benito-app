import SwiftUI

/// Shown only while the server accepts phones over home Wi-Fi; loopback is never filtered.
struct FirewallRow: View {
    let firewall: Probed<FirewallState>

    private var state: CheckState {
        switch firewall {
        case .value(.off): .ok
        case .value(.on), .value(.blockingAll): .needsAttention
        case .pending, .unavailable: .couldNotCheck
        }
    }

    private var finding: String {
        switch firewall {
        case .pending:
            "Checking…"
        case .value(.off):
            "The macOS firewall is off, so it does not stand between phones and the server."
        case .value(.on):
            "The macOS firewall is on. macOS may ask whether benito-server may accept incoming connections: choose Allow."
        case .value(.blockingAll):
            "The macOS firewall blocks all incoming connections, so phones on your Wi-Fi cannot reach the server. Turn that option off in Network, Firewall, Options."
        case .unavailable(let reason):
            reason
        }
    }

    var body: some View {
        ReliabilityRow(
            title: "Firewall",
            state: state,
            finding: finding,
            why: "Phones on your home Wi-Fi connect straight to this Mac, and the firewall decides whether they get through."
        ) {
            EmptyView()
        }
    }
}
