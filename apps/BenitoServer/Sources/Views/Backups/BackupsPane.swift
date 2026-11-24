import SwiftUI

struct BackupsPane: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        Group {
            if model.isRunning, let status = model.status {
                VStack(alignment: .leading, spacing: 16) {
                    BackupSettingsBox(settings: status.backup)
                    if status.backup.enabled {
                        BackupActionRow()
                        BackupBrowser(snapshots: model.backups?.backups ?? [])
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ServerUnavailableView()
            }
        }
        .task(id: model.backupsEnabled) {
            if model.backupsEnabled {
                await model.refreshBackups()
            }
        }
    }
}
