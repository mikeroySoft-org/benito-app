import AppKit
import SwiftUI

struct PopoverActions: View {
    @Environment(ServerModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Back Up Now") {
                    Task { await model.backUpNow() }
                }
                .disabled(!model.backupsEnabled || model.isBackingUp)
                Button("Invite…") {
                    model.showInvite()
                    openMainWindow()
                }
                .disabled(!model.isRunning)
                if model.isBackingUp {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Backing up")
                }
            }
            if model.isRunning, !model.backupsEnabled {
                Text("Backups are off: the server was started without BENITO_BACKUP_DIR.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let result = model.lastBackupResult {
                Text("Saved \(result.name), \(Format.bytes(result.sizeBytes)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isRunning, model.canControlService {
                PopoverServiceControls()
            }
            HStack {
                Button("Open Benito Server") {
                    openMainWindow()
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private func openMainWindow() {
        openWindow(id: ServerModel.mainWindowID)
        NSApplication.shared.activate()
    }
}
