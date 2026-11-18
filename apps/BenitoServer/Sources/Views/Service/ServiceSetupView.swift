import SwiftUI

/// What a server that is not answering needs next: the step that gets it going, or progress
/// while a change to the service runs. Shows nothing when there is no such step.
struct ServiceSetupView: View {
    @Environment(ServerModel.self) private var model

    var isCentered = true

    var body: some View {
        if let operation = model.operation {
            ServiceProgressView(operation: operation)
        } else if let action = model.setupAction {
            ServiceActionPrompt(action: action, isCentered: isCentered)
        }
    }
}
