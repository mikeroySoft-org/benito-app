import SwiftUI

struct BackupTable: View {
    let snapshots: [BackupSnapshot]
    @Binding var selection: Set<BackupSnapshot.ID>
    let canRestore: Bool
    /// Asks before restoring; the table itself changes nothing.
    let restore: (BackupSnapshot) -> Void

    var body: some View {
        Table(snapshots, selection: $selection) {
            TableColumn("Name", value: \.name)
            TableColumn("Date") { snapshot in
                Text(Format.dateTime(snapshot.modifiedAt))
            }
            .width(min: 120, ideal: 170)
            TableColumn("Size") { snapshot in
                Text(Format.bytes(snapshot.sizeBytes))
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: BackupSnapshot.ID.self) { paths in
            if let path = paths.first {
                Button("Reveal in Finder") {
                    Desktop.revealInFinder(path: path)
                }
                if paths.count == 1, let snapshot = snapshots.first(where: { $0.id == path }) {
                    Button("Restore…") {
                        restore(snapshot)
                    }
                    .disabled(!canRestore)
                }
            }
        } primaryAction: { paths in
            if let path = paths.first {
                Desktop.revealInFinder(path: path)
            }
        }
        .overlay {
            if snapshots.isEmpty {
                ContentUnavailableView(
                    "No Snapshots Yet",
                    systemImage: "externaldrive",
                    description: Text("Choose Back Up Now, or wait for the next scheduled backup.")
                )
            }
        }
    }
}
