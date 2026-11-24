import SwiftUI

/// The LaunchAgent that keeps the server running: its state, the server program it runs, and
/// the controls for it.
struct OverviewServiceSection: View {
    @Environment(ServerModel.self) private var model

    private var processID: Int? {
        model.serviceInfo.pid ?? model.status?.pid
    }

    /// The version that is installed, and how it relates to the one inside this app.
    private var program: String {
        let service = model.serviceInfo
        let installed = model.status?.version
        if model.isUpdateAvailable {
            return switch (installed, service.bundledVersion) {
            case let (installed?, bundled?) where installed != bundled:
                "Version \(installed). Version \(bundled) is ready to install."
            case let (installed?, _):
                "Version \(installed). A newer build is ready to install."
            case (nil, let bundled?):
                "Version \(bundled) is ready to install."
            case (nil, nil):
                "An update is ready to install."
            }
        }
        guard let version = installed ?? (service.isBinaryCurrent ? service.bundledVersion : nil) else {
            return "Version unknown while the server is not answering"
        }
        guard let bundledVersion = service.bundledVersion else { return "Version \(version)" }
        return service.isBinaryCurrent
            ? "Version \(version), up to date"
            : "Version \(version), newer than the one in this app (\(bundledVersion))"
    }

    var body: some View {
        Section("Background Service") {
            if model.isRunningOutsideApp {
                ServiceOutsideAppNotice()
                if let processID {
                    LabeledContent("Process ID", value: String(processID))
                }
            } else {
                LabeledContent("State", value: model.serviceInfo.stateTitle)
                if let processID {
                    LabeledContent("Process ID", value: String(processID))
                }
                LabeledContent("Starts at login", value: model.serviceInfo.isInstalled ? "Yes" : "No")
                LabeledContent("Server program", value: program)
                if model.isUpdateAvailable || model.setupAction == .update {
                    ServiceActionPrompt(action: .update, isCentered: false)
                }
                ServiceControls()
            }
        }
    }
}
