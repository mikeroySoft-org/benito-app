import SwiftUI

struct LogsToolbar: View {
    @Binding var filter: String
    let summary: String
    let canReveal: Bool
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField("Filter", text: $filter, prompt: Text("Filter lines"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Reveal in Finder", action: reveal)
                .disabled(!canReveal)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
