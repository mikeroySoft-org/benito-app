import SwiftUI

/// The snapshot list, with Restore for the selected row behind a confirmation.
struct BackupBrowser: View {
    @Environment(ServerModel.self) private var model

    let snapshots: [BackupSnapshot]

    @State private var selection = Set<BackupSnapshot.ID>()
    @State private var restoreCandidate: BackupSnapshot?
    @State private var isConfirmingRestore = false

    private var selectedSnapshot: BackupSnapshot? {
        guard selection.count == 1, let path = selection.first else { return nil }
        return snapshots.first { $0.id == path }
    }

    /// Restoring stops and starts the server through launchd, so the app has to manage it.
    private var canRestore: Bool {
        model.canControlService && !model.isBusy
    }

    private var confirmationTitle: String {
        restoreCandidate.map { "Restore \($0.name)?" } ?? "Restore this backup?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BackupTable(
                snapshots: snapshots,
                selection: $selection,
                canRestore: canRestore,
                restore: confirmRestore
            )
            BackupRestoreRow(snapshot: selectedSnapshot, canRestore: canRestore, restore: confirmRestore)
        }
        .confirmationDialog(confirmationTitle, isPresented: $isConfirmingRestore, presenting: restoreCandidate) { snapshot in
            Button("Restore", role: .destructive) {
                restore(snapshot)
            }
        } message: { snapshot in
            Text("This puts the server back to how it was on \(Format.dateTime(snapshot.modifiedAt)) and replaces everything since then: entries, and also people, phones and password changes. Anyone who joined after that date needs a new invite. The data as it is now is saved first as a pre-restore file in the backup folder, and the server stops for a few seconds. Phones keep the entries they already have and do not send them again, so a phone can show entries the server and other phones no longer have.")
        }
    }

    private func confirmRestore(_ snapshot: BackupSnapshot) {
        restoreCandidate = snapshot
        isConfirmingRestore = true
    }

    private func restore(_ snapshot: BackupSnapshot) {
        Task { await model.restoreBackup(snapshot) }
    }
}
