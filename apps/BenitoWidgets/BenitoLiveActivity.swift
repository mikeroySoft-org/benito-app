import ActivityKit
import AppIntents
import BenitoKit
import SwiftUI
import WidgetKit

/// Lock Screen, Dynamic Island, and Apple Watch Smart Stack presentation of the active
/// feed/sleep timer and time since the last diaper/feed. The app owns start/update/end; the
/// buttons run `LiveActivityIntent`s (apps/Shared/Intents) in the app's process.
struct BenitoLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BenitoActivityAttributes.self) { context in
            ActivityContentView(childName: context.attributes.childName, state: context.state)
                .activityBackgroundTint(Palette.canvas)
                .activitySystemActionForegroundColor(Palette.textPrimary)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(state.isPaused ? "Paused" : state.headlineLabel)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: state.isPaused ? "pause.fill" : state.headlineSymbol)
                    }
                    .font(.headline)
                    .foregroundStyle(state.headlineAccent)
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailingClock(state: state)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        (Text("Diaper ") + agoText(state.lastDiaperAt) + Text(" · Feed ") + agoText(state.lastFeedAt))
                            .font(.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if state.hasTimer {
                            TimerControls(state: state, style: .pills, height: 36)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: state.compactSymbol)
                    .foregroundStyle(state.compactAccent)
                    .accessibilityLabel(state.compactAccessibilityLabel)
            } compactTrailing: {
                CompactTrailingClock(state: state)
            } minimal: {
                Image(systemName: state.compactSymbol)
                    .foregroundStyle(state.compactAccent)
                    .accessibilityLabel(state.compactAccessibilityLabel)
            }
            .keylineTint(state.compactAccent)
        }
        // `.small` = Apple Watch Smart Stack (watchOS 11+), mirrored from the iPhone.
        .supplementalActivityFamilies([.small])
    }
}

/// Lock Screen / banner (`.medium`) vs. Apple Watch Smart Stack (`.small`).
private struct ActivityContentView: View {
    @Environment(\.activityFamily) private var family
    let childName: String
    let state: BenitoActivityAttributes.ContentState

    var body: some View {
        if family == .small {
            SmartStackView(state: state)
        } else {
            LockScreenView(childName: childName, state: state)
        }
    }
}

// MARK: - Lock Screen / banner

private struct LockScreenView: View {
    let childName: String
    let state: BenitoActivityAttributes.ContentState

    // Stacked vertically: side-by-side columns overflowed the card on iOS 26 and clipped
    // the stats off-screen. Lock Screen activities are capped at 160pt tall; with the control
    // row this is ~140pt (active) / ~130pt (idle).
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if state.hasTimer {
                HStack(alignment: .center, spacing: 10) {
                    if let clock = timerClock(state) {
                        clock
                            .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(state.headlineAccent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .accessibilityLabel(state.compactClockAccessibilityPrefix)
                    }
                    Spacer(minLength: 8)
                    TimerControls(state: state, style: .circles, height: 40)
                }
            }
            HStack(alignment: .top, spacing: 20) {
                StatLine(
                    title: "Last feed",
                    date: state.lastFeedAt,
                    detail: state.lastFeedLabel,
                    accent: Palette.feed
                )
                StatLine(
                    title: "Last diaper",
                    date: state.lastDiaperAt,
                    detail: state.diaperLabel,
                    accent: Palette.diaper
                )
            }
            if !state.hasTimer {
                StartButtons(height: 34)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .foregroundStyle(Palette.textPrimary)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if state.hasTimer {
                Label(state.timerLabel, systemImage: state.timerSymbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(state.headlineAccent)
                    .lineLimit(1)
                if state.isPaused {
                    PausedChip(tint: state.timerAccent)
                }
                Spacer(minLength: 8)
                Text(childName)
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            } else {
                Text(childName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StatLine: View {
    let title: String
    let date: Date?
    let detail: String?
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(accent)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                agoText(date)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PausedChip: View {
    let tint: Color

    var body: some View {
        Text("PAUSED")
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.2)))
            .accessibilityLabel("Paused")
    }
}

// MARK: - Apple Watch Smart Stack

/// Compact layout for the watchOS Smart Stack: one status row plus big buttons.
private struct SmartStackView: View {
    let state: BenitoActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.hasTimer {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: state.isPaused ? "pause.fill" : state.timerSymbol)
                        .font(.caption.weight(.bold))
                    Text(state.isPaused ? "Paused" : state.timerShortLabel)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let clock = timerClock(state) {
                        clock
                            .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel(state.compactClockAccessibilityPrefix)
                    }
                }
                .foregroundStyle(state.headlineAccent)
                TimerControls(state: state, style: .pills, height: 34)
            } else {
                (Text("Last diaper ") + agoText(state.lastDiaperAt))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                StartButtons(height: 34, compact: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Buttons

/// Pause/Resume + Stop for the active timer.
private struct TimerControls: View {
    enum Style {
        /// Icon-only circles (Lock Screen, next to the clock).
        case circles
        /// Full-width icon + title pills (Dynamic Island, Smart Stack).
        case pills
    }

    let state: BenitoActivityAttributes.ContentState
    let style: Style
    let height: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            if state.isPaused {
                control(
                    ResumeTimerIntent(),
                    title: "Resume",
                    symbol: "play.fill",
                    tint: state.timerAccent,
                    accessibilityLabel: "Resume \(state.timerNoun) timer"
                )
            } else {
                control(
                    PauseTimerIntent(),
                    title: "Pause",
                    symbol: "pause.fill",
                    tint: state.timerAccent,
                    accessibilityLabel: "Pause \(state.timerNoun) timer"
                )
            }
            control(
                StopTimerIntent(),
                title: "Stop",
                symbol: "stop.fill",
                tint: Palette.textPrimary,
                accessibilityLabel: "Stop \(state.timerNoun) timer"
            )
        }
    }

    private func control(
        _ intent: some AppIntent,
        title: String,
        symbol: String,
        tint: Color,
        accessibilityLabel: String
    ) -> some View {
        IntentButton(
            intent: intent,
            title: style == .pills ? title : nil,
            symbol: symbol,
            tint: tint,
            height: height,
            accessibilityLabel: accessibilityLabel
        )
    }
}

/// Idle row: Feed / Diaper / Sleep (mirrors Home thumbs).
private struct StartButtons: View {
    let height: CGFloat
    /// Icon-only titles for the Smart Stack.
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            IntentButton(
                intent: OpenFeedSheetIntent(),
                title: compact ? nil : "Feed",
                symbol: "drop.fill",
                tint: Palette.feed,
                height: height,
                fillsWidth: true,
                accessibilityLabel: "Log a feed"
            )
            IntentButton(
                intent: OpenDiaperSheetIntent(),
                title: compact ? nil : "Diaper",
                symbol: "circle.grid.cross.fill",
                tint: Palette.diaper,
                height: height,
                fillsWidth: true,
                accessibilityLabel: "Log a diaper"
            )
            IntentButton(
                intent: StartNapButtonIntent(),
                title: compact ? nil : "Sleep",
                symbol: "bed.double.fill",
                tint: Palette.sleep,
                height: height,
                fillsWidth: true,
                accessibilityLabel: "Start nap timer"
            )
        }
    }
}

/// `Button(intent:)` styled as a tinted circle (no title) or a rounded pill.
private struct IntentButton<Intent: AppIntent>: View {
    let intent: Intent
    let title: String?
    let symbol: String
    let tint: Color
    let height: CGFloat
    /// Icon-only buttons are circles unless asked to share the row width.
    var fillsWidth = false
    let accessibilityLabel: String

    var body: some View {
        Button(intent: intent) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: height * 0.4, weight: .bold))
                if let title {
                    Text(title)
                        .font(.system(size: height * 0.4, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, title == nil ? 0 : 8)
            .frame(width: isCircle ? height : nil, height: height)
            .frame(maxWidth: isCircle ? nil : .infinity)
            .background(background)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(LiveActivityBorderlessButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    private var isCircle: Bool { title == nil && !fillsWidth }

    @ViewBuilder
    private var background: some View {
        if isCircle {
            Circle().fill(tint.opacity(0.22))
        } else {
            Capsule(style: .continuous).fill(tint.opacity(0.22))
        }
    }
}


/// No system rounded-rect plate behind the pill/circle fill.
private struct LiveActivityBorderlessButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Dynamic Island clocks

private struct ExpandedTrailingClock: View {
    let state: BenitoActivityAttributes.ContentState

    var body: some View {
        Group {
            if let clock = timerClock(state) {
                clock
                    .foregroundStyle(state.headlineAccent)
            } else {
                agoText(state.lastFeedAt)
                    .foregroundStyle(Palette.textPrimary)
            }
        }
        .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
        .lineLimit(1)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct CompactTrailingClock: View {
    let state: BenitoActivityAttributes.ContentState

    var body: some View {
        Group {
            if let start = state.compactClockStart {
                countUpText(from: start, pausedAt: state.timerPausedAt)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(state.compactClockAccessibilityPrefix)
                    .accessibilityValue(countUpText(from: start, pausedAt: state.timerPausedAt))
            } else {
                Text("—")
                    .accessibilityLabel("No recent events")
            }
        }
        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundStyle(state.compactAccent)
        .lineLimit(1)
        // Timer text reserves its widest possible layout; pin a width so the island stays compact.
        .frame(width: 58, alignment: .trailing)
    }
}

// MARK: - Presentation helpers

/// "1 hr, 5 min ago" that keeps ticking on the Lock Screen, or an em dash when unknown.
private func agoText(_ date: Date?) -> Text {
    guard let date else { return Text("—") }
    return Text(date, style: .relative) + Text(" ago")
}

/// Count-up clock bounded to 24h. `Text(timerInterval:)` sizes itself for the widest string in
/// its range, so an open-ended (`distantFuture`) range reserves an enormous width and pushed the
/// Lock Screen layout off the card. Live Activities end long before 24h anyway. A `pausedAt`
/// freezes the clock at that instant.
private func countUpText(from start: Date, pausedAt: Date? = nil) -> Text {
    Text(
        timerInterval: start...start.addingTimeInterval(24 * 60 * 60),
        pauseTime: pausedAt.map { max($0, start) },
        countsDown: false
    )
}

/// Active timer clock excluding paused time (frozen while paused); nil without a timer.
private func timerClock(_ state: BenitoActivityAttributes.ContentState) -> Text? {
    guard let start = state.timerEffectiveStart else { return nil }
    return countUpText(from: start, pausedAt: state.timerPausedAt)
}

private extension BenitoActivityAttributes.ContentState {
    var timerAccent: Color {
        if isSleepTimer { return Palette.sleep }
        return activityTimer.map(BenitoPalette.accent(for:)) ?? Palette.feed
    }

    /// Timer accent, dimmed while paused.
    var liveTimerAccent: Color { isPaused ? timerAccent.opacity(0.55) : timerAccent }

    var timerLabel: String {
        if isSleepTimer { return "Sleeping" }
        if let activityTimer { return activityTimer.title }
        return NursingLabels.title(side: timerSide)
    }

    /// Smart Stack label: "Left" / "Sleep" / "Walk".
    var timerShortLabel: String {
        if isSleepTimer { return "Sleep" }
        if let activityTimer { return activityTimer.title }
        return NursingLabels.short(side: timerSide)
    }

    /// Spoken noun for button labels: "feed" / "nap" / "walk" / "crying".
    var timerNoun: String {
        if isSleepTimer { return "nap" }
        return activityTimer?.noun ?? "feed"
    }

    var timerSymbol: String {
        if isSleepTimer { return "bed.double.fill" }
        return activityTimer?.systemImage ?? "drop.fill"
    }

    /// Headline = active timer, else the last feed.
    var headlineLabel: String { hasTimer ? timerLabel : "Last feed" }
    var headlineSymbol: String { hasTimer ? timerSymbol : "clock" }
    var headlineAccent: Color { hasTimer ? liveTimerAccent : Palette.feed }

    var diaperLabel: String? { lastDiaperSubtype.map { $0.capitalized } }

    /// Compact trailing clock: active timer (pause-excluded), else time since last diaper
    /// (falling back to last feed).
    var compactClockStart: Date? { timerEffectiveStart ?? lastDiaperAt ?? lastFeedAt }

    var compactSymbol: String {
        if isPaused { return "pause.fill" }
        return hasTimer ? timerSymbol : "clock"
    }

    var compactAccent: Color {
        if hasTimer { return liveTimerAccent }
        return lastDiaperAt != nil ? Palette.diaper : Palette.feed
    }

    var compactAccessibilityLabel: String {
        if hasTimer {
            let timer: String
            if isSleepTimer {
                timer = "Sleep timer"
            } else if let activityTimer {
                timer = "\(activityTimer.title) timer"
            } else {
                timer = "\(timerLabel) feed timer"
            }
            return isPaused ? "\(timer) paused" : "\(timer) running"
        }
        return lastDiaperAt != nil ? "Time since last diaper" : "Time since last feed"
    }

    var compactClockAccessibilityPrefix: String {
        if hasTimer {
            if let activityTimer {
                return isPaused ? "\(activityTimer.title) paused at" : "\(activityTimer.title) for"
            }
            if isPaused { return isSleepTimer ? "Nap paused at" : "Feed paused at" }
            return isSleepTimer ? "Sleeping for" : "Feeding for"
        }
        return lastDiaperAt != nil ? "Since last diaper" : "Since last feed"
    }
}

/// Mirrors the app's `DesignTokens` (the extension can't see app sources).
private enum Palette {
    static let canvas = BenitoPalette.canvas
    static let textPrimary = BenitoPalette.textPrimary
    static let textSecondary = BenitoPalette.textSecondary
    static let feed = BenitoPalette.feed
    static let diaper = BenitoPalette.diaper
    static let sleep = BenitoPalette.sleep
}

// MARK: - Previews

extension BenitoActivityAttributes {
    fileprivate static var preview: BenitoActivityAttributes {
        BenitoActivityAttributes(childName: "Sam")
    }
}

extension BenitoActivityAttributes.ContentState {
    fileprivate static var breastLeft: Self {
        Self(
            timerKind: "feed_breast",
            timerSide: "L",
            timerStartedAt: Date.now.addingTimeInterval(-14 * 60),
            lastDiaperAt: Date.now.addingTimeInterval(-52 * 60),
            lastDiaperSubtype: "wet",
            lastFeedAt: Date.now.addingTimeInterval(-2 * 3600 - 10 * 60),
            lastFeedLabel: "Bottle 3 oz"
        )
    }

    /// Left-side feed paused for burping: 9 min fed, 2 min of earlier pauses, paused 1 min ago.
    fileprivate static var breastLeftPaused: Self {
        Self(
            timerKind: "feed_breast",
            timerSide: "L",
            timerStartedAt: Date.now.addingTimeInterval(-12 * 60),
            timerPausedAt: Date.now.addingTimeInterval(-60),
            timerPausedSeconds: 2 * 60,
            lastDiaperAt: Date.now.addingTimeInterval(-52 * 60),
            lastDiaperSubtype: "wet",
            lastFeedAt: Date.now.addingTimeInterval(-2 * 3600 - 10 * 60),
            lastFeedLabel: "Bottle 3 oz"
        )
    }

    fileprivate static var sleeping: Self {
        Self(
            timerKind: "sleep",
            timerStartedAt: Date.now.addingTimeInterval(-3600 - 23 * 60),
            lastDiaperAt: Date.now.addingTimeInterval(-95 * 60),
            lastDiaperSubtype: "both",
            lastFeedAt: Date.now.addingTimeInterval(-100 * 60),
            lastFeedLabel: "Nursing: Right"
        )
    }

    fileprivate static var idle: Self {
        Self(
            lastDiaperAt: Date.now.addingTimeInterval(-38 * 60),
            lastDiaperSubtype: "dirty",
            lastFeedAt: Date.now.addingTimeInterval(-1 * 3600 - 42 * 60),
            lastFeedLabel: "Nursing: Left"
        )
    }
}

#Preview("Lock Screen", as: .content, using: BenitoActivityAttributes.preview) {
    BenitoLiveActivity()
} contentStates: {
    BenitoActivityAttributes.ContentState.breastLeft
    BenitoActivityAttributes.ContentState.breastLeftPaused
    BenitoActivityAttributes.ContentState.sleeping
    BenitoActivityAttributes.ContentState.idle
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: BenitoActivityAttributes.preview) {
    BenitoLiveActivity()
} contentStates: {
    BenitoActivityAttributes.ContentState.breastLeft
    BenitoActivityAttributes.ContentState.breastLeftPaused
    BenitoActivityAttributes.ContentState.sleeping
    BenitoActivityAttributes.ContentState.idle
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: BenitoActivityAttributes.preview) {
    BenitoLiveActivity()
} contentStates: {
    BenitoActivityAttributes.ContentState.breastLeft
    BenitoActivityAttributes.ContentState.breastLeftPaused
    BenitoActivityAttributes.ContentState.idle
}

#Preview("Island minimal", as: .dynamicIsland(.minimal), using: BenitoActivityAttributes.preview) {
    BenitoLiveActivity()
} contentStates: {
    BenitoActivityAttributes.ContentState.sleeping
}

// Repro #12: compare the same controls across host appearance and Always On states.
#Preview("Timer appearance matrix") {
    ScrollView {
        VStack(spacing: 16) {
            ForEach([false, true], id: \.self) { small in
                ForEach([false, true], id: \.self) { dark in
                    ForEach([false, true], id: \.self) { reduced in
                        ForEach([false, true], id: \.self) { paused in
                            VStack {
                                Text("\(small ? "Watch" : "Lock Screen") · \(dark ? "dark" : "light") · \(reduced ? "dim" : "normal") · \(paused ? "paused" : "running")")
                                    .font(.caption2)
                                ActivityContentView(
                                    childName: "Sam",
                                    state: paused ? .breastLeftPaused : .breastLeft
                                )
                                .environment(\.activityFamily, small ? .small : .medium)
                                .environment(\.isLuminanceReduced, reduced)
                                .background(Palette.canvas)
                                .environment(\.colorScheme, dark ? .dark : .light)
                                .frame(width: small ? 184 : 360)
                            }
                        }
                    }
                }
            }
        }
    }
}
