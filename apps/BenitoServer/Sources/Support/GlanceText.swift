import BenitoKit
import Foundation

/// Words for the events and timers in the glance.
enum GlanceText {
    static func feed(_ event: EventDTO) -> String {
        let kind = switch EventType(rawValue: event.type) {
        case .feedBreast: "Breast"
        case .feedBottle: "Bottle"
        case .feedSolid: "Solids"
        default: "Feed"
        }
        return ([kind] + [side(event.side), amount(of: event)].compactMap { $0 }).joined(separator: ", ")
    }

    static func diaper(_ event: EventDTO) -> String {
        switch event.subtype?.lowercased() {
        case "wet": "Wet"
        case "dirty": "Dirty"
        case "both": "Wet and dirty"
        default: "Diaper"
        }
    }

    /// A medicine event carries its display name in `subtype`.
    static func medicine(_ event: EventDTO) -> String {
        let name = event.subtype?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ([name.isEmpty ? "Medicine" : name] + [amount(of: event)].compactMap { $0 })
            .joined(separator: ", ")
    }

    static func timer(_ timer: TimerDTO) -> String {
        let kind: String
        switch timer.kind {
        case EventType.sleep.rawValue:
            kind = "Sleeping"
        case EventType.feedBreast.rawValue:
            kind = (["Nursing"] + [side(timer.side)].compactMap { $0 }).joined(separator: ", ")
        default:
            kind = ActivityKind(timerKind: timer.kind)?.title
                ?? timer.kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return timer.isPaused ? "\(kind), paused" : kind
    }

    static func timerSymbol(_ timer: TimerDTO) -> String {
        if timer.isPaused { return "pause.circle" }
        return switch timer.kind {
        case EventType.sleep.rawValue: "moon.zzz"
        default: ActivityKind(timerKind: timer.kind)?.systemImage ?? "timer"
        }
    }

    private static func side(_ side: String?) -> String? {
        switch side?.uppercased() {
        case "L": "left"
        case "R": "right"
        case "BOTH": "both sides"
        default: nil
        }
    }

    private static func amount(of event: EventDTO) -> String? {
        guard let value = event.amountValue else { return nil }
        let number = value.formatted(.number.precision(.fractionLength(0...1)))
        guard let unit = event.amountUnit, !unit.isEmpty else { return number }
        return "\(number) \(unit)"
    }
}
