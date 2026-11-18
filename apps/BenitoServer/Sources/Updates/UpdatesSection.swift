import SwiftUI

/// App version and update controls; a `Section` for a grouped `Form`.
struct UpdatesSection: View {
    @Environment(UpdaterController.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Section("Updates") {
            LabeledContent("App version", value: updater.currentVersion)
            Toggle("Automatically Check for Updates", isOn: $updater.automaticallyChecksForUpdates)
                .disabled(!updater.isConfigured)
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
            if !updater.isConfigured {
                Text("This copy of Benito Server was built without an update key, so it cannot update itself. If you built it from source, update with git and build again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
