import SwiftUI

struct OverviewDatabaseSection: View {
    let status: ServerStatus

    var body: some View {
        Section("Database") {
            LabeledContent("File") {
                Text(status.database.path)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            LabeledContent("Size", value: Format.bytes(status.database.sizeBytes))
            LabeledContent("Write-ahead log", value: Format.bytes(status.database.walBytes))
            LabeledContent("Users", value: status.counts.users.formatted())
            LabeledContent("Families", value: status.counts.families.formatted())
            LabeledContent("Children", value: status.counts.children.formatted())
            LabeledContent("Events", value: status.counts.events.formatted())
            LabeledContent("Devices", value: status.counts.devices.formatted())
        }
    }
}
