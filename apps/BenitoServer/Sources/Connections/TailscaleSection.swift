import SwiftUI

/// Whether Tailscale is here, connected, and already forwarding HTTPS to this server.
struct TailscaleSection: View {
    let connections: ConnectionsModel

    @State private var isConfirmingServe = false

    var body: some View {
        Section {
            switch connections.tailscale {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Asking Tailscale…")
                        .foregroundStyle(.secondary)
                }
            case .notInstalled:
                Text("Tailscale is not installed on this Mac. It lets phones reach the server from anywhere over a private, encrypted connection.")
                    .foregroundStyle(.secondary)
                if let download = URL(string: TailscaleCLI.downloadAddress) {
                    Link("Get Tailscale", destination: download)
                }
            case .unavailable(let reason):
                Label(reason, systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            case .loaded(let snapshot):
                TailscaleDetails(snapshot: snapshot, connections: connections) {
                    isConfirmingServe = true
                }
            }
            if let error = connections.serveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } header: {
            HStack {
                Text("Tailscale")
                Spacer()
                Button("Check Again") {
                    Task { await connections.refreshNetwork() }
                }
                .controlSize(.small)
                .disabled(connections.isTurningOnServe)
            }
        }
        .confirmationDialog("Turn on Tailscale Serve for Benito?", isPresented: $isConfirmingServe) {
            Button("Turn On") {
                Task { await connections.turnOnServe() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This runs:\n\n\(connections.serveCommandLine)\n\nIt replaces whatever Tailscale Serve currently forwards on port 443 of this Mac. Only devices on your tailnet can use it.")
        }
    }
}
