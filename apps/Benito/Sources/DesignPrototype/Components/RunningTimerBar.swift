import BenitoKit
import SwiftUI

/// Shared labelling for running timers (`feed_breast` with side L/R, `sleep`, or an
/// `activity` span — `walk` / `car_ride` / `crying`). Used by `ActiveTimerView` and `RunningTimerBar` so both
/// surfaces read the same.
enum RunningTimerLabel {
    static func isSleep(kind: String?) -> Bool {
        (kind ?? "").lowercased().contains("sleep")
    }

    /// Nursing timer (the only kind with a side and the feed sheet's controls).
    static func isNursing(kind: String?) -> Bool {
        !isSleep(kind: kind) && ActivityKind(timerKind: kind) == nil
    }

    /// Visible label, e.g. "Nursing: Left", "Nursing", "Sleep", "Walk", "Crying".
    static func title(kind: String?, side: String?) -> String {
        if isSleep(kind: kind) { return "Sleep" }
        if let activity = ActivityKind(timerKind: kind) { return activity.title }
        return NursingLabels.title(side: side)
    }

    /// VoiceOver label, e.g. "Nursing left", "Nursing right", "Sleep", "Car ride".
    static func spokenTitle(kind: String?, side: String?) -> String {
        if isSleep(kind: kind) { return "Sleep" }
        if let activity = ActivityKind(timerKind: kind) { return activity.title }
        return NursingLabels.spoken(side: side)
    }

    static func accent(kind: String?) -> Color {
        if isSleep(kind: kind) { return DesignTokens.sleep }
        if let activity = ActivityKind(timerKind: kind) { return DesignTokens.accent(for: activity) }
        return DesignTokens.feed
    }

    static func systemImage(kind: String?) -> String {
        if isSleep(kind: kind) { return "moon.zzz.fill" }
        if let activity = ActivityKind(timerKind: kind) { return activity.systemImage }
        return "drop.fill"
    }

    /// Whole-minute spoken duration, e.g. "7 minutes", "1 hour, 5 minutes".
    static func spokenDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        guard total >= 60 else { return "under a minute" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .full
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(total - total % 60)) ?? PrototypeFormatters.timerClock(interval)
    }
}

/// Compact bar pinned above the tab bar while a timer is active and the timer screen is hidden.
/// Tap = reopen the timer screen; inline Pause/Resume and Stop control the timer.
struct RunningTimerBar: View {
    let timer: ActiveTimerSnapshot
    let onOpen: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void

    private var accent: Color { RunningTimerLabel.accent(kind: timer.kind) }
    private var spokenTitle: String { RunningTimerLabel.spokenTitle(kind: timer.kind, side: timer.side) }
    private var title: String {
        let base = RunningTimerLabel.title(kind: timer.kind, side: timer.side)
        return timer.isPaused ? "\(base) · Paused" : base
    }

    var body: some View {
        // Keep Liquid Glass / materials OUTSIDE the 1 Hz tick. Rebuilding
        // `.glassEffect(interactive:)` every second was a primary memory-pressure suspect
        // during long debug sessions with a running timer.
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: timer.isPaused ? "pause.circle" : RunningTimerLabel.systemImage(kind: timer.kind))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(timer.isPaused ? DesignTokens.textSecondary : accent)
                        .frame(width: 36, height: 36)
                        .background(
                            (timer.isPaused ? DesignTokens.textSecondary : accent).opacity(0.18),
                            in: Circle()
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DesignTokens.textSecondary)
                            .lineLimit(1)
                        clockLabel
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(BenitoBorderlessButtonStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityClockLabel)
            .accessibilityHint("Double-tap to open.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: timer.isPaused ? "Resume timer" : "Pause timer", togglePause)
            .accessibilityAction(named: "Stop timer", onStop)

            iconButton(
                systemImage: timer.isPaused ? "play.fill" : "pause.fill",
                tint: timer.isPaused ? DesignTokens.active : accent,
                label: timer.isPaused ? "Resume timer" : "Pause timer",
                action: togglePause
            )

            iconButton(
                systemImage: "stop.fill",
                tint: DesignTokens.fault,
                label: "Stop timer",
                role: .destructive,
                action: onStop
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: DesignTokens.thumbMin)
        .benitoFloatingCapsuleChrome(
            tint: DesignTokens.bgCardElevated,
            // Non-interactive: chrome sits above the tab bar for long sleeps; interactive
            // glass was re-sampling on every nearby thumb tap while the 1Hz digits tick.
            interactive: false,
            fallbackOpacity: 0.92
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(accent.opacity(timer.isPaused ? 0.25 : 0.55), lineWidth: 1.5)
        )
        .padding(.horizontal, DesignTokens.gutter)
        .padding(.vertical, 8)
    }

    /// Only the digits tick; paused clocks stay frozen (no TimelineView schedule).
    @ViewBuilder
    private var clockLabel: some View {
        if timer.isPaused {
            clockText(timer.elapsed(at: timer.timer.pausedAt ?? .now))
        } else {
            TimelineView(.periodic(from: timer.startedAt, by: 1)) { context in
                clockText(timer.elapsed(at: context.date))
            }
        }
    }

    private func clockText(_ elapsed: TimeInterval) -> some View {
        Text(PrototypeFormatters.timerClock(elapsed))
            .font(.system(.title3, design: .rounded).weight(.bold))
            .foregroundStyle(timer.isPaused ? DesignTokens.textSecondary : DesignTokens.textPrimary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var accessibilityClockLabel: String {
        let elapsed = timer.elapsed(at: .now)
        return "\(spokenTitle) timer \(timer.isPaused ? "paused" : "running"), \(RunningTimerLabel.spokenDuration(elapsed))"
    }

    private func togglePause() {
        if timer.isPaused { onResume() } else { onPause() }
    }

    private func iconButton(
        systemImage: String,
        tint: Color,
        label: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.16), in: Circle())
                .overlay(Circle().stroke(tint.opacity(0.5), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
        .accessibilityLabel(label)
    }
}

#Preview {
    VStack {
        Spacer()
        RunningTimerBar(
            timer: ActiveTimerSnapshot(
                id: UUID(),
                kind: "feed_breast",
                side: "L",
                startedAt: Date().addingTimeInterval(-7 * 60 - 22)
            ),
            onOpen: {},
            onPause: {},
            onResume: {},
            onStop: {}
        )
        RunningTimerBar(
            timer: ActiveTimerSnapshot(
                id: UUID(),
                kind: "sleep",
                side: nil,
                startedAt: Date().addingTimeInterval(-65 * 60),
                pausedAt: Date().addingTimeInterval(-2 * 60)
            ),
            onOpen: {},
            onPause: {},
            onResume: {},
            onStop: {}
        )
    }
    .background(DesignTokens.bgCanvas)
}
