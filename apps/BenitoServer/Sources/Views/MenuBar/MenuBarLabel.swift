import SwiftUI

struct MenuBarLabel: View {
    let model: ServerModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.indicator.symbolName)
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
}
