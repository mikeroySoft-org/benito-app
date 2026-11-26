import AppIntents
import BenitoKit
import Foundation

// Compiled into the app and the widget extension. `LiveActivityIntent`s run in the app's process
// even when triggered from a Live Activity button (Lock Screen, Dynamic Island, Apple Watch).

/// Siri's "Left, right, or bottle?" answer.
enum FeedChoice: String, AppEnum {
    case left
    case right
    case bottle

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Feed"
    static let caseDisplayRepresentations: [FeedChoice: DisplayRepresentation] = [
        .left: DisplayRepresentation(title: "Left", synonyms: ["left side", "left breast", "on the left"]),
        .right: DisplayRepresentation(title: "Right", synonyms: ["right side", "right breast", "on the right"]),
        .bottle: DisplayRepresentation(title: "Bottle", synonyms: ["bottle", "bottle feed"]),
    ]
}

// MARK: - Siri / Shortcuts

struct StartFeedIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a feed"
    static let description: IntentDescription? = IntentDescription(
        "Starts nursing (left or right) or logs a bottle. Asks which one when you don't say."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Feed", requestValueDialog: IntentDialog("Left, right, or bottle?"))
    var choice: FeedChoice

    /// Donated to Siri for "Sam started a feed". The family's child is used when this is nil.
    @Parameter(title: "Child")
    var child: ChildEntity?

    @Parameter(title: "Ounces", requestValueDialog: IntentDialog("How many ounces?"))
    var ounces: Double?

    @Parameter(title: "Milk", requestValueDialog: IntentDialog("Breast milk or formula?"))
    var milk: MilkType?

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = try await BenitoIntentBackend.connect()
        let name = backend.childName
        switch choice {
        case .left, .right:
            let side = choice == .left ? "L" : "R"
            try await backend.startTimer(kind: EventType.feedBreast.rawValue, side: side)
            let sideName = choice == .left ? "left" : "right"
            return .result(dialog: "Started \(name)'s \(sideName)-side feed.")
        case .bottle:
            let amount = try await resolvedOunces()
            let milkType = try await resolvedMilk()
            try await backend.createEvent(
                type: EventType.feedBottle.rawValue,
                subtype: milkType.eventSubtype,
                amountValue: amount,
                amountUnit: "oz"
            )
            let amountText = BenitoActivityAttributes.ContentState.formatAmount(amount)
            return .result(dialog: "Logged a \(amountText) oz \(milkType.spokenName) bottle for \(name).")
        }
    }

    private func resolvedOunces() async throws -> Double {
        // Typed as optional so this compiles whether `requestValue` yields `Double` or `Double?`.
        let requested: Double?
        if let ounces {
            requested = ounces
        } else {
            requested = try await $ounces.requestValue(IntentDialog("How many ounces?"))
        }
        guard let amount = requested, amount.isFinite, amount > 0, amount <= 32 else {
            throw IntentError.invalidAmount
        }
        return amount
    }

    private func resolvedMilk() async throws -> MilkType {
        if let milk { return milk }
        let requested: MilkType? = try await $milk.requestValue(IntentDialog("Breast milk or formula?"))
        return requested ?? .formula
    }
}

struct StartNapIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a nap"
    static let description: IntentDescription? = IntentDescription("Starts the nap timer.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// Donated to Siri for "Sam started a nap". The family's child is used when this is nil.
    @Parameter(title: "Child")
    var child: ChildEntity?

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = try await BenitoIntentBackend.connect()
        try await backend.startTimer(kind: EventType.sleep.rawValue, side: nil)
        return .result(dialog: "Started \(backend.childName)'s nap.")
    }
}

/// Pauses the running feed/nap timer (e.g. to burp). Also the Live Activity's Pause button.
struct PauseTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause the timer"
    static let description: IntentDescription? = IntentDescription(
        "Pauses the running feed or nap timer. Paused time isn't counted."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = try await BenitoIntentBackend.connect()
        let timer = try backend.requireActiveTimer()
        let label = BenitoIntentBackend.timerLabel(kind: timer.kind)
        guard !timer.isPaused else {
            await backend.syncLiveActivity()
            return .result(dialog: "\(backend.childName)'s \(label) is already paused.")
        }
        try await backend.pause(timerId: timer.id)
        return .result(dialog: "Paused \(backend.childName)'s \(label).")
    }
}

/// Resumes a paused feed/nap timer. Also the Live Activity's Resume button.
struct ResumeTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Resume the timer"
    static let description: IntentDescription? = IntentDescription("Resumes the paused feed or nap timer.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = try await BenitoIntentBackend.connect()
        let timer = try backend.requireActiveTimer()
        let label = BenitoIntentBackend.timerLabel(kind: timer.kind)
        guard timer.isPaused else {
            await backend.syncLiveActivity()
            return .result(dialog: "\(backend.childName)'s \(label) is already running.")
        }
        try await backend.resume(timerId: timer.id)
        return .result(dialog: "Resumed \(backend.childName)'s \(label).")
    }
}

/// Stops the active feed/nap/outing/crying timer and logs it. Also the Live Activity's Stop button.
struct StopTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop the timer"
    static let description: IntentDescription? = IntentDescription(
        "Stops the feed, nap, walk, or car-ride timer and logs it, excluding paused time."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// Donated to Siri for "done feeding Sam" / "Sam woke up". Ignored when nil.
    @Parameter(title: "Child")
    var child: ChildEntity?

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = try await BenitoIntentBackend.connect()
        let timer = try backend.requireActiveTimer()
        let stopped = try await backend.stop(timerId: timer.id)
        let label = BenitoIntentBackend.timerLabel(kind: timer.kind)
        let duration = BenitoIntentBackend.spokenDuration(stopped.elapsed(at: stopped.stoppedAt ?? Date()))
        return .result(dialog: "Stopped \(backend.childName)'s \(label) after \(duration).")
    }
}

// MARK: - Live Activity buttons (not offered in Shortcuts / Siri)

/// Live Activity idle "Feed" button — opens the Feeding sheet (Nursing | Bottle).
struct OpenFeedSheetIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Log a feed"
    static let isDiscoverable = false
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    func perform() async throws -> some IntentResult {
        BenitoHomeSheetRequest.enqueue("feed")
        return .result()
    }
}

/// Live Activity idle "Diaper" button — opens the Diaper sheet (Wet / Dirty / Both).
struct OpenDiaperSheetIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Log a diaper"
    static let isDiscoverable = false
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    func perform() async throws -> some IntentResult {
        BenitoHomeSheetRequest.enqueue("diaper")
        return .result()
    }
}

/// Live Activity "Feed L" / "Feed R" button (kept for Shortcuts / older layouts).
struct StartFeedButtonIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start a breast feed"
    static let isDiscoverable = false
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// `L` or `R`.
    @Parameter(title: "Side")
    var side: String

    init() {}

    init(side: String) {
        self.side = side
    }

    func perform() async throws -> some IntentResult {
        let backend = try await BenitoIntentBackend.connect()
        try await backend.startTimerFromButton(
            kind: EventType.feedBreast.rawValue,
            side: side.uppercased() == "R" ? "R" : "L"
        )
        return .result()
    }
}

/// Live Activity idle "Sleep" button — starts the nap timer immediately.
struct StartNapButtonIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start a nap timer"
    static let isDiscoverable = false
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    func perform() async throws -> some IntentResult {
        let backend = try await BenitoIntentBackend.connect()
        try await backend.startTimerFromButton(kind: EventType.sleep.rawValue, side: nil)
        return .result()
    }
}
