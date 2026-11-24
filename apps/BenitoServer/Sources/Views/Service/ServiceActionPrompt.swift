import SwiftUI

/// The button that installs, updates or starts the server, with what it does written underneath.
struct ServiceActionPrompt: View {
    @Environment(ServerModel.self) private var model

    let action: ServiceSetupAction
    /// Centered inside an empty pane, leading inside a form or the popover.
    var isCentered = true

    var body: some View {
        VStack(alignment: isCentered ? .center : .leading, spacing: 8) {
            Button(action.buttonTitle, action: run)
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            Text(action.details)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(isCentered ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func run() {
        Task { await model.perform(action) }
    }
}
