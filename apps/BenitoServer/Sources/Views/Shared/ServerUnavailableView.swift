import SwiftUI

/// Fills a pane when there is no admin API to show data from: what is going on, and the button
/// that installs, updates or starts the server.
struct ServerUnavailableView: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label(model.statusLine, systemImage: model.indicator.symbolName)
        } description: {
            Text(model.explanation ?? "The server is running, but its status has not loaded yet.")
        } actions: {
            ServiceSetupView()
        }
    }
}
