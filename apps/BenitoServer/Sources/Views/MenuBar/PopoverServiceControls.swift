import SwiftUI

/// Restart and Stop for a running server the app manages.
///
/// Stop asks first, in place: a dialog would take focus away from the menu bar window, which
/// closes when it loses focus.
struct PopoverServiceControls: View {
    @Environment(ServerModel.self) private var model

    @State private var isConfirmingStop = false

    var body: some View {
        if isConfirmingStop {
            VStack(alignment: .leading, spacing: 6) {
                Text(StopServerButton.consequence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Stop Server", role: .destructive, action: stop)
                    Button("Cancel", role: .cancel, action: cancelStop)
                }
            }
        } else {
            HStack {
                Button("Restart", action: restart)
                Button("Stop…", action: confirmStop)
            }
            .disabled(model.isBusy)
        }
    }

    private func restart() {
        Task { await model.restartServer() }
    }

    private func confirmStop() {
        isConfirmingStop = true
    }

    private func cancelStop() {
        isConfirmingStop = false
    }

    private func stop() {
        isConfirmingStop = false
        Task { await model.stopServer() }
    }
}
