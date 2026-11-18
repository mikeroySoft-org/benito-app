import SwiftUI

/// What the popover has to say about the service itself: the step that gets a server going
/// that is not answering, progress, an update that is ready, or that the server was started
/// outside the app. Nothing when the service is simply running.
struct PopoverServiceNotice: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        if !model.isRunning {
            ServiceSetupView(isCentered: false)
        } else if let operation = model.operation {
            ServiceProgressView(operation: operation)
                .font(.callout)
        } else if model.isRunningOutsideApp {
            ServiceOutsideAppNotice()
                .font(.callout)
        } else if model.isUpdateAvailable {
            ServiceActionPrompt(action: .update, isCentered: false)
        }
    }
}
