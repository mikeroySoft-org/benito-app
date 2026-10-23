#if canImport(ActivityKit)
import ActivityKit
import BenitoKit
import Foundation

extension BenitoActivityAttributes.ContentState {
    /// Lock Screen / Dynamic Island / Smart Stack content for `state`, or nil when there is
    /// nothing to show. Shared by the app's `LiveActivityController` and the App Intents.
    static func from(state: BabyStateDTO?) -> Self? {
        // A stopped feed must not leave the island counting. Last feed/diaper alone
        // used to count as content, and the compact clock then kept ticking via
        // `Text(timerInterval:)` from `lastDiaperAt` / `lastFeedAt` — on this phone
        // and on any other phone that applied the ended timer.
        guard let timer = state?.activeTimer, timer.isActive else { return nil }
        let diaper = state?.lastDiaper
        let feed = state?.lastFeed
        let content = Self(
            timerKind: timer.kind,
            timerSide: timer.side?.uppercased(),
            // Timestamps are phone-authored; same domain as Text(timerInterval:) / in-app elapsed.
            timerStartedAt: timer.startedAt,
            timerPausedAt: timer.isPaused ? timer.pausedAt : nil,
            timerPausedSeconds: timer.pausedSeconds,
            lastDiaperAt: diaper?.startedAt,
            lastDiaperSubtype: diaper?.subtype,
            lastFeedAt: feed.map { $0.endedAt ?? $0.startedAt },
            lastFeedLabel: feed.map(feedLabel)
        )
        return content.hasTimer ? content : nil
    }

    private static func feedLabel(_ event: EventDTO) -> String {
        switch event.type {
        case EventType.feedBreast.rawValue:
            return NursingLabels.title(side: event.side)
        case EventType.feedBottle.rawValue:
            guard let amount = event.amountValue else { return "Bottle" }
            return "Bottle \(formatAmount(amount)) \(event.amountUnit ?? "oz")"
        case EventType.feedSolid.rawValue:
            return "Solids"
        default:
            return event.type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func formatAmount(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}

/// Update/end primitives for the existing Benito Live Activity. Starting one stays with the
/// app's `LiveActivityController` (`Activity.request` needs the app in the foreground); intents
/// running in the background only refresh or end what is already on screen.
enum LiveActivitySync {
    typealias ContentState = BenitoActivityAttributes.ContentState

    /// Pushes `content` to every live Benito activity, or ends them when `content` is nil
    /// (nothing left to show). No-op when no activity is running.
    static func apply(_ content: ContentState?) async {
        let live = Activity<BenitoActivityAttributes>.activities.filter(isLive)
        guard let content else {
            await end(live)
            return
        }
        for activity in live where activity.content.state != content {
            await update(activity, content: content)
        }
    }

    static func update(_ activity: Activity<BenitoActivityAttributes>, content: ContentState) async {
        await activity.update(ActivityContent(state: content, staleDate: nil))
        BenitoLog.ui.notice("liveActivity updated \(activity.id, privacy: .public) timer=\(content.timerKind ?? "none", privacy: .public) paused=\(content.isPaused, privacy: .public)")
    }

    static func end(_ activities: [Activity<BenitoActivityAttributes>]) async {
        // Nil final content keeps the last count-up frame until dismissal actually
        // lands, so the island can keep ticking. Clear the timer dates first.
        let cleared = ContentState()
        for activity in activities {
            await activity.end(
                ActivityContent(state: cleared, staleDate: .now),
                dismissalPolicy: .immediate
            )
            BenitoLog.ui.notice("liveActivity ended \(activity.id, privacy: .public)")
        }
    }

    static func isLive(_ activity: Activity<BenitoActivityAttributes>) -> Bool {
        switch activity.activityState {
        case .active, .stale:
            return true
        default:
            // .ended, .dismissed, and (iOS 26) scheduled .pending activities.
            return false
        }
    }
}
#endif
