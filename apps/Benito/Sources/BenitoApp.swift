import SwiftUI

enum BenitoServerPresets {
    /// Simulator / same-Mac only — not reachable from a physical phone.
    static let loopback = "http://127.0.0.1:8080"
}

@main
struct BenitoApp: App {
    /// Empty until the user enters their server's HTTPS address (first-run prompt in ContentView).
    @AppStorage("serverURL") private var serverURL = ""

    init() {
        // Older builds stored the URL untrimmed; a stray space makes it unusable on launch.
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: "serverURL") {
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != stored {
                defaults.set(trimmed, forKey: "serverURL")
            }
        }
        BenitoTips.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(serverURLString: $serverURL)
        }
    }
}
