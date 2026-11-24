import SwiftUI

struct AutoLoginRow: View {
    /// The account this Mac logs in by itself, `nil` when automatic login is off.
    let user: String?

    private var isThisUser: Bool { user == NSUserName() }

    private var finding: String {
        guard let user else {
            return "Automatic login is off. After a power cut this Mac waits at the login window, and the server stays off until someone logs in."
        }
        return isThisUser
            ? "This Mac logs in as \(user) by itself after it starts up."
            : "This Mac logs in by itself as \(user), but the server runs under \(NSUserName())."
    }

    var body: some View {
        ReliabilityRow(
            title: "Automatic login",
            state: isThisUser ? .ok : .needsAttention,
            finding: finding,
            why: "The server runs only while this user is logged in, so after a restart the Mac has to log in on its own. Automatic login needs FileVault to be off."
        ) {
            Button("Open Users & Groups") {
                SystemSettings.open(SystemSettings.usersAndGroups)
            }
            .controlSize(.small)
        }
    }
}
