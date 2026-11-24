import SwiftUI

/// The per-child glance, which a parent can hide when the menubar is on a shared screen.
struct PopoverGlance: View {
    let children: [ChildGlance]

    @AppStorage("hideBabyDetails") private var hideBabyDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !hideBabyDetails {
                if children.isEmpty {
                    Text("No children on this server yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(children) { child in
                        ChildGlanceView(child: child)
                    }
                }
            }
            Toggle("Hide baby details", isOn: $hideBabyDetails)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)
        }
    }
}
