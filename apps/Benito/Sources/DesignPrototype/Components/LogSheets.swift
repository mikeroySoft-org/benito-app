import BenitoKit
import SwiftUI

/// Unified Feeding sheet — Nursing | Bottle segmented panel (Home thumbs + Log tab).
/// Nursing drives the server-authoritative breast timer (L/R start/pause/resume/stop).
/// Bottle reuses the amount / milk / backdate fields.
struct FeedLogSheet: View {
    var model: AppModel
    @Binding var isPresented: Bool

    enum Segment: String, CaseIterable, Identifiable {
        case nursing, bottle
        var id: String { rawValue }
        var title: String {
            switch self {
            case .nursing: return "Nursing"
            case .bottle: return "Bottle"
            }
        }
    }

    @State private var segment: Segment = .nursing
    @State private var ounces: Double = 3.0
    @State private var milk: BottleMilk = .formula
    @State private var bottleAt: Date?
    @State private var didPrefill = false
    @State private var isSaving = false

    private static let ounceRange: ClosedRange<Double> = 0.5...12
    private static let quickOunces: [Double] = [2, 3, 4, 5]

    /// Active breast timer only (sleep timers stay on the sleep surfaces).
    private var breastTimer: TimerDTO? {
        guard let t = model.babyState?.activeTimer, t.isActive else { return nil }
        guard RunningTimerLabel.isNursing(kind: t.kind) else { return nil }
        return t
    }

    var body: some View {
        LogSheetScaffold(title: "Feeding", isPresented: $isPresented) {
            feedSegmentPicker

            switch segment {
            case .nursing:
                NursingFeedPanel(model: model, onSaved: dismissAfterSave)
            case .bottle:
                bottlePanel
            }
        }
        .onAppear {
            prefill()
            if breastTimer != nil { segment = .nursing }
        }
        .onChange(of: model.babyState?.activeTimer?.id) { _, _ in
            if breastTimer != nil { segment = .nursing }
        }
    }

    // MARK: - Segment picker

    /// Capsule-in-capsule segmented control (OpenBBQ / Benito pill grammar).
    private var feedSegmentPicker: some View {
        CapsuleSegmentBar(
            options: Array(Segment.allCases),
            selection: segment,
            title: { $0.title },
            accent: DesignTokens.feed,
            accessibilityLabel: "Feeding type"
        ) { option in
            withAnimation(.easeInOut(duration: 0.18)) { segment = option }
        }
    }

    // MARK: - Bottle

    private var bottlePanel: some View {
        ContinuousCornerCard(padding: 16) {
            VStack(alignment: .leading, spacing: 18) {
                LogAmountStepper(
                    title: "Amount",
                    value: $ounces,
                    range: Self.ounceRange,
                    step: 0.5,
                    unit: "oz",
                    accent: DesignTokens.bottle
                )

                HStack(spacing: 8) {
                    ForEach(Self.quickOunces, id: \.self) { amount in
                        ChoicePill(
                            title: "\(LogAmountStepper.format(amount)) oz",
                            selected: ounces == amount,
                            accent: DesignTokens.bottle,
                            spokenLabel: "\(LogAmountStepper.format(amount)) ounces"
                        ) {
                            ounces = amount
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    LogFieldLabel(text: "Milk")
                    HStack(spacing: 8) {
                        ForEach(BottleMilk.allCases) { option in
                            ChoicePill(
                                title: option.label,
                                selected: milk == option,
                                accent: DesignTokens.bottle
                            ) {
                                milk = option
                            }
                        }
                    }
                }

                LogTimePicker(date: $bottleAt, accent: DesignTokens.bottle)

                PrimaryLogButton(
                    title: "Log bottle",
                    systemImage: "cup.and.saucer.fill",
                    accent: DesignTokens.bottle,
                    isBusy: isSaving
                ) {
                    submitBottle()
                }
            }
        }
    }

    // MARK: - Helpers

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        ounces = LogAmountStepper.snap(model.lastBottleOunces, step: 0.5, range: Self.ounceRange)
        milk = model.lastBottleMilk
    }

    private func submitBottle() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            await model.logBottle(ounces: ounces, milk: milk, at: bottleAt)
            isSaving = false
            isPresented = false
        }
    }

    private func dismissAfterSave() {
        isPresented = false
    }
}

/// Shared Diaper options sheet — used by Home thumbs and Log tab.
struct DiaperLogSheet: View {
    var model: AppModel
    @Binding var isPresented: Bool

    @State private var at: Date?
    @State private var isSaving = false

    var body: some View {
        LogSheetScaffold(title: "Diaper", isPresented: $isPresented) {
            ContinuousCornerCard(padding: 16) {
                LogTimePicker(date: $at, accent: DesignTokens.diaper)
            }
            diaperButton("Wet", subtype: "wet")
            diaperButton("Dirty", subtype: "dirty")
            diaperButton("Both", subtype: "both")
        }
    }

    private func diaperButton(_ title: String, subtype: String) -> some View {
        Button {
            guard !isSaving else { return }
            isSaving = true
            Task {
                await model.logDiaper(subtype: subtype, at: at)
                isSaving = false
                isPresented = false
            }
        } label: {
            Text(title)
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.thumbMin)
                .foregroundStyle(DesignTokens.textPrimary)
                .benitoGlassCapsule()
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(DesignTokens.diaper.opacity(0.35), lineWidth: 1)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
        .disabled(isSaving)
        .accessibilityLabel("Log \(title.lowercased()) diaper")
    }
}

/// Pumping session: side, optional amount, optional duration, finish time.
struct PumpLogSheet: View {
    var model: AppModel
    @Binding var isPresented: Bool

    @State private var side: PumpSide = .both
    @State private var recordAmount = true
    @State private var ounces: Double = 3.0
    @State private var recordDuration = true
    @State private var minutes: Double = 15
    /// When the session ended (nil = just now); the start is derived from the duration.
    @State private var finishedAt: Date?
    @State private var isSaving = false

    var body: some View {
        LogSheetScaffold(title: "Pump", isPresented: $isPresented) {
            ContinuousCornerCard(padding: 16) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        LogFieldLabel(text: "Side")
                        HStack(spacing: 8) {
                            ForEach(PumpSide.allCases) { option in
                                ChoicePill(
                                    title: option.label,
                                    selected: side == option,
                                    accent: DesignTokens.bottle
                                ) {
                                    side = option
                                }
                            }
                        }
                    }

                    Toggle("Record amount", isOn: $recordAmount.animation())
                        .font(.headline)
                        .foregroundStyle(DesignTokens.textPrimary)
                        .tint(DesignTokens.bottle)
                        .frame(minHeight: 44)
                    if recordAmount {
                        LogAmountStepper(
                            title: "Amount",
                            value: $ounces,
                            range: 0.5...16,
                            step: 0.5,
                            unit: "oz",
                            accent: DesignTokens.bottle
                        )
                    }

                    Toggle("Record duration", isOn: $recordDuration.animation())
                        .font(.headline)
                        .foregroundStyle(DesignTokens.textPrimary)
                        .tint(DesignTokens.bottle)
                        .frame(minHeight: 44)
                    if recordDuration {
                        LogAmountStepper(
                            title: "Duration",
                            value: $minutes,
                            range: 1...120,
                            step: 1,
                            unit: "min",
                            accent: DesignTokens.bottle
                        )
                    }

                    LogTimePicker(date: $finishedAt, title: "Finished", accent: DesignTokens.bottle)

                    PrimaryLogButton(
                        title: "Log pump",
                        systemImage: "drop.halffull",
                        accent: DesignTokens.bottle,
                        isBusy: isSaving
                    ) {
                        submitPump()
                    }
                }
            }
        }
    }

    private func submitPump() {
        guard !isSaving else { return }
        isSaving = true
        let duration = recordDuration ? Int(minutes) : nil
        // Sessions are logged after they finish: start = finish − duration.
        let start: Date?
        if let duration {
            start = (finishedAt ?? Date()).addingTimeInterval(-TimeInterval(duration * 60))
        } else {
            start = finishedAt
        }
        let amount = recordAmount ? ounces : nil
        Task {
            await model.logPump(side: side, ounces: amount, durationMinutes: duration, at: start)
            isSaving = false
            isPresented = false
        }
    }
}


/// Medicine dose — name (preset or custom) + optional amount/unit + backdate.
struct MedicineLogSheet: View {
    var model: AppModel
    @Binding var isPresented: Bool

    @State private var preset: MedicinePreset = .vitaminD
    @State private var customName = ""
    @State private var recordDose = true
    @State private var dose: Double = 1.0
    @State private var unit: MedicineDoseUnit = .ml
    @State private var givenAt: Date?
    @State private var didPrefill = false
    @State private var isSaving = false

    private static let doseRange: ClosedRange<Double> = 0.25...40
    private static let quickDoses: [Double] = [0.5, 1, 2, 5]

    private var resolvedName: String {
        if preset == .other {
            return customName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return preset.label
    }

    private var canSave: Bool { !resolvedName.isEmpty && !isSaving }

    var body: some View {
        LogSheetScaffold(title: "Medicine", isPresented: $isPresented) {
            ContinuousCornerCard(padding: 16) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        LogFieldLabel(text: "Medicine")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(MedicinePreset.allCases) { option in
                                ChoicePill(
                                    title: option.label,
                                    selected: preset == option,
                                    accent: DesignTokens.medicine
                                ) {
                                    preset = option
                                }
                            }
                        }
                        if preset == .other {
                            TextField("Name", text: $customName)
                                .font(.headline)
                                .foregroundStyle(DesignTokens.textPrimary)
                                .padding(12)
                                .benitoGlass(tint: DesignTokens.bgCardElevated, cornerRadius: 10)
                                .textInputAutocapitalization(.words)
                                .accessibilityLabel("Medicine name")
                        }
                    }

                    Toggle("Record dose", isOn: $recordDose.animation())
                        .font(.headline)
                        .foregroundStyle(DesignTokens.textPrimary)
                        .tint(DesignTokens.medicine)
                        .frame(minHeight: 44)

                    if recordDose {
                        LogAmountStepper(
                            title: "Dose",
                            value: $dose,
                            range: Self.doseRange,
                            step: 0.25,
                            unit: unit.label,
                            accent: DesignTokens.medicine
                        )

                        HStack(spacing: 8) {
                            ForEach(Self.quickDoses, id: \.self) { amount in
                                ChoicePill(
                                    title: LogAmountStepper.format(amount),
                                    selected: dose == amount,
                                    accent: DesignTokens.medicine,
                                    spokenLabel: "\(LogAmountStepper.format(amount)) \(unit.label)"
                                ) {
                                    dose = amount
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            ForEach(MedicineDoseUnit.allCases) { option in
                                ChoicePill(
                                    title: option.label,
                                    selected: unit == option,
                                    accent: DesignTokens.medicine
                                ) {
                                    unit = option
                                }
                            }
                        }
                    }

                    LogTimePicker(date: $givenAt, title: "Given", accent: DesignTokens.medicine)

                    PrimaryLogButton(
                        title: "Log medicine",
                        systemImage: "pills.fill",
                        accent: DesignTokens.medicine,
                        isBusy: isSaving
                    ) {
                        submit()
                    }
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.45)
                }
            }
        }
        .onAppear(perform: prefill)
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        let lastName = model.lastMedicineName
        guard !lastName.isEmpty else { return }
        let matched = MedicinePreset.matching(lastName)
        preset = matched
        if matched == .other {
            customName = lastName
        }
        if let last = model.babyState?.lastMedicine, let value = last.amountValue, value > 0 {
            recordDose = true
            dose = LogAmountStepper.snap(value, step: 0.25, range: Self.doseRange)
            if let u = last.amountUnit,
               let known = MedicineDoseUnit.allCases.first(where: {
                   $0.rawValue.compare(u, options: .caseInsensitive) == .orderedSame
               }) {
                unit = known
            }
        }
    }

    private func submit() {
        guard canSave else { return }
        isSaving = true
        let amount = recordDose ? dose : nil
        let amountUnit = recordDose ? unit.rawValue : nil
        Task {
            await model.logMedicine(name: resolvedName, dose: amount, unit: amountUnit, at: givenAt)
            isSaving = false
            isPresented = false
        }
    }
}

/// Sleep start sheet — Start (in-app) or log a past nap.
/// Running sleep (pause / stop / start time) always opens `ActiveTimerView`
/// via the shared spring panel — same surface as the RunningTimerBar expand.
/// Watch / App Intents / widgets still call `startSleepTimer` directly.
struct SleepLogSheet: View {
    var model: AppModel
    @Binding var isPresented: Bool
    /// Opens past-nap UI (parent presents `PastSleepLogSheet` as a system sheet).
    var onLogPastNap: (() -> Void)? = nil
    @State private var isBusy = false

    var body: some View {
        LogSheetScaffold(title: "Sleep", isPresented: $isPresented) {
            sleepStartPanel
        }
    }

    private var sleepStartPanel: some View {
        VStack(spacing: 20) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(DesignTokens.sleep)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .accessibilityHidden(true)

            Text("Start a shared sleep timer")
                .font(.subheadline)
                .foregroundStyle(DesignTokens.textSecondary)
                .frame(maxWidth: .infinity)

            PrimaryLogButton(
                title: "Start sleep",
                systemImage: "play.fill",
                accent: DesignTokens.sleep,
                isBusy: isBusy
            ) {
                startSleep()
            }

            if let onLogPastNap {
                Button(action: onLogPastNap) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.subheadline.weight(.semibold))
                        Text("Log a past nap")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(DesignTokens.sleep)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(BenitoBorderlessButtonStyle())
                .disabled(isBusy)
                .accessibilityLabel("Log a past nap")
                .accessibilityHint("Enter when baby fell asleep and woke up")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func startSleep() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            await model.startSleepTimer()
            isBusy = false
            // Parent presents ActiveTimerView from this sheet's onDismiss
            // once the sleep timer is actually running.
            if let timer = model.babyState?.activeTimer, timer.isActive,
               RunningTimerLabel.isSleep(kind: timer.kind) {
                isPresented = false
            }
        }
    }
}

/// Backfill a nap that wasn't timed.
struct PastSleepLogSheet: View {
    var model: AppModel
    @Binding var isPresented: Bool

    @State private var start = Date().addingTimeInterval(-60 * 60)
    @State private var end = Date()
    @State private var isSaving = false

    private static let maxLookback: TimeInterval = 7 * 24 * 60 * 60

    private var isValid: Bool { end > start }

    var body: some View {
        LogSheetScaffold(title: "Past nap", isPresented: $isPresented) {
            ContinuousCornerCard(padding: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    napPicker("Fell asleep", selection: $start)
                    napPicker("Woke up", selection: $end)

                    HStack {
                        LogFieldLabel(text: "Duration")
                        Spacer()
                        Text(isValid ? PrototypeFormatters.compactDuration(end.timeIntervalSince(start)) : "—")
                            .font(.headline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(isValid ? DesignTokens.sleep : DesignTokens.textTertiary)
                    }
                    .accessibilityElement(children: .combine)

                    if !isValid {
                        Text("Wake time must be after the start.")
                            .font(.footnote)
                            .foregroundStyle(DesignTokens.fault)
                    }

                    PrimaryLogButton(
                        title: "Log nap",
                        systemImage: "moon.fill",
                        accent: DesignTokens.sleep,
                        isBusy: isSaving
                    ) {
                        submitNap()
                    }
                    .disabled(!isValid)
                    .opacity(isValid ? 1 : 0.45)
                }
            }
        }
    }

    private func napPicker(_ title: String, selection: Binding<Date>) -> some View {
        DatePicker(
            title,
            selection: selection,
            in: Date().addingTimeInterval(-Self.maxLookback)...Date(),
            displayedComponents: [.date, .hourAndMinute]
        )
        .font(.headline)
        .foregroundStyle(DesignTokens.textPrimary)
        .tint(DesignTokens.sleep)
        .frame(minHeight: 44)
    }

    private func submitNap() {
        guard isValid, !isSaving else { return }
        isSaving = true
        Task {
            await model.logManualSleep(start: start, end: end)
            isSaving = false
            isPresented = false
        }
    }
}

// MARK: - Shared building blocks

/// Navigation chrome + scrollable column shared by the log sheets.
struct LogSheetScaffold<Content: View>: View {
    let title: String
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .padding(DesignTokens.gutter)
            }
            .background(DesignTokens.bgCanvas.ignoresSafeArea())
            .navigationTitle(title)
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
                }
            }
            .benitoNavigationBarGlass()
        }
    }
}

/// Big −/+ stepper with a rounded readout; VoiceOver adjusts it with swipe up/down.
struct LogAmountStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    var accent: Color = DesignTokens.feed

    var body: some View {
        HStack(spacing: 12) {
            stepButton(systemImage: "minus", enabled: value > range.lowerBound) { decrement() }

            VStack(spacing: 2) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(DesignTokens.textSecondary)
                Text("\(Self.format(value)) \(unit)")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.textPrimary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity)

            stepButton(systemImage: "plus", enabled: value < range.upperBound) { increment() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Self.format(value)) \(spokenUnit)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: increment()
            case .decrement: decrement()
            @unknown default: break
            }
        }
    }

    private var spokenUnit: String {
        switch unit {
        case "oz": return "ounces"
        case "min": return "minutes"
        default: return unit
        }
    }

    private func increment() {
        value = Self.snap(value + step, step: step, range: range)
    }

    private func decrement() {
        value = Self.snap(value - step, step: step, range: range)
    }

    private func stepButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.bold))
                .frame(width: 56, height: 56)
                .foregroundStyle(enabled ? accent : DesignTokens.textTertiary)
                .background(accent.opacity(enabled ? 0.18 : 0.06))
                .clipShape(Circle())
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
        .disabled(!enabled)
    }

    /// Rounds to the nearest step and clamps into `range`.
    static func snap(_ raw: Double, step: Double, range: ClosedRange<Double>) -> Double {
        let snapped = (raw / step).rounded() * step
        return min(range.upperBound, max(range.lowerBound, snapped))
    }

    /// "3", "3.5" — at most one decimal.
    static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

/// Full-width primary action at the bottom of a log sheet.
struct PrimaryLogButton: View {
    let title: String
    let systemImage: String
    var accent: Color = DesignTokens.feed
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isBusy {
                    ProgressView()
                        .tint(DesignTokens.onAccent)
                } else {
                    Image(systemName: systemImage)
                        .font(.headline.weight(.bold))
                }
                Text(title)
                    .font(.headline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: DesignTokens.thumbMin)
            .foregroundStyle(DesignTokens.onAccent)
            .background(accent, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
        .disabled(isBusy)
        .accessibilityLabel(title)
    }
}
