import SwiftUI

struct MenuBarLabel: View {
    let model: ServerModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        image
            .accessibilityLabel(model.indicator.accessibilityLabel)
            // An LSUIElement app shows no window by itself, and the menu bar item is easy to
            // miss; the label exists from launch, so it opens the window once. A launch at
            // login stays quiet.
            .task {
                if !LaunchReason.isLoginItem {
                    openWindow(id: ServerModel.mainWindowID)
                }
            }
    }

    /// The capybara while things are fine; a status symbol when the server is stopped or needs
    /// attention, so a problem is visible in the menu bar.
    private var image: Image {
        switch model.indicator {
        case .checking, .working, .running: Image("MenuBarIcon")
        case .needsAttention, .stopped: Image(systemName: model.indicator.symbolName)
        }
    }
}
