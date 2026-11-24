import SwiftUI

/// Restore for the selected snapshot, then progress and the outcome of the last restore.
struct BackupRestoreRow: View {
    @Environment(ServerModel.self) private var model

    let snapshot: BackupSnapshot?
    let canRestore: Bool
    let restore: (BackupSnapshot) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("Restore…", action: restoreSelected)
                .disabled(snapshot == nil || !canRestore)
            if model.operation == .restoring {
                ServiceProgressView(operation: .restoring)
            } else if !model.canControlService {
                Text("Restoring needs the server to run as this app's background service.")
                    .foregroundStyle(.secondary)
            } else if let result = model.lastRestoreResult {
                BackupRestoreOutcome(result: result)
            } else if snapshot == nil {
                Text("Select a snapshot to restore it.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func restoreSelected() {
        if let snapshot {
            restore(snapshot)
        }
    }
}
