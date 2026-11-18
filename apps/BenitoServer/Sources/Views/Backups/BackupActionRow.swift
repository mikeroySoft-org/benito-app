import SwiftUI

/// Back Up Now with progress and the result of the last manual snapshot.
struct BackupActionRow: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Button("Back Up Now") {
                Task { await model.backUpNow() }
            }
            .disabled(model.isBackingUp)
            if model.isBackingUp {
                ProgressView()
                    .controlSize(.small)
                Text("Taking a snapshot…")
                    .foregroundStyle(.secondary)
            } else if let result = model.lastBackupResult {
                Label(
                    "\(result.name), \(Format.bytes(result.sizeBytes)), \(result.users) users, \(result.events) events",
                    systemImage: "checkmark.circle"
                )
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }
}
