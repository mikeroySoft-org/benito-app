import AppIntents
import BenitoKit
import Foundation

/// Siri's "Breast milk or formula?" answer for bottle feeds.
enum MilkType: String, AppEnum {
    case breastMilk
    case formula

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Milk"
    static let caseDisplayRepresentations: [MilkType: DisplayRepresentation] = [
        .breastMilk: DisplayRepresentation(title: "Breast milk", synonyms: ["breastmilk", "pumped milk", "expressed milk"]),
        .formula: DisplayRepresentation(title: "Formula", synonyms: ["formula milk"]),
    ]

    /// `feed_bottle` event subtype.
    var eventSubtype: String {
        switch self {
        case .breastMilk: return "breastmilk"
        case .formula: return "formula"
        }
    }

    var spokenName: String {
        switch self {
        case .breastMilk: return "breast milk"
        case .formula: return "formula"
        }
    }
}

/// Siri's "Wet, dirty, or both?" answer; raw values are the `diaper` event subtypes.
enum DiaperKind: String, AppEnum {
    case wet
    case dirty
    case both

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Diaper"
    static let caseDisplayRepresentations: [DiaperKind: DisplayRepresentation] = [
        .wet: DisplayRepresentation(title: "Wet", synonyms: ["pee", "wet diaper"]),
        .dirty: DisplayRepresentation(title: "Dirty", synonyms: ["poop", "poopy", "dirty diaper"]),
        .both: DisplayRepresentation(title: "Both", synonyms: ["wet and dirty", "mixed"]),
    ]
}

struct LogDiaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a diaper"
    static let description: IntentDescription? = IntentDescription("Logs a wet, dirty, or mixed diaper.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Diaper", requestValueDialog: IntentDialog("Wet, dirty, or both?"))
    var kind: DiaperKind

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = try await BenitoIntentBackend.connect()
        try await backend.createEvent(type: EventType.diaper.rawValue, subtype: kind.rawValue)
        let what = kind == .both ? "wet and dirty" : kind.rawValue
        return .result(dialog: "Logged a \(what) diaper for \(backend.childName).")
    }
}

/// Dose unit for medicine logs. Raw values match `MedicineDoseUnit` / `amount_unit`.
enum MedicineUnitOption: String, AppEnum {
    case ml
    case drops
    case mg
    case iu = "IU"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Unit"
    static let caseDisplayRepresentations: [MedicineUnitOption: DisplayRepresentation] = [
        .ml: DisplayRepresentation(title: "ml", synonyms: ["milliliters", "millilitres", "mL"]),
        .drops: DisplayRepresentation(title: "drops", synonyms: ["drop"]),
        .mg: DisplayRepresentation(title: "mg", synonyms: ["milligrams"]),
        .iu: DisplayRepresentation(title: "IU", synonyms: ["international units", "units"]),
    ]

    var spokenName: String {
        switch self {
        case .ml: return "ml"
        case .drops: return "drops"
        case .mg: return "mg"
        case .iu: return "IU"
        }
    }
}

/// Pumping side. Raw values match `PumpSide` (`L` / `R` / `both`).
enum PumpSideOption: String, AppEnum {
    case left = "L"
    case right = "R"
    case both

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Side"
    static let caseDisplayRepresentations: [PumpSideOption: DisplayRepresentation] = [
        .left: DisplayRepresentation(title: "Left", synonyms: ["left side"]),
        .right: DisplayRepresentation(title: "Right", synonyms: ["right side"]),
        .both: DisplayRepresentation(title: "Both", synonyms: ["both sides"]),
    ]

    var spokenName: String {
        switch self {
        case .left: return "left"
        case .right: return "right"
        case .both: return "both sides"
        }
    }
}

struct LogMedicineIntent: AppIntent {
    static let title: LocalizedStringResource = "Log medicine"
    static let description: IntentDescription? = IntentDescription(
        "Logs a medicine dose. Asks for the name, then an optional amount."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// Free text, same as the sheet's medicine name (preset label or custom). App Shortcut
    /// phrases can't include a String, so Siri asks when it isn't already set.
    @Parameter(title: "Medicine", requestValueDialog: IntentDialog("Which medicine?"))
    var name: String

    /// Optional. Zero skips the dose, matching the sheet's "Record dose" toggle off.
    @Parameter(title: "Dose", requestValueDialog: IntentDialog("How much? Say the dose, or zero to skip."))
    var dose: Double?

    /// Used only when a dose is recorded. Defaults to ml, the sheet's starting unit.
    @Parameter(title: "Unit", default: .ml)
    var unit: MedicineUnitOption

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = try await BenitoIntentBackend.connect()
        let medicine = try await resolvedName()
        let amount = try await resolvedDose()
        try await backend.createEvent(
            type: EventType.medicine.rawValue,
            subtype: medicine,
            amountValue: amount,
            amountUnit: amount == nil ? nil : unit.rawValue
        )
        if let amount {
            let doseText = BenitoActivityAttributes.ContentState.formatAmount(amount)
            return .result(dialog: "Logged \(doseText) \(unit.spokenName) of \(medicine) for \(backend.childName).")
        }
        return .result(dialog: "Logged \(medicine) for \(backend.childName).")
    }

    private func resolvedName() async throws -> String {
        let provided = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: String?
        if !provided.isEmpty {
            raw = provided
        } else {
            raw = try await $name.requestValue(IntentDialog("Which medicine?"))
        }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw IntentError.medicineNameRequired }
        return trimmed
    }

    private func resolvedDose() async throws -> Double? {
        let requested: Double?
        if let dose {
            requested = dose
        } else {
            requested = try await $dose.requestValue(IntentDialog("How much? Say the dose, or zero to skip."))
        }
        return try Self.finiteAmount(requested, max: 40, error: .invalidDose)
    }

    /// `nil` / zero → skip. Otherwise a positive finite amount up to `max`.
    static func finiteAmount(_ requested: Double?, max: Double, error: IntentError) throws -> Double? {
        guard let amount = requested else { return nil }
        if amount == 0 { return nil }
        guard amount.isFinite, amount > 0, amount <= max else { throw error }
        return amount
    }
}

struct LogPumpIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a pump"
    static let description: IntentDescription? = IntentDescription(
        "Logs a pumping session with optional ounces and duration."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// Sheet default is Both, so a bare "pumped" doesn't have to ask.
    @Parameter(title: "Side", default: .both)
    var side: PumpSideOption

    /// Optional. Zero skips the amount, matching "Record amount" off. Unit is always oz.
    @Parameter(title: "Ounces", requestValueDialog: IntentDialog("How many ounces? Say zero to skip."))
    var ounces: Double?

    /// Optional minutes. Zero skips, matching "Record duration" off. Stored as ended_at = finish.
    @Parameter(title: "Duration", requestValueDialog: IntentDialog("How many minutes? Say zero to skip."))
    var durationMinutes: Double?

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = try await BenitoIntentBackend.connect()
        let amount = try await resolvedOunces()
        let minutes = try await resolvedMinutes()
        let finish = Date()
        let start = minutes.map { finish.addingTimeInterval(-TimeInterval($0 * 60)) }
        try await backend.createEvent(
            type: EventType.pump.rawValue,
            amountValue: amount,
            amountUnit: amount == nil ? nil : "oz",
            side: side.rawValue,
            startedAt: start,
            endedAt: minutes == nil ? nil : finish
        )
        let spoken = Self.spokenResult(childName: backend.childName, side: side, ounces: amount, minutes: minutes)
        return .result(dialog: "\(spoken)")
    }

    private func resolvedOunces() async throws -> Double? {
        let requested: Double?
        if let ounces {
            requested = ounces
        } else {
            requested = try await $ounces.requestValue(IntentDialog("How many ounces? Say zero to skip."))
        }
        // Sheet stepper tops out at 16 oz; allow a little more for voice.
        return try LogMedicineIntent.finiteAmount(requested, max: 32, error: .invalidPumpAmount)
    }

    private func resolvedMinutes() async throws -> Int? {
        let requested: Double?
        if let durationMinutes {
            requested = durationMinutes
        } else {
            requested = try await $durationMinutes.requestValue(IntentDialog("How many minutes? Say zero to skip."))
        }
        guard let amount = try LogMedicineIntent.finiteAmount(requested, max: 120, error: .invalidPumpDuration) else {
            return nil
        }
        return max(1, Int(amount.rounded()))
    }

    private static func spokenResult(childName: String, side: PumpSideOption, ounces: Double?, minutes: Int?) -> String {
        var parts: [String] = []
        if let ounces {
            parts.append("\(BenitoActivityAttributes.ContentState.formatAmount(ounces)) oz")
        }
        if let minutes {
            parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes")
        }
        let detail = parts.isEmpty ? "" : "\(parts.joined(separator: ", ")) "
        let sideText = side == .both ? "" : "\(side.spokenName)-side "
        return "Logged a \(detail)\(sideText)pump for \(childName)."
    }
}
