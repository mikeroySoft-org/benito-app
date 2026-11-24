import SwiftUI

/// Will the server be there at 3 a.m.: the settings of this Mac that decide it.
struct ReliabilityPane: View {
    @Environment(ServerModel.self) private var model
    @State private var reliability = ReliabilityModel()

    var body: some View {
        Form {
            Section("This Mac") {
                LoginItemRow(reliability: reliability)
                AutoLoginRow(user: reliability.autoLoginUser)
                SleepRow(minutes: reliability.sleepMinutes)
                if model.hasLanListener {
                    FirewallRow(firewall: reliability.firewall)
                }
            }
            Section("Your Data") {
                BackupHealthRow(storage: reliability.storage)
                DiskSpaceRow(storage: reliability.storage, isChecking: reliability.isRefreshing)
            }
            Section("When Something Goes Wrong") {
                NotificationsRow(reliability: reliability)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await reliability.refresh(server: model) }
                }
                .disabled(reliability.isRefreshing)
                .help("Check this Mac again")
            }
        }
        .task {
            await reliability.refresh(server: model)
        }
    }
}
