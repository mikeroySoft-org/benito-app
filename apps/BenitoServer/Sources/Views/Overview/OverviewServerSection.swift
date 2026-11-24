import SwiftUI

struct OverviewServerSection: View {
    let status: ServerStatus

    var body: some View {
        Section("Server") {
            LabeledContent("Status") {
                StatusLine()
            }
            LabeledContent("Version", value: status.version)
            LabeledContent("Uptime", value: Format.uptime(status.uptimeSeconds))
            LabeledContent("Started", value: Format.dateTime(status.startedAt))
            LabeledContent("Server ID") {
                Text(status.serverId)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}
