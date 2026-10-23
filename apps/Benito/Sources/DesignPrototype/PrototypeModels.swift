import Foundation
import BenitoKit

/// Glance snapshot used by design prototype screens.
/// Built from live `AppModel` when signed in; otherwise demo data matching SPEC.
struct PrototypeGlance: Equatable {
    var childName: String
    var sinceLastFeed: TimeInterval?
    var feedSideLabel: String?       // "L" | "R" | "Bottle" | nil
    var feedDetail: String?          // e.g. "3 oz formula"
    var sinceLastDiaper: TimeInterval?
    var diaperSubtype: String?       // wet / dirty / both
    var sinceLastMedicine: TimeInterval?
    var medicineLabel: String?       // e.g. "Vitamin D"
    var medicineDetail: String?      // e.g. "1 ml"
    var isAsleep: Bool
    var sleepDuration: TimeInterval  // asleep duration OR awake duration
    var activeTimer: ActiveTimerSnapshot?
    var timeline: [PrototypeTimelineItem]
    /// Today's summary counts (calendar day, local).
    var todayFeedCount: Int
    var todayDiaperCount: Int
    var todaySleepMinutes: Int
    /// Nursing time + bottle volume today (local calendar day).
    var todayFed: DailyFedTotals
    /// Active crying seconds today (local calendar day).
    var todayCryingSeconds: TimeInterval
    /// The window every "today" total above covers; also drives the strip's "Since 12 AM" caption.
    var todayWindow: DayWindow
    var syncConnected: Bool
    var statusLine: String
    var isDemo: Bool
}

/// Active (running or paused) timer as shown by prototype screens; elapsed excludes paused time.
struct ActiveTimerSnapshot: Equatable, Identifiable {
    var timer: TimerDTO

    init(_ timer: TimerDTO) {
        self.timer = timer
    }

    /// Demo / preview snapshot without a server timer.
    init(id: UUID, kind: String, side: String?, startedAt: Date, pausedAt: Date? = nil, pausedSeconds: Int = 0) {
        self.timer = TimerDTO(
            id: id,
            childId: id,
            kind: kind,
            startedAt: startedAt,
            startedBy: id,
            state: pausedAt == nil ? "running" : "paused",
            stoppedAt: nil,
            updatedAt: startedAt,
            side: side,
            pausedAt: pausedAt,
            pausedSeconds: pausedSeconds
        )
    }

    var id: UUID { timer.id }
    var kind: String { timer.kind }          // feed_breast | sleep
    var side: String? { timer.side }         // L | R
    var startedAt: Date { timer.startedAt }
    var isPaused: Bool { timer.isPaused }

    /// Active time; frozen while paused.
    func elapsed(at now: Date) -> TimeInterval {
        timer.elapsed(at: now)
    }
}

struct PrototypeTimelineItem: Equatable, Identifiable {
    var id: UUID
    var title: String
    var detail: String?
    var accent: TimelineAccent
    var at: Date
}

enum TimelineAccent: Equatable {
    case feed, diaper, sleep, outing, crying, other
}

enum PrototypeFormatters {
    static func compactDuration(_ interval: TimeInterval?) -> String {
        guard let interval, interval >= 0 else { return "—" }
        let total = Int(interval)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    static func timerClock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    static func shortTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Running-timer row: "Today, 9:25 PM", "Yesterday, 9:25 PM", or "Thu, Oct 1, 9:25 PM".
    static func startTimeLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        let day = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(day), \(time)"
    }
}

@MainActor
enum PrototypeGlanceBuilder {
    static func demo(now: Date = .now) -> PrototypeGlance {
        PrototypeGlance(
            childName: "Sam",
            sinceLastFeed: 1 * 3600 + 42 * 60,
            feedSideLabel: "L",
            feedDetail: nil,
            sinceLastDiaper: 48 * 60,
            diaperSubtype: "wet",
            sinceLastMedicine: 10 * 3600,
            medicineLabel: "Vitamin D",
            medicineDetail: "1 ml",
            isAsleep: false,
            sleepDuration: 35 * 60,
            activeTimer: nil,
            timeline: [
                PrototypeTimelineItem(
                    id: UUID(),
                    title: "Nursing: Left",
                    detail: "12 min",
                    accent: .feed,
                    at: now.addingTimeInterval(-1 * 3600 - 42 * 60)
                ),
                PrototypeTimelineItem(
                    id: UUID(),
                    title: "Diaper wet",
                    detail: nil,
                    accent: .diaper,
                    at: now.addingTimeInterval(-48 * 60)
                ),
                PrototypeTimelineItem(
                    id: UUID(),
                    title: "Sleep",
                    detail: "1h 10m",
                    accent: .sleep,
                    at: now.addingTimeInterval(-3 * 3600)
                ),
                PrototypeTimelineItem(
                    id: UUID(),
                    title: "Bottle",
                    detail: "3 oz",
                    accent: .feed,
                    at: now.addingTimeInterval(-5 * 3600)
                ),
            ],
            todayFeedCount: 4,
            todayDiaperCount: 3,
            todaySleepMinutes: 130,
            todayFed: DailyFedTotals(nursingSeconds: 42 * 60, bottleOunces: 6),
            todayCryingSeconds: 18 * 60,
            todayWindow: DayWindow(containing: now),
            syncConnected: true,
            statusLine: "Demo glance — toggle off to use Form",
            isDemo: true
        )
    }

    static func from(model: AppModel, now: Date = .now) -> PrototypeGlance {
        guard let state = model.babyState else {
            var demo = Self.demo(now: now)
            // Do not read `model.status` here — Home/Timeline glance rebuilds often, and
            // status churn (sync/outbox) was invalidating Liquid Glass docks for free.
            // Settings / Log read `model.status` directly where it is shown.
            demo.syncConnected = model.syncConnected
            demo.childName = model.childName.isEmpty ? "Baby" : model.childName
            return demo
        }

        let feed = state.lastFeed
        let feedSide: String? = {
            guard let feed else { return nil }
            if feed.type == EventType.feedBottle.rawValue { return "Bottle" }
            if let side = feed.side?.uppercased() { return side }
            return nil
        }()
        let feedDetail: String? = {
            guard let feed, let amount = feed.amountValue else { return nil }
            let unit = feed.amountUnit ?? "oz"
            return "\(formatAmount(amount)) \(unit)"
        }()

        let diaper = state.lastDiaper
        let medicine = state.lastMedicine
        let medicineDetail: String? = {
            guard let medicine, let amount = medicine.amountValue else { return nil }
            let unit = medicine.amountUnit ?? ""
            let amt = formatAmount(amount)
            return unit.isEmpty ? amt : "\(amt) \(unit)"
        }()
        let timerSnap: ActiveTimerSnapshot? = state.activeTimer.flatMap { $0.isActive ? ActiveTimerSnapshot($0) : nil }

        let lastSleep = model.timeline.first { $0.type == EventType.sleep.rawValue }
        let isAsleep: Bool
        let sleepDuration: TimeInterval
        if let timer = state.activeTimer, timer.isActive, timer.kind.lowercased().contains("sleep") {
            isAsleep = true
            sleepDuration = timer.elapsed(at: now)
        } else if let sleep = lastSleep, let ended = sleep.endedAt {
            isAsleep = false
            sleepDuration = now.timeIntervalSince(ended)
        } else if let sleep = lastSleep, sleep.endedAt == nil {
            isAsleep = true
            sleepDuration = now.timeIntervalSince(sleep.startedAt)
        } else {
            isAsleep = false
            sleepDuration = 0
        }

        let items: [PrototypeTimelineItem] = model.timeline.prefix(24).map { event in
            PrototypeTimelineItem(
                id: event.id,
                title: timelineTitle(event),
                detail: timelineDetail(event),
                accent: timelineAccent(event),
                at: event.startedAt
            )
        }

        let today = DayWindow(containing: now)
        let counts = todayCounts(from: model.timeline, in: today)

        return PrototypeGlance(
            childName: model.childName.isEmpty ? "Baby" : model.childName,
            sinceLastFeed: feed.map { now.timeIntervalSince($0.startedAt) },
            feedSideLabel: feedSide,
            feedDetail: feedDetail,
            sinceLastDiaper: diaper.map { now.timeIntervalSince($0.startedAt) },
            diaperSubtype: diaper?.subtype,
            sinceLastMedicine: medicine.map { now.timeIntervalSince($0.startedAt) },
            medicineLabel: medicine?.subtype,
            medicineDetail: medicineDetail,
            isAsleep: isAsleep,
            sleepDuration: sleepDuration,
            activeTimer: timerSnap,
            timeline: items,
            todayFeedCount: counts.feeds,
            todayDiaperCount: counts.diapers,
            todaySleepMinutes: counts.sleepMinutes,
            todayFed: DailyFedTotals(events: model.timeline, from: today.start, to: today.end),
            todayCryingSeconds: ActivityKind.crying.activeSeconds(in: model.timeline, from: today.start, to: today.end),
            todayWindow: today,
            syncConnected: model.syncConnected,
            statusLine: "",
            isDemo: false
        )
    }


    private static func todayCounts(from events: [EventDTO], in window: DayWindow) -> (feeds: Int, diapers: Int, sleepMinutes: Int) {
        let start = window.start
        let end = window.end
        let active = events.filter { $0.deletedAt == nil }
        let startedToday = active.filter { $0.startedAt >= start && $0.startedAt < end }
        let feeds = startedToday.filter { $0.type.hasPrefix("feed_") }.count
        let diapers = startedToday.filter { $0.type == EventType.diaper.rawValue }.count
        // Overnight sleep: overlap [start, end) and clip duration (mirrors server /summary/daily).
        let sleepMinutes = active
            .filter { $0.type == EventType.sleep.rawValue }
            .reduce(0) { partial, event in
                let clipped = DailyFedTotals.clippedActiveSeconds(of: event, from: start, to: end)
                return partial + max(0, Int(clipped / 60))
            }
        return (feeds, diapers, sleepMinutes)
    }

    private static func formatAmount(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    private static func timelineTitle(_ event: EventDTO) -> String {
        switch event.type {
        case EventType.feedBreast.rawValue:
            return NursingLabels.title(side: event.side)
        case EventType.feedBottle.rawValue:
            return "Bottle"
        case EventType.diaper.rawValue:
            let sub = event.subtype.map { " \($0)" } ?? ""
            return "Diaper\(sub)"
        case EventType.sleep.rawValue:
            return "Sleep"
        case EventType.medicine.rawValue:
            return event.subtype ?? "Medicine"
        case EventType.pump.rawValue:
            let side = event.side.map { " \($0.uppercased())" } ?? ""
            return "Pump\(side)"
        case EventType.activity.rawValue:
            return ActivityKind(event: event)?.title ?? "Outing"
        default:
            return event.type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func timelineDetail(_ event: EventDTO) -> String? {
        if let amount = event.amountValue {
            let unit = event.amountUnit ?? "oz"
            return "\(formatAmount(amount)) \(unit)"
        }
        if let duration = event.activeDuration {
            return PrototypeFormatters.compactDuration(duration)
        }
        return event.notes
    }

    private static func timelineAccent(_ event: EventDTO) -> TimelineAccent {
        if event.type.hasPrefix("feed_") { return .feed }
        if event.type == EventType.diaper.rawValue { return .diaper }
        if event.type == EventType.sleep.rawValue { return .sleep }
        if let activity = ActivityKind(event: event) { return activity.isOuting ? .outing : .crying }
        if event.type == EventType.activity.rawValue { return .outing }
        return .other
    }
}
