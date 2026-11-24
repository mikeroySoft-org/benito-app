import SwiftUI

struct OverviewActivitySection: View {
    let status: ServerStatus

    var body: some View {
        Section("Activity") {
            LabeledContent("Last activity") {
                if let lastEventAt = status.lastEventAt {
                    RelativeTimeText(date: lastEventAt)
                } else {
                    Text("Nothing logged yet")
                }
            }
            LabeledContent("Phones connected", value: status.syncConnections.formatted())
            LabeledContent("Push notifications (APNs)") {
                Label(
                    status.apnsConfigured ? "Configured" : "Not configured",
                    systemImage: status.apnsConfigured ? "checkmark.circle" : "minus.circle"
                )
            }
        }
    }
}
