import SwiftUI

/// One line of a child's glance: icon, what happened, and a trailing time or clock.
struct GlanceRow<Trailing: View>: View {
    let systemImage: String
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(text, systemImage: systemImage)
            Spacer(minLength: 8)
            trailing
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
