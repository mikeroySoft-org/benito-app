import SwiftUI

/// The model's last error, dismissible. Shows nothing when there is none.
struct ErrorBanner: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        if let message = model.lastError {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Dismiss", systemImage: "xmark") {
                    model.lastError = nil
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(10)
            .background(.quaternary, in: .rect(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Error")
        }
    }
}
