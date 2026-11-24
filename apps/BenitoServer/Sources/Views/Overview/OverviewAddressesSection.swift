import SwiftUI

struct OverviewAddressesSection: View {
    let status: ServerStatus

    var body: some View {
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
        Section("Addresses for Phones") {
            if status.advertisedUrls.isEmpty {
                Text("Phones need an address to reach this Mac, and the server is not advertising one yet. Set one up in Connections.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(status.advertisedUrls, id: \.self) { address in
                    AddressRow(address: address)
                }
            }
        }
    }
}
