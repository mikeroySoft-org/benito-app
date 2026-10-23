import BenitoKit
import SwiftUI

/// Timed `activity` spans — walk / car ride (one sheet with a picker) or crying (its own
/// sheet). Start a shared timer (it stops into an `activity` event, like sleep), or backfill
/// one that already happened with an optional note. A running one opens `ActiveTimerView`
/// instead (the parent routes there), where its start time can be edited.
struct ActivityLogSheet: View {
    var model: AppModel
    @Binding var isPresented: Bool
    /// Kinds offered here; a picker shows when there is more than one.
    var kinds: [ActivityKind]
    var title: String

    @State private var kind: ActivityKind
    @State private var start = Date.now.addingTimeInterval(-30 * 60)
    @State private var end = Date.now
    @State private var note = ""
    @State private var isBusy = false

    private static let maxLookback: TimeInterval = 7 * 24 * 60 * 60

    init(model: AppModel, isPresented: Binding<Bool>, kinds: [ActivityKind], title: String) {
        self.model = model
        _isPresented = isPresented
        self.kinds = kinds
        self.title = title
        _kind = State(initialValue: kinds.first ?? .walk)
    }

    /// Walk / car ride.
    static func outing(model: AppModel, isPresented: Binding<Bool>) -> ActivityLogSheet {
        ActivityLogSheet(model: model, isPresented: isPresented, kinds: ActivityKind.outings, title: "Outing")
    }

    /// Crying spell (mood).
    static func crying(model: AppModel, isPresented: Binding<Bool>) -> ActivityLogSheet {
        ActivityLogSheet(model: model, isPresented: isPresented, kinds: [.crying], title: "Crying")
    }

    private var accent: Color { DesignTokens.accent(for: kind) }

    private var isPastValid: Bool { end > start }

    /// Another timer (feed / sleep / outing) is running — one shared timer at a time.
    private var blockingTimerTitle: String? {
        guard let t = model.babyState?.activeTimer, t.isActive else { return nil }
        return RunningTimerLabel.title(kind: t.kind, side: t.side)
    }

    var body: some View {
        LogSheetScaffold(title: title, isPresented: $isPresented) {
            if kinds.count > 1 {
                CapsuleSegmentBar(
                    options: kinds,
                    selection: kind,
                    title: \.title,
                    accent: accent,
                    minHeight: 44,
                    accessibilityLabel: title
                ) { kind = $0 }
            }

            ContinuousCornerCard(padding: 16) {
                VStack(spacing: 14) {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)

                    if let blockingTimerTitle {
                        Text("Stop the running \(blockingTimerTitle.lowercased()) timer to start the \(kind.noun) timer.")
                            .font(.subheadline)
                            .foregroundStyle(DesignTokens.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Start a shared \(kind.noun) timer")
                            .font(.subheadline)
                            .foregroundStyle(DesignTokens.textSecondary)
                            .frame(maxWidth: .infinity)
                    }

                    PrimaryLogButton(
                        title: "Start \(kind.noun)",
                        systemImage: "play.fill",
                        accent: accent,
                        isBusy: isBusy
                    ) {
                        startTimer()
                    }
                    .disabled(blockingTimerTitle != nil)
                    .opacity(blockingTimerTitle == nil ? 1 : 0.45)
                }
            }

            LogFieldLabel(text: "Already happened")
                .padding(.top, 8)

            ContinuousCornerCard(padding: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    DatePicker(
                        "Started",
                        selection: $start,
                        in: Date.now.addingTimeInterval(-Self.maxLookback)...Date.now,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .font(.headline)
                    .foregroundStyle(DesignTokens.textPrimary)
                    .frame(minHeight: 44)

                    DatePicker(
                        "Ended",
                        selection: $end,
                        in: Date.now.addingTimeInterval(-Self.maxLookback)...Date.now,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .font(.headline)
                    .foregroundStyle(DesignTokens.textPrimary)
                    .frame(minHeight: 44)

                    HStack {
                        LogFieldLabel(text: "Duration")
                        Spacer()
                        Text(isPastValid ? PrototypeFormatters.compactDuration(end.timeIntervalSince(start)) : "—")
                            .font(.headline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(isPastValid ? accent : DesignTokens.textTertiary)
                    }
                    .accessibilityElement(children: .combine)

                    if !isPastValid {
                        Text("End must be after the start.")
                            .font(.footnote)
                            .foregroundStyle(DesignTokens.fault)
                    }

                    TextField("Note (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                        .font(.body)
                        .foregroundStyle(DesignTokens.textPrimary)
                        .frame(minHeight: 44)

                    PrimaryLogButton(
                        title: "Log \(kind.noun)",
                        systemImage: kind.systemImage,
                        accent: accent,
                        isBusy: isBusy
                    ) {
                        logPast()
                    }
                    .disabled(!isPastValid)
                    .opacity(isPastValid ? 1 : 0.45)
                }
            }
            .tint(accent)
        }
    }

    private func startTimer() {
        guard !isBusy, blockingTimerTitle == nil else { return }
        isBusy = true
        Task {
            await model.startActivityTimer(kind)
            isBusy = false
            // Parent presents ActiveTimerView from this sheet's onDismiss once it runs.
            if let timer = model.babyState?.activeTimer, timer.isActive,
               ActivityKind(timerKind: timer.kind) != nil {
                isPresented = false
            }
        }
    }

    private func logPast() {
        guard isPastValid, !isBusy else { return }
        isBusy = true
        Task {
            await model.logActivity(kind, start: start, end: end, note: note)
            isBusy = false
            isPresented = false
        }
    }
}
