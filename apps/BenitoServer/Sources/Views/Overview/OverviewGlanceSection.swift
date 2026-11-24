import SwiftUI

/// Glance cards. Always shown here; the hide toggle only affects the menubar popover.
struct OverviewGlanceSection: View {
    let children: [ChildGlance]

    var body: some View {
        Section("Right Now") {
            if children.isEmpty {
                Text("No children on this server yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(children) { child in
                    GroupBox {
                        ChildGlanceView(child: child)
                            .padding(4)
                    } label: {
                        Text(child.familyName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
