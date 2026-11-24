import SwiftUI

/// Restart, Stop or Start, and Uninstall for the service of this home, with progress.
struct ServiceControls: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if model.canControlService {
                    if model.serviceInfo.isLoaded {
                        Button("Restart", action: restart)
                        StopServerButton()
                    } else {
                        Button("Start", action: start)
                    }
                }
                UninstallServiceButton()
            }
            .disabled(model.isBusy)
            if let operation = model.operation {
                ServiceProgressView(operation: operation)
            }
        }
    }

    private func restart() {
        Task { await model.restartServer() }
    }

    private func start() {
        Task { await model.startServer() }
    }
}
