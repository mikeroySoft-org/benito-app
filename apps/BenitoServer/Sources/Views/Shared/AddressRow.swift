import SwiftUI

/// One advertised server URL with a copy button.
struct AddressRow: View {
    let address: String

    var body: some View {
        HStack(spacing: 8) {
            Text(address)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            CopyButton(value: address, title: "Copy \(address)")
        }
    }
}
