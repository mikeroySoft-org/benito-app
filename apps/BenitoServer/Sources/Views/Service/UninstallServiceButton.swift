import SwiftUI

struct UninstallServiceButton: View {
    @Environment(ServerModel.self) private var model

    @State private var isConfirming = false

    /// Everything uninstalling leaves behind, with where it is.
    private var message: String {
        let home = model.home
        let backups = model.settings["BENITO_BACKUP_DIR"] ?? home.backupDirectory.posixPath
        return """
            The server stops and no longer starts when you log in, so phones cannot sync until \
            it is installed again. Nothing is deleted. These stay on this Mac:

            Database: \(Self.abbreviated(home.databaseFile.posixPath))
            Settings: \(Self.abbreviated(home.envFile.posixPath))
            Backups: \(Self.abbreviated(backups))
            Logs: \(Self.abbreviated(home.logFile.deletingLastPathComponent().posixPath))
            Server program: \(Self.abbreviated(home.installedBinary.posixPath))
            """
    }

    var body: some View {
        Button("Uninstall Service…") {
            isConfirming = true
        }
        .confirmationDialog("Uninstall the background service?", isPresented: $isConfirming) {
            Button("Uninstall Service", role: .destructive, action: uninstall)
        } message: {
            Text(message)
        }
    }

    private func uninstall() {
        Task { await model.uninstallServer() }
    }

    private static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
