import SwiftUI

struct StopServerButton: View {
    /// What stopping means for the family, wherever the app asks before doing it.
    static let consequence = "Phones cannot sync while the server is stopped. They keep new entries and send them once it runs again."

    @Environment(ServerModel.self) private var model

    @State private var isConfirming = false

    var body: some View {
        Button("Stop…") {
            isConfirming = true
        }
        .confirmationDialog("Stop the Benito server?", isPresented: $isConfirming) {
            Button("Stop Server", role: .destructive, action: stop)
        } message: {
            Text("\(Self.consequence) The server stays stopped until you start it here or log in to this Mac again.")
        }
    }

    private func stop() {
        Task { await model.stopServer() }
    }
}
