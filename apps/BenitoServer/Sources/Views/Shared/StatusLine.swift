import SwiftUI

/// Colored dot plus the state in words, so color is never the only signal.
struct StatusLine: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(model.indicator.color)
                .accessibilityHidden(true)
            Text(model.statusLine)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
