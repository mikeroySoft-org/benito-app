import SwiftUI

/// The rows of the Tailscale section once Tailscale has answered.
struct TailscaleDetails: View {
    @Environment(ServerModel.self) private var model

    let snapshot: TailscaleSnapshot
    let connections: ConnectionsModel
    let onTurnOn: () -> Void

    var body: some View {
        LabeledContent("Status") {
            if snapshot.isConnected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Not connected (\(snapshot.backendState))", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        if let name = snapshot.name {
            LabeledContent("This Mac's name") {
                Text(name)
                    .textSelection(.enabled)
            }
        }
        switch snapshot.serve {
        case .forwarding(let host):
            LabeledContent("Serve") {
                Label("Forwards https://\(host) to this server", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
            }
            if !snapshot.isConnected {
                Text("Phones away from home cannot reach the server until Tailscale is connected on this Mac.")
                    .foregroundStyle(.secondary)
            }
        case .notForwarding:
            if let other = snapshot.otherTarget {
                LabeledContent("Serve", value: "Forwards port 443 to \(other), not to this server")
            } else {
                LabeledContent("Serve", value: "Not forwarding to this server")
            }
            turnOnRow
        case .unknown:
            LabeledContent("Serve", value: "Tailscale did not say what it is forwarding")
            turnOnRow
        }
    }

    @ViewBuilder
    private var turnOnRow: some View {
        if model.home.isDefault {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button("Turn On…", action: onTurnOn)
                        .disabled(!snapshot.isConnected || connections.isTurningOnServe)
                    if connections.isTurningOnServe {
                        ProgressView()
                            .controlSize(.small)
                        Text("Asking Tailscale…")
                            .foregroundStyle(.secondary)
                    }
                }
                Text(snapshot.isConnected
                    ? "Gives phones a private https address that works away from home. After it is on, choose Apply so invites include that address."
                    : "Connect Tailscale on this Mac first, then choose Check Again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            // Tailscale Serve is one setting for the whole Mac. From a test folder it would
            // point the family's https address at the test server.
            Text("Turning on Tailscale Serve is not offered for a test folder, because it would send this Mac's Tailscale address to the test server instead of the real one.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
