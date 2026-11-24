import SwiftUI

/// What the last restore put back, and where the data from before it went.
struct BackupRestoreOutcome: View {
    let result: RestoreResult

    private var restoredName: String {
        URL(fileURLWithPath: result.restoredFrom).lastPathComponent
    }

    private var summary: String {
        let restored = "Restored \(restoredName): \(result.users) users, \(result.events) events."
        guard let preRestore = result.preRestore else {
            return "\(restored) There was no earlier data to save."
        }
        return "\(restored) The data from before is saved as \(URL(fileURLWithPath: preRestore).lastPathComponent)."
    }

    var body: some View {
        HStack(spacing: 8) {
            Label(summary, systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let preRestore = result.preRestore {
                Button("Reveal in Finder") {
                    Desktop.revealInFinder(path: preRestore)
                }
                .controlSize(.small)
            }
        }
    }
}
