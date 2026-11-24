import SwiftUI

/// What the running server listens on and the addresses it hands to phones, each testable.
struct ConnectionsCurrentSection: View {
    @Environment(ServerModel.self) private var model

    let connections: ConnectionsModel

    var body: some View {
        if model.isRunning, let status = model.status {
            Section("Listening On") {
                ForEach(status.listeners, id: \.self) { listener in
                    Text(listener)
                        .monospaced()
                        .textSelection(.enabled)
                }
                if let name = status.bonjourName {
                    LabeledContent("Bonjour name", value: name)
                }
            }
            Section {
                if status.advertisedUrls.isEmpty {
                    Text("The server has no address to give phones yet. Turn on Home Wi-Fi or Tailscale below, then choose Apply.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(status.advertisedUrls, id: \.self) { address in
                        ConnectionAddressRow(address: address, connections: connections)
                    }
                    Button("Test All") {
                        Task { await connections.testAll(status.advertisedUrls) }
                    }
                    .disabled(connections.isTesting)
                }
            } header: {
                Text("Addresses for Phones")
            } footer: {
                Text("A test asks the server for its health page through that address, from this Mac. An https Tailscale address can only be tested here while Tailscale is connected on this Mac.")
            }
        } else {
            Section("Addresses for Phones") {
                Text(model.explanation ?? "The server is running, but its status has not loaded yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
