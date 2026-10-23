import BenitoKit
import SwiftUI

struct LogActionsView: View {
    var model: AppModel
    var onShowActiveTimer: () -> Void
    /// When true, parent hides the floating RunningTimerBar so Feed/Sleep sheets
    /// are not stacked with a second 1 Hz `TimelineView`.
    @Binding var suppressFloatingTimerChrome: Bool

    @State private var showDiaperSheet = false
    @State private var showFeedSheet = false
    @State private var showSleepSheet = false
    @State private var showPumpSheet = false
    @State private var showPastSleepSheet = false
    @State private var showMedicineSheet = false
    @State private var showOutingSheet = false
    @State private var showCryingSheet = false
    /// Sleep → past nap can't present a second sheet in the same turn.
    @State private var queuePastNap = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
                ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Log")
                        .font(.caption.weight(.semibold))
                        .tracking(1.5)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .padding(.top, 4)

                    BigActionCard(
                        title: "Feed",
                        subtitle: "Nursing · Bottle",
                        systemImage: "drop.fill",
                        accent: DesignTokens.feed
                    ) { present { showFeedSheet = true } }

                    BigActionCard(
                        title: "Diaper",
                        subtitle: "Wet · dirty · both",
                        systemImage: "circle.grid.cross.fill",
                        accent: DesignTokens.diaper
                    ) { present { showDiaperSheet = true } }

                    BigActionCard(
                        title: "Sleep",
                        subtitle: sleepCardSubtitle,
                        systemImage: "moon.fill",
                        accent: DesignTokens.sleep
                    ) { presentSleep() }

                    BigActionCard(
                        title: "Log a past nap",
                        subtitle: "Fell asleep · woke up",
                        systemImage: "clock.arrow.circlepath",
                        accent: DesignTokens.sleep
                    ) { present { showPastSleepSheet = true } }

                    BigActionCard(
                        title: "Walk or car ride",
                        subtitle: activityCardSubtitle(runningOuting),
                        systemImage: runningOuting?.systemImage ?? "figure.walk",
                        accent: DesignTokens.outing
                    ) { presentActivity(running: runningOuting) { showOutingSheet = true } }

                    BigActionCard(
                        title: "Crying",
                        subtitle: activityCardSubtitle(runningCrying),
                        systemImage: ActivityKind.crying.systemImage,
                        accent: DesignTokens.crying
                    ) { presentActivity(running: runningCrying) { showCryingSheet = true } }

                    BigActionCard(
                        title: "Pump",
                        subtitle: "Side · ounces · duration",
                        systemImage: "drop.halffull",
                        accent: DesignTokens.bottle
                    ) { present { showPumpSheet = true } }

                    BigActionCard(
                        title: "Medicine",
                        subtitle: "Name · dose · time",
                        systemImage: "pills.fill",
                        accent: DesignTokens.medicine
                    ) { present { showMedicineSheet = true } }

                    if model.babyState?.activeTimer != nil {
                        BigActionCard(
                            title: "Active timer",
                            subtitle: "Open running session",
                            systemImage: "timer",
                            accent: DesignTokens.active
                        ) { present { onShowActiveTimer() } }
                    }

                    if !model.status.isEmpty {
                        Text(model.status)
                            .font(.footnote)
                            .foregroundStyle(DesignTokens.textSecondary)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, DesignTokens.gutter)
                .padding(.bottom, 24)
                .readableContentWidth()
            }
            .background(DesignTokens.bgCanvas.ignoresSafeArea())
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .benitoNavigationBarGlass()
            // Pump / Medicine stay system sheets (taller forms).
            .sheet(isPresented: $showPumpSheet) {
                PumpLogSheet(model: model, isPresented: $showPumpSheet)
                    .benitoSheetDetents()
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showMedicineSheet) {
                MedicineLogSheet(model: model, isPresented: $showMedicineSheet)
                    .benitoSheetDetents()
                    .presentationDragIndicator(.visible)
            }
            // Feed / Diaper / Sleep / past nap — same system sheet as Pump / Medicine
            // (slide up from the bottom). Content, chevron dismiss, and timer-bar
            // suppression are unchanged.
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
            .sheet(isPresented: $showOutingSheet, onDismiss: presentRunningActivityAfterDismiss) {
                ActivityLogSheet.outing(model: model, isPresented: $showOutingSheet)
                    .benitoSheetDetents()
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showCryingSheet, onDismiss: presentRunningActivityAfterDismiss) {
                ActivityLogSheet.crying(model: model, isPresented: $showCryingSheet)
                    .benitoSheetDetents()
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showPastSleepSheet) {
                PastSleepLogSheet(model: model, isPresented: $showPastSleepSheet)
                    .benitoSheetDetents()
                    .presentationDragIndicator(.visible)
            }
        }
        .onChange(of: showFeedSheet) { _, _ in syncTimerChromeSuppression() }
        .onChange(of: showSleepSheet) { _, _ in syncTimerChromeSuppression() }
        .onChange(of: showDiaperSheet) { _, _ in syncTimerChromeSuppression() }
        .onChange(of: showPastSleepSheet) { _, _ in syncTimerChromeSuppression() }
        .onChange(of: showOutingSheet) { _, _ in syncTimerChromeSuppression() }
        .onChange(of: showCryingSheet) { _, _ in syncTimerChromeSuppression() }
        .task { await applyScreenshotSheetOverride() }
        .onDisappear { suppressFloatingTimerChrome = false }
    }

    private var sleepCardSubtitle: String {
        if let t = model.babyState?.activeTimer, t.isActive,
           RunningTimerLabel.isSleep(kind: t.kind) {
            return t.isPaused ? "Sleep timer paused" : "Open running sleep timer"
        }
        return "Start shared sleep timer"
    }

    /// `SIMCTL_CHILD_BENITO_PROTOTYPE_SHEET=outing|crying` with the Log tab selected (screenshots).
    private func applyScreenshotSheetOverride() async {
        let sheet = ProcessInfo.processInfo.environment["BENITO_PROTOTYPE_SHEET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard sheet == "outing" || sheet == "crying" else { return }
        try? await Task.sleep(for: .milliseconds(350))
        if sheet == "crying" {
            presentActivity(running: runningCrying) { showCryingSheet = true }
        } else {
            presentActivity(running: runningOuting) { showOutingSheet = true }
        }
    }

    /// The `activity` kind (walk / car ride / crying) whose shared timer is running or paused.
    private var runningActivity: ActivityKind? {
        guard let t = model.babyState?.activeTimer, t.isActive else { return nil }
        return ActivityKind(timerKind: t.kind)
    }

    private var runningOuting: ActivityKind? { runningActivity?.isOuting == true ? runningActivity : nil }
    private var runningCrying: ActivityKind? { runningActivity == .crying ? .crying : nil }

    private func activityCardSubtitle(_ running: ActivityKind?) -> String {
        if let running, let t = model.babyState?.activeTimer {
            return t.isPaused ? "\(running.title) timer paused" : "Open running \(running.noun) timer"
        }
        return "Start a timer · log a past one"
    }

    /// Opens the running timer when this card's kind is live, else its log sheet.
    private func presentActivity(running: ActivityKind?, showSheet: () -> Void) {
        if running != nil {
            present { onShowActiveTimer() }
            return
        }
        present(showSheet)
    }

    /// Starting a walk / car ride / crying timer dismisses its sheet once it runs; open it here.
    private func presentRunningActivityAfterDismiss() {
        if runningActivity != nil {
            present { onShowActiveTimer() }
        }
    }

    private func presentSleep() {
        if let t = model.babyState?.activeTimer, t.isActive,
           RunningTimerLabel.isSleep(kind: t.kind) {
            present { onShowActiveTimer() }
            return
        }
        present { showSleepSheet = true }
    }

    /// Dismiss Sleep first, then present past nap / ActiveTimerView from `onDismiss`
    /// (system sheets drop a second present issued while the first is still up).
    private func queuePastNapAfterSleepDismiss() {
        queuePastNap = true
        present { showSleepSheet = false }
    }

    private func presentQueuedAfterSleepDismiss() {
        if queuePastNap {
            queuePastNap = false
            present { showPastSleepSheet = true }
            return
        }
        // Start sleep dismisses this sheet once the timer is running.
        if let t = model.babyState?.activeTimer, t.isActive,
           RunningTimerLabel.isSleep(kind: t.kind) {
            present { onShowActiveTimer() }
        }
    }

    private func present(_ updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(BenitoGlass.sheetPresentationAnimation, updates)
        }
        // `present` wraps sheet open/close; refresh dock suppression after the state flip.
        DispatchQueue.main.async { syncTimerChromeSuppression() }
    }

    private func syncTimerChromeSuppression() {
        suppressFloatingTimerChrome =
            showFeedSheet || showSleepSheet || showDiaperSheet || showPastSleepSheet || showOutingSheet
            || showCryingSheet
    }
}

#Preview {
    LogActionsView(
        model: AppModel(serverURLString: BenitoServerPresets.loopback),
        onShowActiveTimer: {},
        suppressFloatingTimerChrome: .constant(false)
    )
}
