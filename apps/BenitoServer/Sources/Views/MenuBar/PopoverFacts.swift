import SwiftUI

struct PopoverFacts: View {
    let status: ServerStatus

    var body: some View {
        VStack(spacing: 4) {
            FactRow("Version", value: status.version)
            FactRow("Uptime", value: Format.uptime(status.uptimeSeconds))
            FactRow("Phones connected", value: status.syncConnections.formatted())
            FactRow(label: "Newest backup") {
                if !status.backup.enabled {
                    Text("Backups are off")
                } else if let latest = status.backup.latest {
                    RelativeTimeText(date: latest.modifiedAt)
                } else {
                    Text("None yet")
                }
            }
        }
    }
}
