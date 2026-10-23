import AppIntents
import BenitoKit
import Foundation

/// Siri's "Walk or car ride?" answer.
enum OutingChoice: String, AppEnum {
    case walk
    case carRide

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Outing"
    static let caseDisplayRepresentations: [OutingChoice: DisplayRepresentation] = [
        .walk: DisplayRepresentation(title: "Walk", synonyms: ["stroll", "stroller walk"]),
        .carRide: DisplayRepresentation(title: "Car ride", synonyms: ["drive", "car trip"]),
    ]

    var kind: ActivityKind {
        switch self {
        case .walk: .walk
        case .carRide: .carRide
        }
    }
}

/// Starts the shared walk / car-ride timer; `StopTimerIntent` stops it into an activity event.
struct StartOutingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a walk or car ride"
    static let description: IntentDescription? = IntentDescription(
        "Starts a walk or car-ride timer. Asks which one when you don't say."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Outing", requestValueDialog: IntentDialog("Walk or car ride?"))
    var choice: OutingChoice

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = try await BenitoIntentBackend.connect()
        let kind = choice.kind
        try await backend.startTimer(kind: kind.timerKind, side: nil)
        return .result(dialog: "Started \(backend.childName)'s \(kind.noun).")
    }
}
