import BenitoKit
import SwiftUI

/// Nursing (breast) timer panel: Start Time, main clock, L/R side controls with
/// per-side accumulated time, and the blue Save. Shared by the Feed sheet's Nursing
/// segment and the running-feed `ActiveTimerView`, so both surfaces stay identical.
struct NursingFeedPanel: View {
    var model: AppModel
    /// Called after Save stops the timer (parent dismisses its sheet).
    var onSaved: () -> Void

    @State private var isBusy = false
    @State private var showNursingStart = false

    /// Active breast timer only (sleep timers stay on the sleep surfaces).
    private var breastTimer: TimerDTO? {
        guard let t = model.babyState?.activeTimer, t.isActive else { return nil }
        guard RunningTimerLabel.isNursing(kind: t.kind) else { return nil }
        return t
    }

    var body: some View {
        nursingPanel
            .onAppear {
                if let timer = breastTimer { model.ensureNursingSession(for: timer) }
            }
            .sheet(isPresented: $showNursingStart) {
                let started = model.nursingLive?.sessionStart ?? breastTimer?.startedAt ?? Date()
                StartTimeEditorSheet(
                    accent: DesignTokens.feed,
                    initial: started,
                    range: model.nursingStartBounds(),
                    showsSideScope: true,
                    isPresented: $showNursingStart
                ) { newStart, scope in
                    let ok = await model.adjustRunningActivityStart(to: newStart, nursingScope: scope)
                    return ok ? nil : model.status
                }
            }
    }

    private var nursingPanel: some View {
        let timer = breastTimer
        let paused = timer?.isPaused == true
        let activeSide = timer?.side?.uppercased()

        // Digit-only 1Hz TimelineViews (main clock + active side); chrome/Save stay outside.
        return nursingPanelContent(
            timer: timer,
            paused: paused,
            activeSide: activeSide
        )
    }

    private func nursingPanelContent(
        timer: TimerDTO?,
        paused: Bool,
        activeSide: String?
    ) -> some View {
        let startedAt = model.nursingLive?.sessionStart ?? timer?.startedAt
        // Digits may tick; L/R button chrome + Save stay OUTSIDE any TimelineView.
        // Putting Circles/Buttons inside a 1Hz schedule was a jetsam suspect on long nursing.
        // Start Time row stays outside the tick too.
        return VStack(spacing: 28) {
            if timer != nil, let startedAt {
                StartTimeRow(date: startedAt, accent: DesignTokens.feed) {
                    showNursingStart = true
                }
            }

            nursingMainClock(timer: timer, paused: paused)

            nursingSideRow(
                activeSide: activeSide,
                timer: timer,
                paused: paused
            )

            if timer != nil {
                PrimaryLogButton(
                    title: "Save",
                    systemImage: "checkmark.circle.fill",
                    accent: DesignTokens.accentBlue,
                    isBusy: isBusy
                ) {
                    saveBreast()
                }
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
        .onAppear {
            if let timer { model.ensureNursingSession(for: timer) }
        }
        .onChange(of: timer?.id) { _, _ in
            if let timer = breastTimer { model.ensureNursingSession(for: timer) }
        }
    }

    /// Main nursing clock — TimelineView wraps digit Texts only (no side chrome).
    @ViewBuilder
    private func nursingMainClock(timer: TimerDTO?, paused: Bool) -> some View {
        if let timer, !paused {
            TimelineView(.periodic(from: timer.startedAt, by: 1)) { context in
                let segmentElapsed = liveSegmentSeconds(
                    timer: timer,
                    liveSegmentElapsed: timer.elapsed(at: context.date)
                )
                nursingClockDigits(
                    elapsed: totalNursingElapsed(segmentElapsed: segmentElapsed),
                    paused: false
                )
            }
        } else {
            let segmentElapsed = liveSegmentSeconds(timer: timer, liveSegmentElapsed: nil)
            nursingClockDigits(
                elapsed: totalNursingElapsed(segmentElapsed: segmentElapsed),
                paused: paused
            )
        }
    }

    /// Main clock = L accumulated + R accumulated + live segment on the active side.
    private func totalNursingElapsed(segmentElapsed: TimeInterval) -> TimeInterval {
        let left = model.nursingLive?.frozenLeft ?? 0
        let right = model.nursingLive?.frozenRight ?? 0
        return left + right + max(0, segmentElapsed)
    }

    /// Live segment seconds for the current timer, or 0 while a just-folded timer is suppressed.
    private func liveSegmentSeconds(timer: TimerDTO?, liveSegmentElapsed: TimeInterval?) -> TimeInterval {
        guard let timer else { return 0 }
        if timer.id == model.nursingLive?.suppressTimerId { return 0 }
        if let liveSegmentElapsed { return max(0, liveSegmentElapsed) }
        return max(0, timer.elapsed(at: .now))
    }

    private func nursingSideRow(
        activeSide: String?,
        timer: TimerDTO?,
        paused: Bool
    ) -> some View {
        HStack(spacing: 28) {
            nursingSideButton(
                side: "L",
                activeSide: activeSide,
                timer: timer,
                paused: paused
            )
            nursingSideButton(
                side: "R",
                activeSide: activeSide,
                timer: timer,
                paused: paused
            )
        }
        .padding(.top, 4)
    }

    private func nursingClockDigits(elapsed: TimeInterval, paused: Bool) -> some View {
        let parts = Self.clockParts(elapsed)
        return VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                clockDigit(parts.hours)
                Text(":")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(paused ? DesignTokens.textTertiary : DesignTokens.textSecondary)
                clockDigit(parts.minutes)
                Text(":")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(paused ? DesignTokens.textTertiary : DesignTokens.textSecondary)
                clockDigit(parts.seconds)
            }
            .monospacedDigit()
            .opacity(paused ? 0.55 : 1)

            HStack(spacing: 0) {
                clockUnit("HOURS")
                clockUnit("MIN")
                clockUnit("SEC")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(paused ? "Paused, \(parts.hours) hours \(parts.minutes) minutes \(parts.seconds) seconds" : "\(parts.hours) hours \(parts.minutes) minutes \(parts.seconds) seconds")
    }

    private func clockDigit(_ value: Int) -> some View {
        // No `.contentTransition(.numericText())` on the 1Hz path — it allocates
        // transition state every second for the life of a nursing session.
        Text(String(format: "%02d", value))
            .font(.system(size: 48, weight: .bold, design: .rounded))
            .foregroundStyle(DesignTokens.textPrimary)
            .frame(minWidth: 64)
    }

    private func clockUnit(_ label: String) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .tracking(1.0)
            .foregroundStyle(DesignTokens.textTertiary)
            .frame(maxWidth: .infinity)
    }

    private func nursingSideButton(
        side: String,
        activeSide: String?,
        timer: TimerDTO?,
        paused: Bool
    ) -> some View {
        let isActiveSide = activeSide == side
        let showPause = isActiveSide && !paused
        let icon = showPause ? "pause.fill" : "play.fill"
        let fill: Color = {
            if isActiveSide && !paused { return DesignTokens.feed }
            if isActiveSide && paused { return DesignTokens.feed.opacity(0.45) }
            return DesignTokens.bgCardElevated
        }()
        let iconColor: Color = (isActiveSide && !paused) ? DesignTokens.onAccent : DesignTokens.textPrimary
        let timeColor: Color = (isActiveSide && !paused) ? DesignTokens.onAccent : DesignTokens.feed

        return Button {
            tapBreastSide(side)
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            DesignTokens.feed.opacity(isActiveSide ? 0.9 : 0.35),
                            style: StrokeStyle(lineWidth: 2, dash: isActiveSide ? [] : [6, 5])
                        )
                        .frame(width: 118, height: 118)
                    Circle()
                        .fill(fill)
                        .frame(width: 100, height: 100)
                    VStack(spacing: 6) {
                        Image(systemName: icon)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(iconColor)
                        // Digits only on the 1Hz path — Circle/Image chrome stays outside.
                        nursingSideElapsedText(
                            side: side,
                            isActiveSide: isActiveSide,
                            timer: timer,
                            paused: paused,
                            timeColor: timeColor
                        )
                    }
                }
                Text(side)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(isActiveSide ? DesignTokens.feed : DesignTokens.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
        .disabled(isBusy)
        .accessibilityLabel(breastSideAccessibility(side: side, isActiveSide: isActiveSide, paused: paused))
    }

    /// Inactive / paused: frozen Text. Active running: digit-only TimelineView.
    @ViewBuilder
    private func nursingSideElapsedText(
        side: String,
        isActiveSide: Bool,
        timer: TimerDTO?,
        paused: Bool,
        timeColor: Color
    ) -> some View {
        let frozen = side == "L" ? (model.nursingLive?.frozenLeft ?? 0) : (model.nursingLive?.frozenRight ?? 0)
        if isActiveSide, let timer, !paused {
            TimelineView(.periodic(from: timer.startedAt, by: 1)) { context in
                let segment = liveSegmentSeconds(
                    timer: timer,
                    liveSegmentElapsed: timer.elapsed(at: context.date)
                )
                Text(PrototypeFormatters.timerClock(frozen + max(0, segment)))
                    .font(.system(.callout, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(timeColor)
            }
        } else if isActiveSide {
            let segment = liveSegmentSeconds(timer: timer, liveSegmentElapsed: nil)
            Text(PrototypeFormatters.timerClock(frozen + max(0, segment)))
                .font(.system(.callout, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(timeColor)
        } else {
            Text(PrototypeFormatters.timerClock(frozen))
                .font(.system(.callout, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(timeColor)
        }
    }

    private func breastSideAccessibility(side: String, isActiveSide: Bool, paused: Bool) -> String {
        let name = side == "L" ? "Left" : "Right"
        if !isActiveSide { return "Start \(name.lowercased()) breast timer" }
        if paused { return "Resume \(name.lowercased()) breast timer" }
        return "Pause \(name.lowercased()) breast timer"
    }

    private func tapBreastSide(_ side: String) {
        guard !isBusy else { return }
        let upper = side.uppercased()
        if let timer = breastTimer {
            let current = timer.side?.uppercased()
            if current == upper {
                isBusy = true
                Task {
                    if timer.isPaused {
                        await model.resumeActiveTimer()
                    } else {
                        await model.pauseActiveTimer()
                    }
                    isBusy = false
                }
                return
            }
            // Switch sides: freeze current side elapsed, persist that segment via stop
            // (same auto-event path as Save), then start the other side.
            let previousIDs = Set(model.timeline.map(\.id))
            let finishedSide = timer.side?.uppercased() ?? upper
            model.foldActiveNursingSide(timer)
            isBusy = true
            Task {
                model.nursingPreserveSession = true
                defer { model.nursingPreserveSession = false }
                await model.stopActiveTimer()
                await model.catchUp()
                model.captureNewNursingSegment(side: finishedSide, previousIDs: previousIDs)
                await model.startBreastTimer(side: upper)
                isBusy = false
            }
            return
        }
        isBusy = true
        Task {
            await model.startBreastTimer(side: upper)
            if let started = model.babyState?.activeTimer, started.isActive {
                model.ensureNursingSession(for: started)
            }
            isBusy = false
        }
    }

    private func saveBreast() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            // Persist the active side segment (prior side already persisted on switch).
            await model.stopActiveTimer()
            isBusy = false
            onSaved()
        }
    }

    private static func clockParts(_ interval: TimeInterval) -> (hours: Int, minutes: Int, seconds: Int) {
        let total = max(0, Int(interval))
        return (total / 3600, (total % 3600) / 60, total % 60)
    }
}
