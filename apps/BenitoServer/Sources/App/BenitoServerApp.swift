import SwiftUI

@main
struct BenitoServerApp: App {
    @State private var model: ServerModel
    @State private var updater: UpdaterController

    init() {
        let model = ServerModel()
        _model = State(initialValue: model)
        _updater = State(initialValue: UpdaterController(model: model))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
                .task { HealthMonitor.shared.start(watching: model) }
        }
        .menuBarExtraStyle(.window)

        Window("Benito Server", id: ServerModel.mainWindowID) {
            MainWindow()
                .environment(model)
                .environment(updater)
        }
        .defaultSize(width: 880, height: 620)
    }
}
