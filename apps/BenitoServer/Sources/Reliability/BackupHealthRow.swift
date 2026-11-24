import SwiftUI

struct BackupHealthRow: View {
    @Environment(ServerModel.self) private var model

    let storage: StorageFacts?

    private var backup: ServerStatus.BackupSettings? {
        model.isRunning ? model.status?.backup : nil
    }

    private var state: CheckState {
        guard let backup, let status = model.status else { return .couldNotCheck }
        let healthy = backup.enabled && backup.lastError == nil
            && !backup.isOverdue(serverStartedAt: status.startedAt)
        return healthy ? .ok : .needsAttention
    }

    private var finding: String {
        guard let backup, let status = model.status else {
            return "The server is not answering, so its backups could not be checked."
        }
        guard backup.enabled else {
            return "Automatic backups are off."
        }
        let newest = backup.latest.map { "The newest backup was taken \(Format.relative($0.modifiedAt))." }
            ?? "No backup has been taken yet."
        if let error = backup.lastError {
            return "The last backup failed: \(error) \(newest)"
        }
        if backup.isOverdue(serverStartedAt: status.startedAt) {
            return "Backups are overdue. \(newest)"
        }
        return "Automatic backups are on. \(newest) \(volumeAdvice)"
    }

    private var volumeAdvice: String {
        switch storage?.backupsShareVolume {
        case true?:
            "They are on the same disk as the data, so a failed disk would take both: copy them to another disk, or turn on Time Machine."
        case false?:
            "They are on a different disk from the data."
        default:
            ""
        }
    }

    var body: some View {
        ReliabilityRow(
            title: "Backups",
            state: state,
            finding: finding.trimmingCharacters(in: .whitespaces),
            why: "A backup is the only way back if the database is damaged or this Mac's disk fails."
        ) {
            Button("Show Backups") {
                model.selectedPane = .backups
            }
            .controlSize(.small)
        }
    }
}
