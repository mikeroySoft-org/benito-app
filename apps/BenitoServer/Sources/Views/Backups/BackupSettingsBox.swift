import SwiftUI

struct BackupSettingsBox: View {
    let settings: ServerStatus.BackupSettings

    private var schedule: String {
        settings.intervalHours > 0
            ? "Every \(Format.hours(settings.intervalHours))"
            : "Only when you choose Back Up Now"
    }

    var body: some View {
        GroupBox {
            Form {
                LabeledContent("Automatic backups", value: settings.enabled ? "On" : "Off")
                if settings.enabled {
                    if let dir = settings.dir {
                        LabeledContent("Folder") {
                            HStack {
                                Text(dir)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Button("Reveal in Finder") {
                                    Desktop.revealInFinder(path: dir)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    LabeledContent("Keeps", value: "The newest \(settings.keep) snapshots")
                    LabeledContent("Schedule", value: schedule)
                    LabeledContent("Newest snapshot") {
                        if let latest = settings.latest {
                            RelativeTimeText(date: latest.modifiedAt)
                        } else {
                            Text("None yet")
                        }
                    }
                    if let lastError = settings.lastError {
                        LabeledContent("Last error") {
                            Text(lastError)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Text("The server was started without BENITO_BACKUP_DIR, so it takes no backups. Set a backup folder in the server's configuration and restart it to turn them on.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.columns)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
