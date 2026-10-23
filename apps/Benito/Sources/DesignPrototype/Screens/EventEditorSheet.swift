import SwiftUI
import BenitoKit

/// Edits or deletes one logged event. Only fields the user actually changed are sent
/// (`PATCH /events/{id}` keeps everything else via COALESCE).
struct EventEditorSheet: View {
    let event: EventDTO
    var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var startedAt: Date
    @State private var endedAt: Date
    @State private var subtype: String
    @State private var side: String
    @State private var ounces: Double
    @State private var notes: String
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false

    /// Normalized starting values; edits are diffed against these, not the raw event.
    private let initial: Snapshot

    private struct Snapshot {
        let subtype: String
        let side: String
        let ounces: Double
        let notes: String
    }

    init(event: EventDTO, model: AppModel) {
        self.event = event
        self.model = model
        let snapshot = Snapshot(
            subtype: (event.subtype ?? "").lowercased(),
            side: Self.normalizedSide(event.side),
            ounces: event.amountValue ?? 0,
            notes: event.notes ?? ""
        )
        initial = snapshot
        _startedAt = State(initialValue: event.startedAt)
        _endedAt = State(initialValue: event.endedAt ?? event.startedAt)
        _subtype = State(initialValue: snapshot.subtype)
        _side = State(initialValue: snapshot.side)
        _ounces = State(initialValue: snapshot.ounces)
        _notes = State(initialValue: snapshot.notes)
    }

    // MARK: - Derived

    private var item: CalendarItem { CalendarItem(source: .event(event)) }
    private var isRanged: Bool { event.endedAt != nil }
    private var isDiaper: Bool { event.type == EventType.diaper.rawValue }
    private var isBottle: Bool { event.type == EventType.feedBottle.rawValue }
    private var isBreast: Bool { event.type == EventType.feedBreast.rawValue }
    private var isPump: Bool { event.type == EventType.pump.rawValue }
    private var isMedicine: Bool { event.type == EventType.medicine.rawValue }
    private var isSleep: Bool { event.type == EventType.sleep.rawValue }
    /// Walk / car ride (switchable between the two). Crying has no subtype choice.
    private var isOuting: Bool { ActivityKind(event: event)?.isOuting == true }
    private var hasAmount: Bool { isBottle || isPump || isMedicine }
    /// Completed sleep can be turned back into a live timer from its start.
    private var canResumeSleep: Bool {
        isSleep && event.endedAt != nil && model.babyState?.activeTimer?.isActive != true
    }
    private var amountUnit: String { event.amountUnit ?? (isMedicine ? "ml" : "oz") }

    private var rangeIsInvalid: Bool { isRanged && endedAt < startedAt }

    /// Pause-excluded duration for the edited start/end.
    private var activeDuration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt) - TimeInterval(event.pausedSeconds))
    }

    private var changes: UpdateEventRequestDTO {
        var changes = UpdateEventRequestDTO()
        if abs(startedAt.timeIntervalSince(event.startedAt)) >= 1 {
            changes.startedAt = startedAt
        }
        if let originalEnd = event.endedAt, abs(endedAt.timeIntervalSince(originalEnd)) >= 1 {
            changes.endedAt = endedAt
        }
        if (isDiaper || isBottle || isMedicine || isOuting), !subtype.isEmpty, subtype != initial.subtype {
            changes.subtype = subtype
        }
        if (isBreast || isPump), !side.isEmpty, side != initial.side {
            changes.side = side
        }
        if hasAmount, ounces != initial.ounces || (event.amountValue == nil && ounces > 0) {
            changes.amountValue = ounces
            if event.amountUnit == nil { changes.amountUnit = isMedicine ? "ml" : "oz" }
        }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNotes != initial.notes.trimmingCharacters(in: .whitespacesAndNewlines) {
            changes.notes = trimmedNotes
        }
        return changes
    }

    private var canSave: Bool {
        !isWorking && !rangeIsInvalid && changes != UpdateEventRequestDTO()
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                header
                timeSection
                detailsSection
                notesSection
                actionsSection
            }
            .scrollContentBackground(.hidden)
            .background(DesignTokens.bgCanvas.ignoresSafeArea())
            .tint(item.color)
            .navigationTitle("Edit \(item.typeName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .benitoNavigationBarGlass()
            .confirmationDialog(
                "Delete this \(item.typeName.lowercased())?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { Task { await delete() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It will be removed for everyone in the family.")
            }
        }
        .interactiveDismissDisabled(isWorking || changes != UpdateEventRequestDTO())
    }

    // MARK: - Sections

    private var header: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(item.color)
                    .accessibilityHidden(true)
                Text(item.shortTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(DesignTokens.textPrimary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 4))
        }
    }

    private var timeSection: some View {
        Section {
            DatePicker(
                isRanged ? "Start" : "Time",
                selection: $startedAt,
                in: ...max(Date.now, event.startedAt),
                displayedComponents: [.date, .hourAndMinute]
            )
            .foregroundStyle(DesignTokens.textPrimary)

            if isRanged {
                DatePicker(
                    "End",
                    selection: $endedAt,
                    in: ...max(Date.now, event.endedAt ?? event.startedAt),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .foregroundStyle(DesignTokens.textPrimary)

                readOnlyRow("Duration", value: rangeIsInvalid ? "—" : PrototypeFormatters.compactDuration(activeDuration))
                if event.pausedSeconds > 0 {
                    readOnlyRow("Paused", value: PrototypeFormatters.compactDuration(TimeInterval(event.pausedSeconds)))
                }
            }
        } header: {
            sectionHeader("When")
        } footer: {
            if rangeIsInvalid {
                Text("End must be after start.")
                    .foregroundStyle(DesignTokens.fault)
            } else if isRanged, event.pausedSeconds > 0 {
                Text("Duration excludes time the timer was paused.")
                    .foregroundStyle(DesignTokens.textTertiary)
            }
        }
        .listRowBackground(BenitoGlassListRowBackground())
    }

    @ViewBuilder
    private var detailsSection: some View {
        if isDiaper || isBottle || isBreast || isPump || isMedicine || isOuting {
            Section {
                if isMedicine {
                    TextField("Name", text: $subtype)
                        .textInputAutocapitalization(.words)
                        .foregroundStyle(DesignTokens.textPrimary)
                }
                if isDiaper {
                    CapsuleSegmentBar(
                        options: ["wet", "dirty", "both"],
                        selection: subtype,
                        title: { $0.capitalized },
                        accent: item.color,
                        accessibilityLabel: "Diaper"
                    ) { subtype = $0 }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
                }
                if isOuting {
                    CapsuleSegmentBar(
                        options: ActivityKind.outings.map(\.rawValue),
                        selection: subtype,
                        title: { ActivityKind(rawValue: $0)?.title ?? $0 },
                        accent: item.color,
                        accessibilityLabel: "Outing"
                    ) { subtype = $0 }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
                }
                if isBottle {
                    CapsuleSegmentBar(
                        options: BottleMilk.allCases.map(\.rawValue),
                        selection: subtype,
                        title: { BottleMilk(rawValue: $0)?.label ?? $0 },
                        accent: item.color,
                        accessibilityLabel: "Milk"
                    ) { subtype = $0 }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
                }
                if isBreast {
                    CapsuleSegmentBar(
                        options: ["L", "R"],
                        selection: side,
                        title: { $0 == "L" ? "Left" : "Right" },
                        accent: item.color,
                        accessibilityLabel: "Side"
                    ) { side = $0 }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
                }
                if isPump {
                    CapsuleSegmentBar(
                        options: PumpSide.allCases.map(\.rawValue),
                        selection: side,
                        title: { PumpSide(rawValue: $0)?.label ?? $0 },
                        accent: item.color,
                        accessibilityLabel: "Side"
                    ) { side = $0 }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
                }
                if hasAmount {
                    Stepper(value: $ounces, in: 0...max(20, initial.ounces), step: 0.5) {
                        HStack {
                            Text("Amount")
                                .foregroundStyle(DesignTokens.textPrimary)
                            Spacer(minLength: 8)
                            Text("\(CalendarItem.formatAmount(ounces)) \(amountUnit)")
                                .monospacedDigit()
                                .foregroundStyle(DesignTokens.textSecondary)
                        }
                    }
                    .accessibilityValue("\(CalendarItem.formatAmount(ounces)) \(amountUnit == "oz" ? "ounces" : amountUnit)")
                }
            } header: {
                sectionHeader(detailsTitle)
            }
            .listRowBackground(BenitoGlassListRowBackground())
        }
    }

    private var detailsTitle: String {
        if isDiaper { return "Diaper" }
        if isBottle { return "Bottle" }
        if isPump { return "Pump" }
        if isMedicine { return "Medicine" }
        if isOuting { return "Outing" }
        return "Side"
    }

    private var notesSection: some View {
        Section {
            TextField("Add a note", text: $notes, axis: .vertical)
                .lineLimit(2...6)
                .foregroundStyle(DesignTokens.textPrimary)
        } header: {
            sectionHeader("Notes")
        }
        .listRowBackground(BenitoGlassListRowBackground())
    }

    /// Bottom actions so Save/Delete are reachable one-handed.
    /// Capsule fills only — never a solid rectangle stuffed inside the Form's glass row chrome.
    private var actionsSection: some View {
        Section {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(DesignTokens.fault)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            }

            if canResumeSleep {
                capsuleActionButton(
                    title: "Resume sleep timer",
                    systemImage: "play.fill",
                    foreground: DesignTokens.onAccent,
                    background: DesignTokens.sleep,
                    enabled: !isWorking
                ) {
                    Task { await resumeSleep() }
                }
            }

            capsuleActionButton(
                title: "Save changes",
                systemImage: "checkmark",
                foreground: canSave ? DesignTokens.onAccent : DesignTokens.textTertiary,
                background: canSave ? item.color : DesignTokens.bgCardElevated,
                enabled: canSave
            ) {
                Task { await save() }
            }

            capsuleActionButton(
                title: "Delete \(item.typeName.lowercased())",
                systemImage: "trash",
                foreground: DesignTokens.fault,
                background: DesignTokens.fault.opacity(0.16),
                enabled: !isWorking
            ) {
                confirmingDelete = true
            }
        }
    }

    private func capsuleActionButton(
        title: String,
        systemImage: String,
        foreground: Color,
        background: Color,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isWorking {
                    ProgressView()
                        .tint(foreground)
                } else {
                    Image(systemName: systemImage)
                        .font(.headline.weight(.bold))
                }
                Text(title)
                    .font(.headline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: DesignTokens.thumbMin)
            .foregroundStyle(foreground)
            .background(background, in: Capsule(style: .continuous))
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
        .disabled(!enabled)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
        .accessibilityLabel(title)
    }

    // MARK: - Pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(DesignTokens.textSecondary)
    }

    private func readOnlyRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(DesignTokens.textPrimary)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private static func normalizedSide(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        switch raw.lowercased() {
        case "l", "left": return "L"
        case "r", "right": return "R"
        case "both": return "both"
        default: return raw
        }
    }

    // MARK: - Actions

    private func resumeSleep() async {
        guard canResumeSleep, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        let succeeded = await model.resumeSleepTimer(from: event, startedAt: startedAt)
        isWorking = false
        if succeeded {
            dismiss()
        } else {
            errorMessage = model.status
        }
    }

    private func save() async {
        guard canSave else { return }
        isWorking = true
        errorMessage = nil
        let succeeded = await model.updateEvent(event, changes: changes)
        isWorking = false
        if succeeded {
            dismiss()
        } else {
            errorMessage = model.status
        }
    }

    private func delete() async {
        isWorking = true
        errorMessage = nil
        let succeeded = await model.deleteEvent(event)
        isWorking = false
        if succeeded {
            dismiss()
        } else {
            errorMessage = model.status
        }
    }
}
