import SwiftUI

/// Why there are no service controls for a server that launchd does not run for this home.
struct ServiceOutsideAppNotice: View {
    var body: some View {
        Text("This server was started outside the app, so the app cannot stop, restart or update it.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
