import SwiftUI

/// The optional plain-HTTP listener for phones on the same network as this Mac.
struct HomeWiFiSection: View {
    @Environment(ServerModel.self) private var model

    @Bindable var connections: ConnectionsModel

    var body: some View {
        Section {
            Toggle("Let phones on your home Wi-Fi connect", isOn: $connections.draft.wifiEnabled)
            if connections.draft.wifiEnabled {
                TextField("Port", text: $connections.draft.lanPortText, prompt: Text(String(LanPortCheck.defaultPort)))
                if case .invalid(let reason) = connections.lanPortCheck {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField(
                    "Name phones see",
                    text: $connections.draft.bonjourName,
                    prompt: Text(ConnectionDraft.defaultBonjourName)
                )
                LabeledContent("This Mac's address") {
                    if let address = connections.lanAddress {
                        Text(address)
                            .monospaced()
                            .textSelection(.enabled)
                    } else {
                        Text("Not connected to Wi-Fi or Ethernet")
                            .foregroundStyle(.secondary)
                    }
                }
                Label(
                    "This connection is plain HTTP: anyone on the same network could read what phones send. Turn it on only for a network you trust, such as your own home Wi-Fi.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let stale = connections.staleLanHost, let current = connections.lanAddress {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Invites still point phones at \(stale), but this Mac's address is now \(current). Phones on your Wi-Fi cannot find the server until this is updated. Updating restarts the server, which takes a few seconds.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Update Address") {
                        Task { await connections.updateAddress(on: model) }
                    }
                    .disabled(!model.isServiceManaged || connections.isApplying)
                }
            }
        } header: {
            Text("Home Wi-Fi")
        } footer: {
            Text("Give this Mac a DHCP reservation in your router so its address does not change. If the address changes, phones on your Wi-Fi lose the server until it is updated here.")
        }
    }
}
