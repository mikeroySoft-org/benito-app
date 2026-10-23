import Foundation

/// A timed span that is not a feed or sleep: an outing (walk, car ride) or a crying spell.
///
/// Logged as `type = "activity"` with this as the subtype. While running, the shared timer's
/// `kind` is the raw value (`walk` / `car_ride` / `crying`) and the server turns it into an
/// `activity` event on stop.
public enum ActivityKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case walk
    case carRide = "car_ride"
    case crying

    /// Kinds offered together in the outing sheet and the outing subtype picker.
    public static let outings: [ActivityKind] = [.walk, .carRide]

    public var id: String { rawValue }

    /// Walk / car ride (as opposed to a mood span like crying).
    public var isOuting: Bool { Self.outings.contains(self) }

    /// Timer kind sent to `POST /timers` (same as the event subtype).
    public var timerKind: String { rawValue }

    /// Visible title: "Walk", "Car ride", "Crying".
    public var title: String {
        switch self {
        case .walk: "Walk"
        case .carRide: "Car ride"
        case .crying: "Crying"
        }
    }

    /// Lowercase noun for sentences and Siri: "walk", "car ride", "crying".
    public var noun: String {
        switch self {
        case .walk: "walk"
        case .carRide: "car ride"
        case .crying: "crying"
        }
    }

    /// SF Symbol for cards, timeline rows, and the running timer.
    public var systemImage: String {
        switch self {
        case .walk: "figure.walk"
        case .carRide: "car.fill"
        case .crying: "cloud.rain.fill"
        }
    }

    /// The activity a running timer represents; nil for feed / sleep timers.
    public init?(timerKind: String?) {
        guard let raw = timerKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        self.init(rawValue: raw)
    }

    /// The activity an `activity` event represents; nil for other event types.
    public init?(event: EventDTO) {
        guard event.type == EventType.activity.rawValue else { return nil }
        self.init(timerKind: event.subtype)
    }

    /// Active seconds of this kind inside `[from, to)`: clipped at the window edges, paused
    /// time excluded. Events without `endedAt` add no time.
    public func activeSeconds(in events: [EventDTO], from: Date, to: Date) -> TimeInterval {
        events.reduce(0) { total, event in
            guard event.deletedAt == nil, ActivityKind(event: event) == self else { return total }
            return total + DailyFedTotals.clippedActiveSeconds(of: event, from: from, to: to)
        }
    }
}
