import Foundation

/// How much the baby was fed in one day: nursing time and bottle volume.
///
/// Nursing is clipped to the day like sleep (a feed straddling midnight splits across both
/// days). Bottles count when they start in the day; oz and ml are kept apart so a display
/// can convert once.
public struct DailyFedTotals: Equatable, Sendable {
    public static let mlPerOunce = 29.5735

    public var nursingSeconds: TimeInterval
    public var bottleOunces: Double
    public var bottleMilliliters: Double

    public init(nursingSeconds: TimeInterval = 0, bottleOunces: Double = 0, bottleMilliliters: Double = 0) {
        self.nursingSeconds = nursingSeconds
        self.bottleOunces = bottleOunces
        self.bottleMilliliters = bottleMilliliters
    }

    /// From the server summary. Older servers omit `nursing_seconds`; fall back to the
    /// started-in-window nursing total the caller computed locally.
    public init(summary: DailySummaryDTO, fallbackNursingSeconds: TimeInterval) {
        self.init(
            nursingSeconds: summary.nursingSeconds ?? fallbackNursingSeconds,
            bottleOunces: summary.bottleOzTotal,
            bottleMilliliters: summary.bottleMlTotal
        )
    }

    /// Local fallback from events overlapping `[from, to)`. Events without `endedAt` add no
    /// time (see `clippedActiveSeconds(of:from:to:)`).
    public init(events: [EventDTO], from: Date, to: Date) {
        var nursing: TimeInterval = 0
        var oz = 0.0
        var ml = 0.0
        for event in events where event.deletedAt == nil {
            switch event.type {
            case EventType.feedBreast.rawValue:
                nursing += Self.clippedActiveSeconds(of: event, from: from, to: to)
            case EventType.feedBottle.rawValue:
                guard event.startedAt >= from, event.startedAt < to,
                      let value = event.amountValue, value.isFinite, value > 0
                else { continue }
                if event.amountUnit?.lowercased() == "ml" {
                    ml += value
                } else {
                    oz += value
                }
            default:
                continue
            }
        }
        self.init(nursingSeconds: nursing, bottleOunces: oz, bottleMilliliters: ml)
    }

    public var hasNursing: Bool { nursingSeconds >= 30 }
    public var hasBottle: Bool { bottleOunces > 0 || bottleMilliliters > 0 }
    public var isEmpty: Bool { !hasNursing && !hasBottle }

    /// Total bottle volume in ounces (ml converted).
    public var bottleOuncesTotal: Double { bottleOunces + bottleMilliliters / Self.mlPerOunce }

    /// Total bottle volume in millilitres (oz converted).
    public var bottleMillilitersTotal: Double { bottleMilliliters + bottleOunces * Self.mlPerOunce }

    /// Active seconds of `[start, end]` inside `[from, to)`; pause time scales with the clip.
    /// Active seconds of a finished event inside `[from, to)`.
    ///
    /// An event with no `endedAt` is a one-off log with no known duration, not a session in
    /// progress: running sessions live in the timers table, and stopping one writes an event
    /// with `endedAt`. Treating a missing end as "now" let a forgotten Sep 27 nursing log
    /// count as nursing all day, every day.
    public static func clippedActiveSeconds(of event: EventDTO, from: Date, to: Date) -> TimeInterval {
        guard let end = event.endedAt else { return 0 }
        return clippedActiveSeconds(
            start: event.startedAt,
            end: end,
            from: from,
            to: to,
            pausedSeconds: event.pausedSeconds
        )
    }

    public static func clippedActiveSeconds(
        start: Date,
        end: Date,
        from: Date,
        to: Date,
        pausedSeconds: Int
    ) -> TimeInterval {
        let clipStart = max(start, from)
        let clipEnd = min(end, to)
        guard clipEnd > clipStart else { return 0 }
        let wall = end.timeIntervalSince(start)
        guard wall > 0 else { return 0 }
        let activeFull = max(0, wall - TimeInterval(max(0, pausedSeconds)))
        return clipEnd.timeIntervalSince(clipStart) * activeFull / wall
    }
}
