import SwiftUI

/// A spinner beside the name of the change to the service that is under way.
struct ServiceProgressView: View {
    let operation: ServiceOperation

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(operation.title)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
