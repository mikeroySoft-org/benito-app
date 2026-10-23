#if canImport(ActivityKit)
import ActivityKit
import BenitoKit
import Foundation

/// Live Activity payload shared by the Benito app (which starts/updates it) and the
/// BenitoWidgets extension (which renders it). Compiled into both targets from `apps/Shared/`.
/// Mapping from BenitoKit state lives in `LiveActivityContent.swift`.
struct BenitoActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Active timer kind: `"feed_breast"`, `"sleep"`, or an outing (`"walk"` / `"car_ride"`); nil when no timer is running or paused.
        var timerKind: String?
        /// Breast side (`"L"` / `"R"`) for `feed_breast` timers.
        var timerSide: String?
        var timerStartedAt: Date?
        /// Start of the pause in progress; nil while the timer runs.
        var timerPausedAt: Date?
        /// Seconds of completed pauses (the pause in progress is not included).
        var timerPausedSeconds: Int
        var lastDiaperAt: Date?
        /// Raw diaper subtype (`wet` / `dirty` / `both`).
        var lastDiaperSubtype: String?
        /// When the last feed finished (`endedAt ?? startedAt`).
        var lastFeedAt: Date?
        /// Human label for the last feed, e.g. "Nursing: Left" or "Bottle 3 oz".
        var lastFeedLabel: String?

        init(
            timerKind: String? = nil,
            timerSide: String? = nil,
            timerStartedAt: Date? = nil,
            timerPausedAt: Date? = nil,
            timerPausedSeconds: Int = 0,
            lastDiaperAt: Date? = nil,
            lastDiaperSubtype: String? = nil,
            lastFeedAt: Date? = nil,
            lastFeedLabel: String? = nil
        ) {
            self.timerKind = timerKind
            self.timerSide = timerSide
            self.timerStartedAt = timerStartedAt
            self.timerPausedAt = timerPausedAt
            self.timerPausedSeconds = timerPausedSeconds
            self.lastDiaperAt = lastDiaperAt
            self.lastDiaperSubtype = lastDiaperSubtype
            self.lastFeedAt = lastFeedAt
            self.lastFeedLabel = lastFeedLabel
        }

        enum CodingKeys: String, CodingKey {
            case timerKind, timerSide, timerStartedAt, timerPausedAt, timerPausedSeconds
            case lastDiaperAt, lastDiaperSubtype, lastFeedAt, lastFeedLabel
        }

        /// Tolerates payloads from builds that predate pausing (no `timerPausedSeconds`), e.g. an
        /// activity adopted after an app update.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            timerKind = try c.decodeIfPresent(String.self, forKey: .timerKind)
            timerSide = try c.decodeIfPresent(String.self, forKey: .timerSide)
            timerStartedAt = try c.decodeIfPresent(Date.self, forKey: .timerStartedAt)
            timerPausedAt = try c.decodeIfPresent(Date.self, forKey: .timerPausedAt)
            timerPausedSeconds = try c.decodeIfPresent(Int.self, forKey: .timerPausedSeconds) ?? 0
            lastDiaperAt = try c.decodeIfPresent(Date.self, forKey: .lastDiaperAt)
            lastDiaperSubtype = try c.decodeIfPresent(String.self, forKey: .lastDiaperSubtype)
            lastFeedAt = try c.decodeIfPresent(Date.self, forKey: .lastFeedAt)
            lastFeedLabel = try c.decodeIfPresent(String.self, forKey: .lastFeedLabel)
        }

        /// True when a feed/sleep timer is running or paused.
        var hasTimer: Bool { timerStartedAt != nil }

        /// True when the active timer is paused.
        var isPaused: Bool { hasTimer && timerPausedAt != nil }

        /// Timer start shifted by completed pauses, so a count-up from here excludes paused time.
        var timerEffectiveStart: Date? {
            timerStartedAt?.addingTimeInterval(TimeInterval(timerPausedSeconds))
        }

        /// True when there is anything worth showing on the Lock Screen / Dynamic Island.
        var hasContent: Bool { hasTimer || lastDiaperAt != nil || lastFeedAt != nil }

        var isSleepTimer: Bool { timerKind?.lowercased().contains("sleep") == true }

        /// Walk / car ride / crying when the active timer is an `activity` span.
        var activityTimer: ActivityKind? { ActivityKind(timerKind: timerKind) }
    }

    var childName: String
}
#endif
