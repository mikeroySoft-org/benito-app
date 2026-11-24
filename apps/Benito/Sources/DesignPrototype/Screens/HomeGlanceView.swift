import BenitoKit
import SwiftUI
import TipKit

struct HomeGlanceView: View {
    var model: AppModel
    /// Opens the active timer spring panel (parent owns presentation).
    var onOpenTimer: () -> Void
    /// When false, hide the compact running-timer chrome (full timer panel is up).
    var showRunningTimerChrome: Bool = true

    @State private var showFeedSheet = false
    @State private var showDiaperSheet = false
    @State private var showSleepSheet = false
    @State private var showPastSleepSheet = false
    /// Sleep → past nap can't present a second sheet in the same turn.
    @State private var queuePastNap = false
    @Namespace private var sheetZoomNamespace
    /// First-run hints, one at a time: feed, then diaper, then Siri.
    @State private var homeTips = TipGroup(.ordered) {
        LogFeedTip()
        LogDiaperTip()
        SiriLoggingTip()
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private func glance(at now: Date) -> PrototypeGlance {
        PrototypeGlanceBuilder.from(model: model, now: now)
    }

    private func breastTimerRunning(_ glance: PrototypeGlance) -> Bool {
        guard let t = glance.activeTimer else { return false }
        return RunningTimerLabel.isNursing(kind: t.kind)
    }

    private func sleepTimerRunning(_ glance: PrototypeGlance) -> Bool {
        guard let t = glance.activeTimer else { return false }
        return t.kind.lowercased().contains("sleep")
    }

    /// Active timer for the floating chrome.
    /// Hidden while the full timer panel is open **or** while Feed/Sleep/Diaper sheets
    /// are up — those sheets own their own 1 Hz `TimelineView` clocks, and stacking
    /// another schedule under Liquid Glass was a jetsam suspect during long feeds.
    private var dockTimer: ActiveTimerSnapshot? {
        guard showRunningTimerChrome,
              !showFeedSheet,
              !showSleepSheet,
              !showDiaperSheet,
              !showPastSleepSheet,
              let timer = model.babyState?.activeTimer,
              timer.isActive else { return nil }
        return ActiveTimerSnapshot(timer)
    }

    var body: some View {
        // Glance duration digits tick inside each card (not around glass).
        // Sheets are system presentations (same slide-up as Log's Pump / Medicine),
        // so an open Feed/Diaper/Sleep sheet is not a sibling rebuilt with the glance.
        homeChrome()
            .sheet(isPresented: $showFeedSheet) {
                FeedLogSheet(model: model, isPresented: $showFeedSheet)
                    .benitoSheetDetents()
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showDiaperSheet) {
                DiaperLogSheet(model: model, isPresented: $showDiaperSheet)
                    .benitoSheetDetents()
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSleepSheet, onDismiss: presentQueuedAfterSleepDismiss) {
                SleepLogSheet(
                    model: model,
                    isPresented: $showSleepSheet,
                    onLogPastNap: queuePastNapAfterSleepDismiss
                )
                .benitoSheetDetents()
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showPastSleepSheet) {
                PastSleepLogSheet(model: model, isPresented: $showPastSleepSheet)
                    .benitoSheetDetents()
                    .presentationDragIndicator(.visible)
            }
    }

    private func homeChrome() -> some View {
        // Child name / sync chips come from model; duration digits tick inside each card
        // so Liquid Glass on Hero / mini cards is not rebuilt every minute.
        let titleGlance = glance(at: .now)
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.gutter) {
                    headerChips(titleGlance)
                    feedHero(titleGlance)
                    secondaryGrid(titleGlance)
                    todaySummary(titleGlance)
                    if model.hasFamily, let siri = homeTips.currentTip as? SiriLoggingTip {
                        TipView(siri)
                            .tipBackground(DesignTokens.bgCard)
                    }
                }
                .padding(.horizontal, DesignTokens.gutter)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .readableContentWidth()
            }
            .background(DesignTokens.bgCanvas.ignoresSafeArea())
            .navigationTitle(titleGlance.childName)
            .navigationBarTitleDisplayMode(.inline)
            .benitoNavigationBarGlass()
            .onAppear {
                applyScreenshotSheetOverrides()
                applyPendingHomeSheetRequest()
            }
            .onReceive(NotificationCenter.default.publisher(for: .benitoPendingHomeSheet)) { _ in
                applyPendingHomeSheetRequest()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { applyPendingHomeSheetRequest() }
            }
            // OpenBBQ-style floating dock: timer chrome stacked above activity thumbs,
            // then a little air above the system tab bar.
            // Dock stays outside any TimelineView + ignores ambient sheet springs so
            // raise/lower / expand taps do not re-animate GlassEffectContainer.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomDock(titleGlance)
                    .popoverTip(model.hasFamily ? homeTips.currentTip as? LogDiaperTip : nil, arrowEdge: .bottom)
                    .readableContentWidth()
                    .padding(.bottom, 8)
                    .transaction { $0.animation = nil }
            }
            // Keep off the minute-tick path so a TimelineView identity churn cannot
            // cancel/restart the daily summary fetch.
            .task(id: model.childId) {
                await model.refreshDailySummary()
            }
        }
    }

    /// Timer bar (when running) stacked cleanly above Feed/Diaper/Sleep thumbs.
    private func bottomDock(_ glance: PrototypeGlance) -> some View {
        VStack(spacing: 0) {
            if let timer = dockTimer {
                RunningTimerBar(
                    timer: timer,
                    onOpen: onOpenTimer,
                    onPause: {
                        Task { await model.pauseActiveTimer() }
                    },
                    onResume: {
                        Task { await model.resumeActiveTimer() }
                    },
                    onStop: {
                        Task { await model.stopActiveTimer() }
                    }
                )
            }

            ThumbActionBar(
                actions: [
                    ThumbAction(
                        title: "Feed",
                        systemImage: "drop.fill",
                        detail: feedThumbDetail(glance),
                        runningEmphasis: breastTimerRunning(glance),
                        accent: DesignTokens.feed,
                        transitionID: BenitoGlass.SheetTransitionID.feed,
                        glassEffectID: BenitoGlass.ThumbEffectID.feed
                    ) { presentFeed() },
                    ThumbAction(
                        title: "Diaper",
                        systemImage: "circle.grid.cross.fill",
                        runningEmphasis: false,
                        accent: DesignTokens.diaper,
                        transitionID: BenitoGlass.SheetTransitionID.diaper,
                        glassEffectID: BenitoGlass.ThumbEffectID.diaper
                    ) { presentDiaper() },
                    ThumbAction(
                        title: "Sleep",
                        systemImage: "moon.fill",
                        runningEmphasis: sleepTimerRunning(glance),
                        accent: DesignTokens.sleep,
                        transitionID: BenitoGlass.SheetTransitionID.sleep,
                        glassEffectID: BenitoGlass.ThumbEffectID.sleep
                    ) { presentSleep() },
                ],
                sheetTransitionNamespace: sheetZoomNamespace
            )
        }
    }

    private func headerChips(_ glance: PrototypeGlance) -> some View {
        HStack(spacing: 8) {
            if glance.isDemo {
                StatusChip(text: "Demo", accent: DesignTokens.textSecondary, inverted: false)
            }
            if glance.isOnDevice {
                StatusChip(text: String(localized: "This \(BenitoDevice.name)"), accent: DesignTokens.textSecondary, inverted: false)
            } else {
                StatusChip(
                    text: glance.syncConnected ? "Sync" : "Offline",
                    accent: glance.syncConnected ? DesignTokens.active : DesignTokens.fault,
                    inverted: glance.syncConnected
                )
            }
            Spacer()
            Text(glance.isAsleep ? "ASLEEP" : "AWAKE")
                .font(.caption.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(glance.isAsleep ? DesignTokens.sleep : DesignTokens.active)
        }
    }

    private func feedHero(_ glance: PrototypeGlance) -> some View {
        let chipAccent: Color = {
            switch glance.feedSideLabel {
            case "Bottle": return DesignTokens.bottle
            case "R": return DesignTokens.feed.opacity(0.85)
            default: return DesignTokens.feed
            }
        }()

        return Button { presentFeed() } label: {
            HeroCard(
                eyebrow: "Since last feed",
                tickingValue: { date in
                    PrototypeFormatters.compactDuration(self.glance(at: date).sinceLastFeed)
                },
                chip: glance.feedSideLabel,
                chipAccent: chipAccent,
                subtitle: glance.feedDetail
            )
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
        .accessibilityLabel(feedHeroAccessibility(glance))
        .popoverTip(model.hasFamily ? homeTips.currentTip as? LogFeedTip : nil, arrowEdge: .top)
    }

    private func feedThumbDetail(_ glance: PrototypeGlance) -> String? {
        // Keep to side · ago so the taller thumb still reads at a glance.
        var parts: [String] = []
        if let side = glance.feedSideLabel { parts.append(side) }
        let ago = PrototypeFormatters.compactDuration(glance.sinceLastFeed)
        if ago != "—" { parts.append("\(ago) ago") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func presentFeed() {
        LogFeedTip().invalidate(reason: .actionPerformed)
        animateActivity { showFeedSheet = true }
    }

    private func presentDiaper() {
        LogDiaperTip().invalidate(reason: .actionPerformed)
        animateActivity { showDiaperSheet = true }
    }

    private func presentSleep() {
        // Running sleep always uses the shared ActiveTimerView (same as RunningTimerBar expand).
        if sleepTimerRunning(glance(at: .now)) {
            onOpenTimer()
            return
        }
        animateActivity { showSleepSheet = true }
    }

    /// Dismiss Sleep first, then present past nap / ActiveTimerView from `onDismiss`
    /// (system sheets drop a second present issued while the first is still up).
    private func queuePastNapAfterSleepDismiss() {
        queuePastNap = true
        animateActivity { showSleepSheet = false }
    }

    private func presentQueuedAfterSleepDismiss() {
        if queuePastNap {
            queuePastNap = false
            animateActivity { showPastSleepSheet = true }
            return
        }
        // Start sleep dismisses this sheet once the timer is running.
        if sleepTimerRunning(glance(at: .now)) {
            onOpenTimer()
        }
    }

    private func animateActivity(_ updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(BenitoGlass.sheetPresentationAnimation, updates)
        }
    }

    private func feedHeroAccessibility(_ glance: PrototypeGlance) -> String {
        let ago = PrototypeFormatters.compactDuration(glance.sinceLastFeed)
        var label = "Since last feed, \(ago)"
        if let side = glance.feedSideLabel { label += ", \(side)" }
        if let detail = glance.feedDetail { label += ", \(detail)" }
        return label + ". Opens feeding"
    }

    private func secondaryGrid(_ glance: PrototypeGlance) -> some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                GlanceMiniCard(
                    title: "Diaper",
                    tickingValue: { date in
                        PrototypeFormatters.compactDuration(self.glance(at: date).sinceLastDiaper)
                    },
                    detail: glance.diaperSubtype.map { $0.capitalized } ?? "No log yet",
                    accent: DesignTokens.diaper
                )
                GlanceMiniCard(
                    title: glance.isAsleep ? "Asleep" : "Awake",
                    tickingValue: { date in
                        let g = self.glance(at: date)
                        return g.sleepDuration > 0
                            ? PrototypeFormatters.compactDuration(g.sleepDuration)
                            : "—"
                    },
                    detail: glance.isAsleep
                        ? (sleepTimerRunning(glance) && glance.activeTimer?.isPaused == true ? "Sleep timer paused" : "Sleeping now")
                        : "Since last wake",
                    accent: DesignTokens.sleep
                )
            }
            // Only show Medicine after at least one dose has been logged.
            if glance.sinceLastMedicine != nil {
                GlanceMiniCard(
                    title: "Medicine",
                    tickingValue: { date in
                        PrototypeFormatters.compactDuration(self.glance(at: date).sinceLastMedicine)
                    },
                    detail: medicineGlanceDetail(glance),
                    accent: DesignTokens.medicine
                )
            }
        }
    }

    private func medicineGlanceDetail(_ glance: PrototypeGlance) -> String {
        if let label = glance.medicineLabel, let detail = glance.medicineDetail {
            return "\(label) · \(detail)"
        }
        return glance.medicineLabel ?? glance.medicineDetail ?? "No log yet"
    }

    /// Compact today strip — prefers server `DailySummaryDTO` (local-day from/to); falls back to timeline counts.
    private func todaySummary(_ glance: PrototypeGlance) -> some View {
        VStack(spacing: 10) {
            DayWindowCaption(window: glance.todayWindow, now: .now)
                .padding(.horizontal, 16)

            HStack(spacing: 0) {
                todayStat(label: "Feeds", value: todayFeedLabel(glance), accent: DesignTokens.feed)
                divider
                todayStat(label: "Diapers", value: todayDiaperLabel(glance), accent: DesignTokens.diaper)
                divider
                todayStat(label: "Sleep", value: todaySleepLabel(glance), accent: DesignTokens.sleep)
            }

            Rectangle()
                .fill(DesignTokens.textSecondary.opacity(0.15))
                .frame(height: 1)
                .padding(.horizontal, 16)
                .accessibilityHidden(true)

            FedTotalsLine(totals: todayFedTotals(glance))
                .padding(.horizontal, 16)

            let crying = todayCryingSeconds(glance)
            if CryingTotalLine.isVisible(seconds: crying) {
                CryingTotalLine(seconds: crying)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 14)
        .benitoGlass()
    }

    /// Nursing minutes + bottle volume today: server summary when loaded, else the local timeline.
    private func todayFedTotals(_ glance: PrototypeGlance) -> DailyFedTotals {
        guard let s = model.dailySummary else { return glance.todayFed }
        return DailyFedTotals(summary: s, fallbackNursingSeconds: glance.todayFed.nursingSeconds)
    }

    /// Crying minutes today: server summary when it has the field, else the local timeline.
    private func todayCryingSeconds(_ glance: PrototypeGlance) -> TimeInterval {
        model.dailySummary?.cryingSeconds ?? glance.todayCryingSeconds
    }

    private func todayFeedLabel(_ glance: PrototypeGlance) -> String {
        if let s = model.dailySummary {
            return "\(s.feedBreastCount + s.feedBottleCount + s.feedSolidCount)"
        }
        return "\(glance.todayFeedCount)"
    }

    private func todayDiaperLabel(_ glance: PrototypeGlance) -> String {
        if let s = model.dailySummary {
            return "\(s.diaperWet + s.diaperDirty + s.diaperBoth + s.diaperOther)"
        }
        return "\(glance.todayDiaperCount)"
    }

    private func todaySleepLabel(_ glance: PrototypeGlance) -> String {
        if let s = model.dailySummary {
            guard s.sleepHours > 0 else { return "—" }
            return PrototypeFormatters.compactDuration(s.sleepHours * 3600)
        }
        return glance.todaySleepMinutes > 0
            ? PrototypeFormatters.compactDuration(TimeInterval(glance.todaySleepMinutes * 60))
            : "—"
    }

    private var divider: some View {
        Rectangle()
            .fill(DesignTokens.textSecondary.opacity(0.2))
            .frame(width: 1, height: 28)
    }

    private func todayStat(label: String, value: String, accent: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(DesignTokens.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity)
    }

    /// `SIMCTL_CHILD_BENITO_PROTOTYPE_SHEET` = feed | diaper | sleep (home stays selected).
    private func applyScreenshotSheetOverrides() {
        let sheet = ProcessInfo.processInfo.environment["BENITO_PROTOTYPE_SHEET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let sheet, !sheet.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            presentHomeSheet(sheet)
        }
    }

    /// Live Activity Feed / Diaper buttons enqueue a sheet via `BenitoHomeSheetRequest`.
    private func applyPendingHomeSheetRequest() {
        guard let sheet = BenitoHomeSheetRequest.take() else { return }
        // Slight delay so the tab switch to Home (if needed) lands first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            presentHomeSheet(sheet)
        }
    }

    private func presentHomeSheet(_ sheet: String) {
        switch sheet {
        case "feed": presentFeed()
        case "diaper": presentDiaper()
        case "sleep": presentSleep()
        default: break
        }
    }
}

#Preview {
    HomeGlanceView(
        model: AppModel(serverURLString: BenitoServerPresets.loopback),
        onOpenTimer: {}
    )
}


/// Applies `navigationTransition(.zoom)` when the sheet opens from a thumb (iOS 18+).
struct BenitoSheetZoomDestinationModifier: ViewModifier {
    let namespace: Namespace.ID
    let sourceID: String

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
    }
}
