import SwiftUI
import BenitoKit

/// Single-day Timeline mode: per-day summary (sleep / feeds / diapers) + that day's events.
struct TimelineDayView: View {
    var model: AppModel
    var isSelected: Bool = true

    @State private var dayOffset: Int = 0
    @State private var events: [EventDTO] = []
    @State private var summary: DailySummaryDTO?
    @State private var loadedDayStart: Date?
    @State private var editing: EventDTO?
    @State private var pendingDelete: EventDTO?
    /// Wall clock sampled when the day loads / reloads (not a 1Hz chrome tick).
    @State private var now = Date()

    private var calendar: Calendar { .current }

    /// The selected day; bounds both the summary request and the "Since 12 AM" caption.
    private var dayWindow: DayWindow {
        DayWindow(offset: dayOffset, from: now, calendar: calendar)
    }

    private var dayStart: Date { dayWindow.start }

    private var dayEnd: Date { dayWindow.end }

    var body: some View {
        VStack(spacing: 0) {
            header
            daySummaryStrip
                .padding(.horizontal, DesignTokens.gutter)
                .padding(.bottom, 10)
            dayEventList
        }
        .background(DesignTokens.bgCanvas.ignoresSafeArea())
        .onAppear(perform: applyScreenshotDayOverride)
        .task(id: "\(dayStart.timeIntervalSince1970)-\(isSelected)") {
            guard isSelected else { return }
            now = Date()
            await load(dayStart: dayStart, dayEnd: dayEnd)
        }
        .sheet(item: $editing) { event in
            EventEditorSheet(event: event, model: model)
        }
        .confirmationDialog(
            pendingDelete.map { "Delete this \(CalendarItem(source: .event($0)).typeName.lowercased())?" } ?? "Delete entry?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { event in
            Button("Delete", role: .destructive) {
                Task { _ = await model.deleteEvent(event) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// `SIMCTL_CHILD_BENITO_PROTOTYPE_DAY_OFFSET` = 0, -1, … opens a past day (screenshots only).
    private func applyScreenshotDayOverride() {
        guard let raw = ProcessInfo.processInfo.environment["BENITO_PROTOTYPE_DAY_OFFSET"],
              let offset = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              offset <= 0 else { return }
        dayOffset = offset
    }

    // MARK: - Header (prev / next day)

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                dayOffset -= 1
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous day")

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text(dayTitle)
                    .font(.headline)
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(daySubtitle)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            if dayOffset != 0 {
                Button("Today") { dayOffset = 0 }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.feed)
                    .accessibilityHint("Shows today")
            }

            Button {
                dayOffset += 1
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(dayOffset >= 0 ? DesignTokens.textTertiary.opacity(0.5) : DesignTokens.textSecondary)
            }
            .disabled(dayOffset >= 0)
            .accessibilityLabel("Next day")
        }
        .foregroundStyle(DesignTokens.textSecondary)
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .buttonStyle(BenitoBorderlessButtonStyle())
    }

    private var dayTitle: String {
        if calendar.isDateInToday(dayStart) { return "Today" }
        if calendar.isDateInYesterday(dayStart) { return "Yesterday" }
        return dayStart.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var daySubtitle: String {
        if calendar.isDateInToday(dayStart) || calendar.isDateInYesterday(dayStart) {
            return dayStart.formatted(.dateTime.month(.abbreviated).day().year())
        }
        return dayStart.formatted(.dateTime.year())
    }

    // MARK: - Summary strip

    private var daySummaryStrip: some View {
        let stats = resolvedStats
        return VStack(spacing: 10) {
            DayWindowCaption(window: dayWindow, now: .now)
                .padding(.horizontal, 12)

            HStack(spacing: 0) {
            summaryStat(
                label: "Sleep",
                value: stats.sleepLabel,
                detail: nil,
                accent: DesignTokens.sleep
            )
            stripDivider
            summaryStat(
                label: "Feeds",
                value: stats.feedCountLabel,
                detail: stats.feedDetail,
                accent: DesignTokens.feed
            )
            stripDivider
            summaryStat(
                label: "Diapers",
                value: stats.diaperLabel,
                detail: nil,
                accent: DesignTokens.diaper
            )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(stats.accessibilityLabel)

            Rectangle()
                .fill(DesignTokens.textSecondary.opacity(0.15))
                .frame(height: 1)
                .padding(.horizontal, 12)
                .accessibilityHidden(true)

            FedTotalsLine(totals: stats.fed, emptyText: "No feeds logged")
                .padding(.horizontal, 12)

            if CryingTotalLine.isVisible(seconds: stats.cryingSeconds) {
                CryingTotalLine(seconds: stats.cryingSeconds)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .benitoGlass(interactive: false)
        .accessibilityElement(children: .contain)
    }

    private var stripDivider: some View {
        Rectangle()
            .fill(DesignTokens.textSecondary.opacity(0.2))
            .frame(width: 1, height: 36)
    }

    private func summaryStat(label: String, value: String, detail: String?, accent: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(DesignTokens.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Event list

    private var dayEventList: some View {
        Group {
            if events.isEmpty {
                VStack(spacing: 12) {
                    Spacer(minLength: 24)
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 36))
                        .foregroundStyle(DesignTokens.textSecondary)
                    Text("Nothing logged")
                        .font(.headline)
                        .foregroundStyle(DesignTokens.textPrimary)
                    Text("Feeds, diapers, and sleep for this day show up here.")
                        .font(.subheadline)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(events) { event in
                        dayRow(event)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(
                                top: 5,
                                leading: DesignTokens.gutter,
                                bottom: 5,
                                trailing: DesignTokens.gutter
                            ))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.vertical, 7, for: .scrollContent)
            }
        }
    }

    private func dayRow(_ event: EventDTO) -> some View {
        Button {
            editing = event
        } label: {
            let item = CalendarItem(source: .event(event))
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(item.color)
                    .frame(width: 10, height: 10)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.shortTitle)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(DesignTokens.textPrimary)
                        Spacer()
                        Text(PrototypeFormatters.shortTime(event.startedAt))
                            .font(.caption)
                            .foregroundStyle(DesignTokens.textSecondary)
                    }
                    if let detail = item.compactDetail(now: now) {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(DesignTokens.textSecondary)
                    }
                }
            }
            .padding(14)
            .benitoGlass(interactive: false)
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
        .accessibilityHint("Edit or delete this entry")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                pendingDelete = event
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(DesignTokens.fault)
        }
    }

    // MARK: - Load + stats

    @MainActor
    private func load(dayStart: Date, dayEnd: Date) async {
        async let fetchedEvents = model.localEvents(from: dayStart, to: dayEnd)
        async let fetchedSummary = model.dailySummary(from: dayStart, to: dayEnd)
        let (ev, sum) = await (fetchedEvents, fetchedSummary)
        guard dayStart == self.dayStart else { return }
        events = ev.sorted { $0.startedAt > $1.startedAt }
        summary = sum
        loadedDayStart = dayStart
    }

    private struct DayStats {
        var sleepLabel: String
        var feedCountLabel: String
        var feedDetail: String?
        var diaperLabel: String
        var fed: DailyFedTotals
        var cryingSeconds: TimeInterval
        var accessibilityLabel: String
    }

    private var resolvedStats: DayStats {
        let feedCount: Int
        let diaperCount: Int
        let sleepHours: Double
        let feedSeconds: Double
        let fed: DailyFedTotals
        let localFed = DailyFedTotals(events: events, from: dayStart, to: dayEnd)
        let localCrying = ActivityKind.crying.activeSeconds(in: events, from: dayStart, to: dayEnd)
        var cryingSeconds = localCrying

        if let s = summary, loadedDayStart == dayStart {
            feedCount = s.feedBreastCount + s.feedBottleCount + s.feedSolidCount
            diaperCount = s.diaperWet + s.diaperDirty + s.diaperBoth + s.diaperOther
            sleepHours = s.sleepHours
            feedSeconds = s.feedSeconds
            fed = DailyFedTotals(summary: s, fallbackNursingSeconds: localFed.nursingSeconds)
            cryingSeconds = s.cryingSeconds ?? localCrying
        } else {
            let active = events.filter { $0.deletedAt == nil }
            let startedInDay = active.filter { $0.startedAt >= dayStart && $0.startedAt < dayEnd }
            feedCount = startedInDay.filter { $0.type.hasPrefix("feed_") }.count
            diaperCount = startedInDay.filter { $0.type == EventType.diaper.rawValue }.count
            sleepHours = active
                .filter { $0.type == EventType.sleep.rawValue }
                .reduce(0.0) { partial, event in
                    partial + DailyFedTotals.clippedActiveSeconds(of: event, from: dayStart, to: dayEnd) / 3600
                }
            feedSeconds = startedInDay
                .filter { $0.type.hasPrefix("feed_") }
                .compactMap(\.activeDuration)
                .reduce(0, +)
            fed = localFed
        }

        let sleepLabel = sleepHours > 0
            ? PrototypeFormatters.compactDuration(sleepHours * 3600)
            : "—"
        let feedCountLabel = "\(feedCount)"
        let feedDetail: String? = {
            guard feedCount > 0, feedSeconds > 0 else { return nil }
            let total = PrototypeFormatters.compactDuration(feedSeconds)
            let avg = PrototypeFormatters.compactDuration(feedSeconds / Double(feedCount))
            return "\(total) · avg \(avg)"
        }()
        let diaperLabel = "\(diaperCount)"
        var a11y = "Sleep \(sleepLabel), \(feedCount) feeds"
        if let feedDetail { a11y += ", \(feedDetail)" }
        a11y += ", \(diaperCount) diapers"
        return DayStats(
            sleepLabel: sleepLabel,
            feedCountLabel: feedCountLabel,
            feedDetail: feedDetail,
            diaperLabel: diaperLabel,
            fed: fed,
            cryingSeconds: cryingSeconds,
            accessibilityLabel: a11y
        )
    }
}

#Preview {
    TimelineDayView(model: AppModel(serverURLString: BenitoServerPresets.loopback))
}
