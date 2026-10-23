import AppIntents
import BenitoKit
import Foundation

/// Starts the shared crying timer (mood); `StopTimerIntent` stops it into an
/// `activity` / `crying` event.
struct StartCryingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a crying timer"
    static let description: IntentDescription? = IntentDescription(
        "Starts a crying timer to track fussy spells."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = try await BenitoIntentBackend.connect()
        try await backend.startTimer(kind: ActivityKind.crying.timerKind, side: nil)
        return .result(dialog: "Started \(backend.childName)'s crying timer.")
    }
}
