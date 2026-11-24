import SwiftUI

/// How phones reach this Mac: what the server listens on today, home Wi-Fi, and Tailscale.
struct ConnectionsPane: View {
    @Environment(ServerModel.self) private var model
    @State private var connections = ConnectionsModel()

    var body: some View {
        Form {
            ConnectionsCurrentSection(connections: connections)
            HomeWiFiSection(connections: connections)
            TailscaleSection(connections: connections)
            ConnectionsApplySection(connections: connections)
        }
        .formStyle(.grouped)
        .task(id: model.settings) {
            connections.adopt(settings: model.settings, publicPort: model.publicPort)
            await connections.refreshNetwork()
        }
        .onChange(of: connections.draft) {
            connections.validateLanPort()
        }
    }
}
