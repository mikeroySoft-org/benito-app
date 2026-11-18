import SwiftUI

struct DiskSpaceRow: View {
    let storage: StorageFacts?
    let isChecking: Bool

    private var state: CheckState {
        guard let free = storage?.freeBytes else { return .couldNotCheck }
        return free < StorageProbe.lowSpaceBytes ? .needsAttention : .ok
    }

    private var finding: String {
        guard let free = storage?.freeBytes else {
            return isChecking ? "Checking…" : "The free space on the disk that holds Benito's data could not be read."
        }
        return free < StorageProbe.lowSpaceBytes
            ? "Only \(Format.bytes(free)) is free on the disk that holds Benito's data. Free up at least 1 GB."
            : "\(Format.bytes(free)) is free on the disk that holds Benito's data."
    }

    var body: some View {
        ReliabilityRow(
            title: "Disk space",
            state: state,
            finding: finding,
            why: "On a full disk the server cannot save what phones send, and backups fail."
        ) {
            Button("Open Storage Settings") {
                SystemSettings.open(SystemSettings.storage)
            }
            .controlSize(.small)
        }
    }
}
