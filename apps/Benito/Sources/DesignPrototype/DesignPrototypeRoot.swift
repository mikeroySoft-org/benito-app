import SwiftUI

/// Tab shell matching OpenBBQ Cook HUD information architecture.
struct DesignPrototypeRoot: View {
    @Binding var serverURLString: String
    var model: AppModel

    @State private var selectedTab = 0
    @State private var showActiveTimer = false
    /// Log tab spring sheets own their own 1 Hz clocks — hide the floating bar while they are open.
    @State private var suppressFloatingTimerChrome = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                HomeGlanceView(
                    model: model,
                    onOpenTimer: { presentActiveTimer() },
                    // TabView keeps inactive tabs alive — only mount the 1 Hz bar on the visible tab.
                    showRunningTimerChrome: !showActiveTimer && selectedTab == 0
                )
                // Home owns the stacked timer + activity dock via safeAreaInset.
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

                LogActionsView(
                    model: model,
                    onShowActiveTimer: { presentActiveTimer() },
                    suppressFloatingTimerChrome: $suppressFloatingTimerChrome
                )
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    floatingRunningTimerDock(visible: selectedTab == 1 && !suppressFloatingTimerChrome)
                }
                .tabItem { Label("Log", systemImage: "plus.circle.fill") }
                .tag(1)

                TimelinePrototypeView(model: model, isSelected: selectedTab == 2)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        floatingRunningTimerDock(visible: selectedTab == 2 && !suppressFloatingTimerChrome)
                    }
                    .tabItem { Label("Timeline", systemImage: "list.bullet") }
                    .tag(2)

                SettingsPrototypeView(serverURLString: $serverURLString, model: model)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        floatingRunningTimerDock(visible: selectedTab == 3 && !suppressFloatingTimerChrome)
                    }
                    .tabItem { Label("Account", systemImage: "person.crop.circle") }
                    .tag(3)
            }
            .tint(DesignTokens.feed)
            .benitoTabBarGlass()
            // Running Sleep / Feed timer — same system sheet as Feed / Diaper / Sleep
            // (slide up from the bottom, medium/large detents, drag indicator, swipe to dismiss).
            .sheet(isPresented: $showActiveTimer) {
                ActiveTimerView(
                    model: model,
                    onDismissToHome: {
                        dismissActiveTimer()
                        selectedTab = 0
                    },
                    onHide: { dismissActiveTimer() }
                )
                .benitoSheetDetents()
                .presentationDragIndicator(.visible)
            }
            .onChange(of: model.babyState?.activeTimer?.id) { _, newID in
                // Partner (or another device) stopped the timer while the screen was open.
                // Skip the brief nil while switching nursing sides (stop L → start R).
                if newID == nil, showActiveTimer, !model.nursingPreserveSession {
                    dismissActiveTimer()
                }
            }
            .onChange(of: selectedTab) { _, tab in
                if tab != 1 { suppressFloatingTimerChrome = false }
            }
            .onAppear {
                if BenitoHomeSheetRequest.peek() != nil {
                    selectedTab = 0
                }
                applyScreenshotLaunchOverrides()
            }
            .onReceive(NotificationCenter.default.publisher(for: .benitoPendingHomeSheet)) { _ in
                selectedTab = 0
            }

        }
    }

    /// Active (running or paused) timer, unless the spring timer panel is already showing it.
    private var hiddenRunningTimer: ActiveTimerSnapshot? {
        guard !showActiveTimer, let timer = model.babyState?.activeTimer, timer.isActive else { return nil }
        return ActiveTimerSnapshot(timer)
    }

    /// OpenBBQ floating-dock spacing above the system tab bar (non-Home tabs).
    /// `visible` must be the currently selected tab so inactive TabView children don't keep
    /// extra `TimelineView` schedules (and glass chrome) alive.
    @ViewBuilder
    private func floatingRunningTimerDock(visible: Bool) -> some View {
        if visible, let timer = hiddenRunningTimer {
            RunningTimerBar(
                timer: timer,
                onOpen: { presentActiveTimer() },
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
            .readableContentWidth()
            .padding(.bottom, 8)
        }
    }

    private func presentActiveTimer() {
        setActiveTimerPresented(true)
    }

    private func dismissActiveTimer() {
        setActiveTimerPresented(false)
    }

    private func setActiveTimerPresented(_ show: Bool) {
        if reduceMotion {
            showActiveTimer = show
        } else {
            withAnimation(BenitoGlass.sheetPresentationAnimation) {
                showActiveTimer = show
            }
        }
    }

    /// `SIMCTL_CHILD_BENITO_PROTOTYPE_TAB` = 0..3 or `timer`.
    /// Sheets: pair with `SIMCTL_CHILD_BENITO_PROTOTYPE_SHEET` = feed|diaper|sleep (Home).
    private func applyScreenshotLaunchOverrides() {
        let env = ProcessInfo.processInfo.environment["BENITO_PROTOTYPE_TAB"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let env, !env.isEmpty else { return }
        if env == "timer" {
            selectedTab = 0
            presentActiveTimer()
            return
        }
        if let idx = Int(env), (0...3).contains(idx) {
            selectedTab = idx
        }
    }
}

#Preview {
    DesignPrototypeRoot(
        serverURLString: .constant(BenitoServerPresets.loopback),
        model: AppModel(serverURLString: BenitoServerPresets.loopback)
    )
}
