import SwiftUI

/// One address phones are given: copy it, test it, and see how the last test went.
struct ConnectionAddressRow: View {
    let address: String
    let connections: ConnectionsModel

    private var result: ReachabilityResult? { connections.tests[address] }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(address)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                switch result {
                case .testing:
                    Text("Testing…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .reachable(let version):
                    Label(
                        version.map { "Reachable, Benito server \($0) answered" } ?? "Reachable",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.green)
                case .notReachable(let reason):
                    Label("Not reachable: \(reason)", systemImage: "xmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case nil:
                    EmptyView()
                }
            }
            Spacer(minLength: 8)
            Button("Test") {
                Task { await connections.test(address) }
            }
            .controlSize(.small)
            .disabled(result == .testing)
            .accessibilityLabel("Test \(address)")
            CopyButton(value: address, title: "Copy \(address)")
        }
    }
}
