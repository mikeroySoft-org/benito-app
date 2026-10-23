import Foundation

/// Pure port of the server's `GET /summary/daily` (server/src/routes/summary.rs), so a
/// device with no server shows the same Day totals a family server would.
public enum DailySummaryCalculator {
    public enum WindowError: Error, Sendable, Equatable {
        case toNotAfterFrom
        case invalidDay(String)
    }

    /// Same precedence as the server: explicit `from`+`to`, else a UTC calendar `day`
    /// (`yyyy-MM-dd`), else the last 24 hours ending `now`.
    public static func window(
        day: String?,
        from: Date?,
        to: Date?,
        now: Date = Date.now
    ) throws -> (from: Date, to: Date, day: String?) {
        if let from, let to {
            guard to > from else { throw WindowError.toNotAfterFrom }
            return (from, to, day)
        }
        if let day {
            guard let start = utcDayStart(day) else { throw WindowError.invalidDay(day) }
            return (start, start.addingTimeInterval(86_400), day)
        }
        return (now.addingTimeInterval(-86_400), now, nil)
    }

    /// Totals for `events` (any superset of the window's events; deleted rows are ignored).
    public static func summarize(
        childId: UUID,
        events: [EventDTO],
        from: Date,
        to: Date,
        day: String?
    ) -> DailySummaryDTO {
        var feedBreastCount = 0, feedBreastLeft = 0, feedBreastRight = 0
        var feedBottleCount = 0, feedSolidCount = 0
        var bottleOz = 0.0, bottleMl = 0.0, feedSecs = 0.0
        var diaperWet = 0, diaperDirty = 0, diaperBoth = 0, diaperOther = 0
        var pumpCount = 0, medicineCount = 0, totalEvents = 0
        var sleepCount = 0, sleepSecs = 0.0, nursingSecs = 0.0, cryingSecs = 0.0

        let live = events.filter { $0.childId == childId && $0.deletedAt == nil }

        for event in live where event.startedAt >= from && event.startedAt < to {
            totalEvents += 1
            switch event.type {
            case EventType.feedBreast.rawValue:
                feedBreastCount += 1
                switch event.side {
                case "L", "l", "left": feedBreastLeft += 1
                case "R", "r", "right": feedBreastRight += 1
                default: break
                }
                feedSecs += timedSeconds(event)
            case EventType.feedBottle.rawValue:
                feedBottleCount += 1
                if let amount = event.amountValue {
                    if (event.amountUnit ?? "oz").lowercased() == "ml" {
                        bottleMl += amount
                    } else {
                        bottleOz += amount
                    }
                }
                feedSecs += timedSeconds(event)
            case EventType.feedSolid.rawValue:
                feedSolidCount += 1
                feedSecs += timedSeconds(event)
            case EventType.diaper.rawValue:
                switch (event.subtype ?? "").lowercased() {
                case "wet": diaperWet += 1
                case "dirty", "poop", "bm": diaperDirty += 1
                case "both", "mixed": diaperBoth += 1
                default: diaperOther += 1
                }
            case EventType.pump.rawValue:
                pumpCount += 1
            case EventType.medicine.rawValue:
                medicineCount += 1
            default:
                break
            }
        }

        for span in spans(live, type: EventType.sleep.rawValue, subtype: nil, from: from, to: to) {
            if span.startedAt < from { totalEvents += 1 }
            sleepCount += 1
            sleepSecs += clippedActiveSeconds(span, from: from, to: to)
        }
        for span in spans(live, type: EventType.feedBreast.rawValue, subtype: nil, from: from, to: to) {
            nursingSecs += clippedActiveSeconds(span, from: from, to: to)
        }
        for span in spans(live, type: EventType.activity.rawValue, subtype: ActivityKind.crying.rawValue, from: from, to: to) {
            cryingSecs += clippedActiveSeconds(span, from: from, to: to)
        }

        return DailySummaryDTO(
            childId: childId,
            from: from,
            to: to,
            day: day,
            feedBreastCount: feedBreastCount,
            feedBreastLeft: feedBreastLeft,
            feedBreastRight: feedBreastRight,
            feedBottleCount: feedBottleCount,
            bottleOzTotal: round2(bottleOz),
            bottleMlTotal: round2(bottleMl),
            bottleOzEquiv: round2(bottleOz + bottleMl / 29.5735),
            feedSolidCount: feedSolidCount,
            feedSeconds: round2(feedSecs),
            nursingSeconds: round2(nursingSecs),
            cryingSeconds: round2(cryingSecs),
            diaperWet: diaperWet,
            diaperDirty: diaperDirty,
            diaperBoth: diaperBoth,
            diaperOther: diaperOther,
            sleepEventCount: sleepCount,
            sleepHours: round2(sleepSecs / 3600),
            pumpCount: pumpCount,
            medicineCount: medicineCount,
            totalEvents: totalEvents
        )
    }

    // MARK: - Server helpers, ported

    /// Ended events of `type` that overlap `[from, to)` with a positive length.
    private static func spans(_ events: [EventDTO], type: String, subtype: String?, from: Date, to: Date) -> [EventDTO] {
        events.filter { event in
            guard event.type == type, let end = event.endedAt else { return false }
            if let subtype, event.subtype != subtype { return false }
            return event.startedAt < to && end > from && end > event.startedAt
        }
    }

    /// Whole seconds like chrono's `num_seconds()` (truncates toward zero).
    private static func wholeSeconds(_ interval: TimeInterval) -> Int {
        Int(interval.rounded(.towardZero))
    }

    private static func timedSeconds(_ event: EventDTO) -> Double {
        guard let end = event.endedAt else { return 0 }
        return Double(max(0, wholeSeconds(end.timeIntervalSince(event.startedAt)) - event.pausedSeconds))
    }

    /// Clipped wall time scaled by the event's active share (paused time spread evenly).
    private static func clippedActiveSeconds(_ event: EventDTO, from: Date, to: Date) -> Double {
        guard let end = event.endedAt else { return 0 }
        let clipStart = max(event.startedAt, from)
        let clipEnd = min(end, to)
        guard clipEnd > clipStart else { return 0 }
        let wall = Double(max(0, wholeSeconds(end.timeIntervalSince(event.startedAt))))
        let clippedWall = Double(max(0, wholeSeconds(clipEnd.timeIntervalSince(clipStart))))
        guard wall > 0 else { return 0 }
        let activeFull = max(0, wall - Double(event.pausedSeconds))
        return clippedWall * activeFull / wall
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func utcDayStart(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        var components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        components.timeZone = calendar.timeZone
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == parts[2]
        else { return nil }
        return date
    }
}
