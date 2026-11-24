import AppKit
import SwiftUI

struct MainWindow: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(MainPane.allCases, selection: $model.selectedPane) { pane in
                Label(pane.title, systemImage: pane.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            MainPaneView(pane: model.selectedPane ?? .overview)
        }
        .frame(minWidth: 760, minHeight: 480)
        // LSUIElement keeps the app out of the Dock; it becomes a regular app only while this
        // window is open, so the window can come forward and has a menu bar.
        .onAppear {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate()
        }
        .onDisappear {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
}
