import Foundation

/// Which breast duration absorbs a nursing start-time edit.
/// `both` is the Huckleberry default: split across sides that already have time,
/// and if only one side has been used the whole delta stays on that side
/// (so "forgot to start" does not invent a phantom side).
public enum NursingSideScope: String, Codable, CaseIterable, Sendable {
    case left
    case both
    case right
}

/// Frozen (already switched-away) side time plus the live segment.
public struct NursingDurationBooks: Equatable, Sendable {
    public var frozenLeft: TimeInterval
    public var frozenRight: TimeInterval
    /// Elapsed on `activeSide` that is still the running timer (not frozen).
    public var live: TimeInterval
    /// `"L"` or `"R"`.
    public var activeSide: String

    public init(frozenLeft: TimeInterval, frozenRight: TimeInterval, live: TimeInterval, activeSide: String) {
        self.frozenLeft = frozenLeft
        self.frozenRight = frozenRight
        self.live = live
        self.activeSide = activeSide.uppercased() == "R" ? "R" : "L"
    }

    public var leftTotal: TimeInterval { frozenLeft + (activeSide == "L" ? live : 0) }
    public var rightTotal: TimeInterval { frozenRight + (activeSide == "R" ? live : 0) }
    public var total: TimeInterval { leftTotal + rightTotal }
}

/// How to move a nursing session's start without breaking side totals.
///
/// `appliedDelta` > 0 means the session started earlier and durations grew.
/// `liveDelta` is the part of that change that belongs on the running timer
/// (`timer.startedAt` moves earlier by `liveDelta`). Frozen deltas belong on
/// completed side segments.
public struct NursingStartPlan: Equatable, Sendable {
    public var appliedDelta: TimeInterval
    public var newSessionStart: Date
    public var frozenLeft: TimeInterval
    public var frozenRight: TimeInterval
    public var live: TimeInterval
    public var liveDelta: TimeInterval
    public var frozenLeftDelta: TimeInterval
    public var frozenRightDelta: TimeInterval

    public var durationDelta: TimeInterval { liveDelta + frozenLeftDelta + frozenRightDelta }
}

public enum NursingStartAdjustment {
    /// `delta` is `oldSessionStart - newStart` (positive → earlier → more duration).
    /// Shrink stops at zero on every side. Growth on the active side prefers the
    /// live segment; frozen time on that side only changes when the shrink eats
    /// past the live segment into already-saved switches.
    public static func plan(
        sessionStart: Date,
        delta: TimeInterval,
        scope: NursingSideScope,
        books: NursingDurationBooks
    ) -> NursingStartPlan {
        let left0 = max(0, books.leftTotal)
        let right0 = max(0, books.rightTotal)
        let shrinkCap: TimeInterval
        switch scope {
        case .left: shrinkCap = left0
        case .right: shrinkCap = right0
        case .both: shrinkCap = left0 + right0
        }
        var applied = delta
        if applied < -shrinkCap { applied = -shrinkCap }

        var addLeft: TimeInterval = 0
        var addRight: TimeInterval = 0
        switch scope {
        case .left:
            addLeft = applied
        case .right:
            addRight = applied
        case .both:
            let leftUsed = left0 > 0.5
            let rightUsed = right0 > 0.5
            if leftUsed && rightUsed {
                addLeft = applied / 2
                addRight = applied - addLeft
                if left0 + addLeft < 0 {
                    addLeft = -left0
                    addRight = applied - addLeft
                } else if right0 + addRight < 0 {
                    addRight = -right0
                    addLeft = applied - addRight
                }
            } else if leftUsed {
                addLeft = applied
            } else if rightUsed {
                addRight = applied
            } else if books.activeSide == "R" {
                addRight = applied
            } else {
                addLeft = applied
            }
        }

        let newLeft = max(0, left0 + addLeft)
        let newRight = max(0, right0 + addRight)
        let appliedDelta = (newLeft - left0) + (newRight - right0)

        var frozenLeft = max(0, books.frozenLeft)
        var frozenRight = max(0, books.frozenRight)
        var live = max(0, books.live)
        if books.activeSide == "L" {
            if newLeft >= frozenLeft {
                live = newLeft - frozenLeft
            } else {
                live = 0
                frozenLeft = newLeft
            }
            frozenRight = newRight
        } else {
            if newRight >= frozenRight {
                live = newRight - frozenRight
            } else {
                live = 0
                frozenRight = newRight
            }
            frozenLeft = newLeft
        }

        return NursingStartPlan(
            appliedDelta: appliedDelta,
            newSessionStart: sessionStart.addingTimeInterval(-appliedDelta),
            frozenLeft: frozenLeft,
            frozenRight: frozenRight,
            live: live,
            liveDelta: live - max(0, books.live),
            frozenLeftDelta: frozenLeft - max(0, books.frozenLeft),
            frozenRightDelta: frozenRight - max(0, books.frozenRight)
        )
    }
}
