import SwiftUI

struct OverviewPane: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        if model.isRunning, let status = model.status {
            Form {
                if status.counts.families == 0 {
                    OverviewGettingStartedSection(status: status)
                }
                OverviewServerSection(status: status)
                OverviewServiceSection()
                OverviewAddressesSection(status: status)
                OverviewDatabaseSection(status: status)
                OverviewActivitySection(status: status)
                OverviewGlanceSection(children: model.glance)
                UpdatesSection()
            }
            .formStyle(.grouped)
        } else if model.isServiceManaged {
            // A stopped service still has controls worth showing: Start, Update, Uninstall.
            Form {
                OverviewUnavailableSection()
                OverviewServiceSection()
                UpdatesSection()
            }
            .formStyle(.grouped)
        } else {
            ServerUnavailableView()
        }
    }
}
