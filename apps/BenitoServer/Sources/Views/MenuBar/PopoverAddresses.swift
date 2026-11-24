import SwiftUI

struct PopoverAddresses: View {
    let addresses: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Addresses for phones")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if addresses.isEmpty {
                Text("This Mac has no address for phones yet.")
                    .font(.callout)
            } else {
                ForEach(addresses, id: \.self) { address in
                    AddressRow(address: address)
                        .font(.callout)
                }
            }
        }
    }
}
