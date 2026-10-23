import BenitoKit
import SwiftUI

struct ActiveTimerView: View {
    var model: AppModel
    var onDismissToHome: (() -> Void)? = nil
    /// Closes the timer screen without stopping the timer (toolbar Hide / swipe down).
    var onHide: () -> Void = {}

    @State private var demoStartedAt = Date().addingTimeInterval(-7 * 60 - 22)
    @State private var showAdjustStart = false
    @State private var showsNursingPanel = false

    private var timer: ActiveTimerSnapshot? {
        PrototypeGlanceBuilder.from(model: model, now: .now).activeTimer
            ?? demoTimerIfNeeded
    }

    /// When no live timer and we're in demo-ish empty state, show a calm preview clock.
    private var demoTimerIfNeeded: ActiveTimerSnapshot? {
        guard model.babyState?.activeTimer == nil, model.babyState == nil else { return nil }
        return ActiveTimerSnapshot(
            id: UUID(uuidString: "00000000-0000-4000-8000-0000000000DE")!,
            kind: "breast",
            side: "L",
            startedAt: demoStartedAt
        )
    }

    private var isDemoPreview: Bool {
        model.babyState?.activeTimer == nil && model.babyState == nil
    }

    var body: some View {
        Group {
            if showsNursingPanel || isRunningFeed {
                RunningFeedSheet(model: model, onHide: onHide, onSaved: finishFeed)
            } else {
                timerScreen
            }
        }
        .onAppear(perform: latchFeedMode)
        .onChange(of: model.babyState?.activeTimer?.id) { _, _ in latchFeedMode() }
    }

    /// Latched so the brief nil during an L↔R switch or Save does not swap the sheet
    /// back to the sleep-style screen mid-animation.
    private func latchFeedMode() {
        if isRunningFeed { showsNursingPanel = true }
    }

    /// Live (non-demo) breast timer: reuse the Feed sheet's Nursing panel.
    private var isRunningFeed: Bool {
        guard !isDemoPreview, let t = model.babyState?.activeTimer, t.isActive else { return false }
        return RunningTimerLabel.isNursing(kind: t.kind)
    }

    private func finishFeed() {
        if let onDismissToHome {
            onDismissToHome()
        } else {
            onHide()
        }
    }

    /// Sleep (and demo preview) timer screen.
    /// The action bar is a bottom safe-area inset (not the last VStack row) so Stop/Pause
    /// stay pinned and reachable when the card overflows a short window
    /// (iPhone Duo folded at the medium detent); the card still compresses into the space above it.
    private var timerScreen: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 24)

                VStack(spacing: 16) {
                    StatusChip(
                        text: isPaused ? "\(kindLabel) · Paused" : kindLabel,
                        accent: kindAccent,
                        inverted: !isPaused
                    )

                    // Digits only — avoid rebuilding `.benitoGlass()` on the parent card every second.
                    activeClock

                    if let timer {
                        StartTimeRow(date: displayedStart(for: timer), accent: kindAccent) {
                            showAdjustStart = true
                        }
                    }

                    if let side = timer?.side {
                        HStack(spacing: 10) {
                            sidePill("L", selected: side.uppercased() == "L")
                            sidePill("R", selected: side.uppercased() == "R")
                        }
                        .padding(.top, 4)
                    } else if let sharedTimerCaption {
                        Text(sharedTimerCaption)
                            .font(.subheadline)
                            .foregroundStyle(DesignTokens.textSecondary)
                    }

                    if isDemoPreview {
                        Text("Demo preview — start a timer from Log")
                            .font(.caption)
                            .foregroundStyle(DesignTokens.textTertiary)
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .padding(.horizontal, DesignTokens.gutter)
                .benitoGlass()
                .padding(.horizontal, DesignTokens.gutter)

                Spacer()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ThumbActionBar(actions: timerActions)
            }
            .background(DesignTokens.bgCanvas.ignoresSafeArea())
            .navigationTitle("Timer")
            .navigationBarTitleDisplayMode(.inline)
            .benitoNavigationBarGlass()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onHide) {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(BenitoBorderlessButtonStyle())
                    .accessibilityLabel("Dismiss timer, keep it running")
                }
            }
            .onAppear {
                if let timer = model.babyState?.activeTimer, timer.isActive {
                    model.ensureNursingSession(for: timer)
                }
            }
            .sheet(isPresented: $showAdjustStart) {
                if let timer {
                    let breast = !isDemoPreview && RunningTimerLabel.isNursing(kind: timer.kind)
                    StartTimeEditorSheet(
                        accent: kindAccent,
                        initial: breast ? (model.nursingLive?.sessionStart ?? timer.startedAt) : timer.startedAt,
                        range: breast ? model.nursingStartBounds() : model.timerStartBounds(for: timer.timer),
                        showsSideScope: breast,
                        isPresented: $showAdjustStart
                    ) { newStart, scope in
                        if isDemoPreview {
                            demoStartedAt = newStart
                            return nil
                        }
                        let ok = await model.adjustRunningActivityStart(
                            to: newStart,
                            nursingScope: breast ? scope : nil
                        )
                        return ok ? nil : model.status
                    }
                }
            }
        }
    }

    /// Pause-excluded snapshot for VoiceOver / non-ticking chrome.
    private var elapsed: TimeInterval {
        timer?.elapsed(at: .now) ?? 0
    }

    @ViewBuilder
    private var activeClock: some View {
        if isPaused || timer == nil {
            clockText(elapsed)
        } else if let timer {
            TimelineView(.periodic(from: timer.startedAt, by: 1)) { context in
                clockText(timer.elapsed(at: context.date))
            }
        }
    }

    private func clockText(_ elapsed: TimeInterval) -> some View {
        Text(PrototypeFormatters.timerClock(elapsed))
            .font(.system(size: 72, weight: .bold, design: .rounded))
            .foregroundStyle(isPaused ? DesignTokens.textSecondary : DesignTokens.textPrimary)
            .opacity(isPaused ? 0.6 : 1)
            .monospacedDigit()
            .minimumScaleFactor(0.5)
            .lineLimit(1)
    }

    private var isPaused: Bool {
        timer?.isPaused == true
    }

    /// "Shared sleep timer" / "Shared walk timer" / "Shared crying timer"; nil for nursing (shows side pills instead).
    private var sharedTimerCaption: String? {
        if RunningTimerLabel.isSleep(kind: timer?.kind) { return "Shared sleep timer" }
        if let activity = ActivityKind(timerKind: timer?.kind) { return "Shared \(activity.noun) timer" }
        return nil
    }

    private var kindLabel: String {
        RunningTimerLabel.title(kind: timer?.kind, side: timer?.side)
    }

    private var kindAccent: Color {
        RunningTimerLabel.accent(kind: timer?.kind)
    }

    private var timerActions: [ThumbAction] {
        var actions: [ThumbAction] = []
        if !isDemoPreview, timer != nil {
            let paused = isPaused
            actions.append(
                ThumbAction(
                    title: paused ? "Resume" : "Pause",
                    systemImage: paused ? "play.fill" : "pause.fill",
                    runningEmphasis: true,
                    accent: paused ? DesignTokens.feed : DesignTokens.active,
                    glassEffectID: BenitoGlass.ThumbEffectID.pause
                ) {
                    Task {
                        if paused {
                            await model.resumeActiveTimer()
                        } else {
                            await model.pauseActiveTimer()
                        }
                    }
                }
            )
        }
        actions.append(
            ThumbAction(
                title: isDemoPreview ? "Close preview" : "Stop",
                systemImage: "stop.fill",
                accent: DesignTokens.fault,
                glassEffectID: BenitoGlass.ThumbEffectID.stop
            ) {
                Task {
                    if !isDemoPreview {
                        await model.stopActiveTimer()
                    }
                    onDismissToHome?()
                }
            }
        )
        return actions
    }

    private func sidePill(_ label: String, selected: Bool) -> some View {
        Text(label)
            .font(.headline.weight(.bold))
            .foregroundStyle(selected ? DesignTokens.onAccent : DesignTokens.textSecondary)
            .frame(width: 64, height: 44)
            .benitoSelectableCapsule(selected: selected, solid: DesignTokens.feed)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DesignTokens.textSecondary.opacity(selected ? 0 : 0.25), lineWidth: 1)
            )
    }

    private func displayedStart(for timer: ActiveTimerSnapshot) -> Date {
        if !isDemoPreview, RunningTimerLabel.isNursing(kind: timer.kind),
           let session = model.nursingLive?.sessionStart {
            return session
        }
        return timer.startedAt
    }
}

/// Label left, underlined value right (`Today, 9:25 PM`). Not on the 1Hz tick.
struct StartTimeRow: View {
    var date: Date
    var accent: Color
    var action: () -> Void

    var body: some View {
        let label = PrototypeFormatters.startTimeLabel(date)
        return Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Start Time")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                Spacer(minLength: 8)
                Text(label)
                    .font(.body.weight(.semibold))
                    .underline()
                    .monospacedDigit()
                    .foregroundStyle(accent)
                    .multilineTextAlignment(.trailing)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
        .accessibilityLabel("Start time, \(label)")
        .accessibilityHint("Opens the start time editor")
    }
}

/// Bottom sheet: date/time wheel, optional nursing side scope, Cancel / Save.
struct StartTimeEditorSheet: View {
    var accent: Color
    var initial: Date
    var range: ClosedRange<Date>
    var showsSideScope: Bool
    @Binding var isPresented: Bool
    var onSave: (Date, NursingSideScope) async -> String?

    @State private var draft: Date
    @State private var scope: NursingSideScope = .both
    @State private var isSaving = false
    @State private var errorText: String?

    init(
        accent: Color,
        initial: Date,
        range: ClosedRange<Date>,
        showsSideScope: Bool,
        isPresented: Binding<Bool>,
        onSave: @escaping (Date, NursingSideScope) async -> String?
    ) {
        self.accent = accent
        self.initial = initial
        self.range = range
        self.showsSideScope = showsSideScope
        self._isPresented = isPresented
        self.onSave = onSave
        let clamped = min(range.upperBound, max(range.lowerBound, initial))
        self._draft = State(initialValue: clamped)
    }

    private var hasChange: Bool { abs(draft.timeIntervalSince(initial)) >= 1 }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                DatePicker(
                    "Start time",
                    selection: $draft,
                    in: range,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .frame(minHeight: 180)
                .tint(accent)
                .accessibilityLabel("Start time")
                .onChange(of: draft) { _, _ in errorText = nil }

                if showsSideScope {
                    sideScopePicker
                }

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.fault)
                        .accessibilityLabel("Error: \(errorText)")
                }

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    sheetCapsule("Cancel", filled: false, enabled: !isSaving) {
                        isPresented = false
                    }
                    sheetCapsule("Save", filled: true, enabled: hasChange && !isSaving) {
                        save()
                    }
                }
            }
            .padding(DesignTokens.gutter)
            .background(DesignTokens.bgCanvas.ignoresSafeArea())
            .navigationTitle("Start time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(BenitoBorderlessButtonStyle())
                    .accessibilityLabel("Dismiss")
                    .disabled(isSaving)
                }
            }
            .benitoNavigationBarGlass()
        }
        .benitoSheetDetents()
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(isSaving)
    }

    private var sideScopePicker: some View {
        CapsuleSegmentBar(
            options: Array(NursingSideScope.allCases),
            selection: scope,
            title: { $0.title },
            accent: accent,
            accessibilityLabel: "Change duration for which side?"
        )
        { scope = $0 }
    }

    private func sheetCapsule(_ title: String, filled: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
                .foregroundStyle(filled ? (enabled ? DesignTokens.onAccent : DesignTokens.textTertiary) : DesignTokens.textPrimary)
                .background(
                    filled ? (enabled ? accent : DesignTokens.bgCardElevated) : DesignTokens.bgCardElevated,
                    in: Capsule(style: .continuous)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(DesignTokens.textSecondary.opacity(filled ? 0 : 0.28), lineWidth: 1)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(title)
    }

    private func save() {
        guard hasChange, !isSaving else { return }
        isSaving = true
        errorText = nil
        let picked = min(range.upperBound, max(range.lowerBound, draft))
        Task {
            let error = await onSave(picked, scope)
            isSaving = false
            if let error, !error.isEmpty {
                errorText = error
            } else {
                isPresented = false
            }
        }
    }
}

private extension NursingSideScope {
    var title: String {
        switch self {
        case .left: return "Left"
        case .both: return "Both"
        case .right: return "Right"
        }
    }
}


#Preview {
    ActiveTimerView(model: AppModel(serverURLString: BenitoServerPresets.loopback))
}
