import SwiftUI
import UIKit
import BenitoKit

/// Outlook / Apple Calendar–style week grid: a rolling 7-day window (today is the rightmost column),
/// 24 hour rows, one block per event segment, running timer drawn as an open dashed block.
struct TimelineWeekView: View {
    var model: AppModel
    /// When false (inactive TabView child), do not advance `now` from the minute publisher.
    var isSelected: Bool = true

    /// 0 = the 7 days ending today; -1 = the 7 days before that; never positive.
    @State private var weekOffset = 0
    @State private var now = Date()
    @State private var events: [EventDTO] = []
    @State private var loadedWindow: WeekWindow?
    @State private var selection: CalendarItem?
    /// Set by the detail sheet's Edit button; presented once the detail sheet has dismissed.
    @State private var pendingEdit: EventDTO?
    @State private var editing: EventDTO?
    /// Layout scale for hour rows and day columns (1 = columns fit the screen).
    /// Committed when a pinch ends — not on every touch sample.
    @State private var zoomScale: CGFloat = 1
    /// Continuous scale while a pinch is active. Event frames stay at `zoomScale`;
    /// this drives a visual scale so the grid tracks the fingers without a relayout per sample.
    @State private var previewScale: CGFloat = 1
    /// `previewScale` at the start of the current pinch, so the recognizer's relative scale compounds correctly.
    @State private var pinchBaseScale: CGFloat = 1
    /// Pinch centroid tracking. Not `@State` scroll offset — publishing offset relayouts the week path every frame.
    @State private var zoomBridge = TimelineWeekZoomBridge()
    /// Visual shift that keeps the finger midpoint fixed while layout size stays frozen.
    /// Cleared on commit, when the real content offset takes over.
    @State private var pinchTranslation: CGSize = .zero

    @ScaledMetric(relativeTo: .caption2) private var scaledHourHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .caption2) private var scaledGutterWidth: CGFloat = 44

    /// Minute cadence only while this tab is selected. TabView keeps inactive children
    /// alive — a Combine `Timer.publish.autoconnect()` would keep firing forever off-tab.
    private let gridInset: CGFloat = 10
    fileprivate static let minZoom: CGFloat = 0.75
    /// Cap below 3× — full-height Path + 7-day columns at 3× was a large per-frame alloc during pinch.
    /// The same cap applies to both axes; a pinch must not exceed it (area grows with the square).
    fileprivate static let maxZoom: CGFloat = 2.25

    private var calendar: Calendar { .current }
    /// Scales with Dynamic Type, then the committed pinch zoom; clamped so a day still scrolls reasonably.
    private var baseHourHeight: CGFloat { min(max(scaledHourHeight, 44), 66) }
    /// Layout row height. Frozen for the duration of a pinch (`previewScale` carries the live scale).
    private var hourHeight: CGFloat { baseHourHeight * zoomScale }
    /// Visual scale on top of the frozen layout. 1 when nothing is pinching.
    private var pinchRatio: CGFloat {
        guard zoomScale > 0 else { return 1 }
        return previewScale / zoomScale
    }
    private var gutterWidth: CGFloat { min(max(scaledGutterWidth, 40), 64) }

    private var window: WeekWindow {
        WeekWindow.ending(weeksFromToday: weekOffset, now: now, calendar: calendar)
    }

    var body: some View {
        let window = self.window
        VStack(spacing: 0) {
            header(window)
            weekGrid(window)
        }
        .background(DesignTokens.bgCanvas)
        .task(id: window) { await load(window) }
        .onChange(of: model.timeline) {
            Task { await load(self.window) }
        }
        .background {
            // Mount the minute TimelineView only while selected so off-tab retention
            // cannot keep a schedule (and now-line layout work) alive.
            if isSelected {
                TimelineWeekMinuteTick(now: $now)
            }
        }
        .onChange(of: isSelected) { _, selected in
            // Catch up the now-line / open timer block when returning to Timeline.
            if selected { now = Date() }
        }
        .sheet(item: $selection, onDismiss: presentPendingEdit) { item in
            CalendarItemDetailSheet(item: item) { event in
                pendingEdit = event
                selection = nil
            }
        }
        .sheet(item: $editing, onDismiss: { Task { await load(self.window) } }) { event in
            EventEditorSheet(event: event, model: model)
        }
    }

    /// One sheet at a time: the editor replaces the detail sheet after it finishes dismissing.
    private func presentPendingEdit() {
        guard let event = pendingEdit else { return }
        pendingEdit = nil
        editing = event
    }

    @MainActor
    private func load(_ requested: WeekWindow) async {
        let fetched = await model.localEvents(from: requested.from, to: requested.to)
        // Drop stale responses when the user paged (or the day rolled) mid-flight.
        guard requested == window else { return }
        events = fetched
        loadedWindow = requested
    }

    // MARK: - Header

    private func header(_ window: WeekWindow) -> some View {
        HStack(spacing: 4) {
            Button {
                weekOffset -= 1
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous week")

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text(rangeTitle(window))
                    .font(.headline)
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle(window))
                    .font(.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            if weekOffset != 0 {
                Button("Today") { weekOffset = 0 }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.feed)
                    .accessibilityHint("Shows the last 7 days")
            }

            Button {
                weekOffset += 1
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(weekOffset >= 0 ? DesignTokens.textTertiary.opacity(0.5) : DesignTokens.textSecondary)
            }
            .disabled(weekOffset >= 0)
            .accessibilityLabel("Next week")
        }
        .foregroundStyle(DesignTokens.textSecondary)
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func rangeTitle(_ window: WeekWindow) -> String {
        guard let first = window.days.first, let last = window.days.last else { return "" }
        var style = Date.IntervalFormatStyle().month(.abbreviated).day()
        if calendar.component(.year, from: first) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return (first..<last).formatted(style)
    }

    private func subtitle(_ window: WeekWindow) -> String {
        if loadedWindow == window, events.isEmpty, model.babyState?.activeTimer?.isActive != true {
            return "Nothing logged"
        }
        switch weekOffset {
        case 0: return "Last 7 days"
        case -1: return "1 week earlier"
        default: return "\(-weekOffset) weeks earlier"
        }
    }

    private func dayHeaderRow(_ window: WeekWindow, dayWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            // Frozen corner: weekday labels scroll horizontally with their columns, but this
            // gutter stays put so names don't slide under the hour labels.
            Color.clear
                .frame(width: gutterWidth)
                .background(DesignTokens.bgCanvas)
                .modifier(TimelineWeekPinnedAxes(axes: .horizontal))
                .zIndex(1)
            // Same x scale and x shift as the day lanes. Width stays on the frozen layout
            // scale during the gesture so this row cannot drift from the columns.
            TimelineWeekDayHeaderLabels(days: window.days, dayWidth: dayWidth, now: now)
                .scaleEffect(x: pinchRatio, y: 1, anchor: .leading)
                .offset(x: pinchTranslation.width)
        }
    }

    // MARK: - Grid

    /// Week grid. One pinch scale drives hour height and day width (both clamped).
    /// During the pinch, event frames stay at `zoomScale` and a continuous `previewScale`
    /// is a visual scale. A matching translation keeps the finger midpoint fixed on both
    /// axes without resizing the scroll content each sample (that resize snapped back to
    /// the top-left). Weekday headers get the same horizontal scale and shift as the day
    /// lanes. Rebuilding the week path on each 0.05 quantum made blocks jump.
    /// Weekday labels stick vertically and hour labels stick horizontally.
    private func weekGrid(_ window: WeekWindow) -> some View {
        let activeTimer = model.babyState?.activeTimer.flatMap { $0.isActive ? $0 : nil }
        return GeometryReader { viewport in
            let trailing = CGFloat(4)
            let dayLaneWidth = max(viewport.size.width - gutterWidth - trailing, 1)
            let layoutDaysWidth = dayLaneWidth * zoomScale
            let dayCount = CGFloat(max(window.days.count, 1))
            let layoutDayWidth = layoutDaysWidth / dayCount
            let layoutGridHeight = hourHeight * 24
            let ratio = pinchRatio
            // Layout size stays at the committed scale for the whole gesture. Preview is a
            // visual scale plus `pinchTranslation`, so SwiftUI does not resize (and re-anchor
            // to the top-left) on every sample. Header labels use this same layout width.
            let contentWidth = max(gutterWidth + layoutDaysWidth + trailing, viewport.size.width)

            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(spacing: 0) {
                            dayHeaderRow(window, dayWidth: layoutDayWidth)
                                .padding(.trailing, trailing)
                                .padding(.vertical, 6)
                            Rectangle()
                                .fill(DesignTokens.bgCardElevated)
                                .frame(height: 1)
                        }
                        .frame(width: contentWidth, alignment: .leading)
                        .background(DesignTokens.bgCanvas)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: TimelineWeekHeaderHeightKey.self,
                                    value: proxy.size.height
                                )
                            }
                        }
                        .modifier(TimelineWeekPinnedAxes(axes: .vertical))
                        .zIndex(2)

                        HStack(alignment: .top, spacing: 0) {
                            TimelineWeekHourColumn(labels: (0..<24).map { hourLabel($0) }, hourHeight: hourHeight)
                                .frame(width: gutterWidth, height: layoutGridHeight, alignment: .top)
                                .scaleEffect(x: 1, y: ratio, anchor: .top)
                                .offset(y: pinchTranslation.height)
                                .background(DesignTokens.bgCanvas)
                                .modifier(TimelineWeekPinnedAxes(axes: .horizontal))
                                .zIndex(1)
                            TimelineWeekDayCanvas(
                                window: window,
                                now: now,
                                events: events,
                                timer: activeTimer,
                                dayWidth: layoutDayWidth,
                                hourHeight: hourHeight,
                                daysWidth: layoutDaysWidth,
                                onSelect: { selection = $0 }
                            )
                            // Scale from the day-lane origin. `pinchTranslation` is the scroll
                            // the commit will apply, so the point under the fingers stays put
                            // without resizing the scroll content on each sample.
                            .scaleEffect(x: ratio, y: ratio, anchor: .topLeading)
                            .offset(pinchTranslation)
                        }
                        .padding(.vertical, gridInset)
                        .padding(.trailing, trailing)
                        .frame(width: contentWidth, alignment: .topLeading)
                    }
                    .frame(width: contentWidth, alignment: .topLeading)
                    .animation(nil, value: previewScale)
                    .animation(nil, value: zoomScale)
                    .animation(nil, value: pinchTranslation)
                    .background(alignment: .topLeading) {
                        TimelineWeekPinchCatcher(
                            bridge: zoomBridge,
                            zoomScale: zoomScale,
                            previewScale: previewScale,
                            pinchBaseScale: pinchBaseScale,
                            baseHourHeight: baseHourHeight,
                            gutterWidth: gutterWidth,
                            onZoom: { live, translation in
                                var transaction = Transaction()
                                transaction.animation = nil
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    previewScale = live
                                    pinchTranslation = translation
                                }
                            },
                            onEnded: { live in
                                var transaction = Transaction()
                                transaction.animation = nil
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    // One layout commit at the scale the fingers released on.
                                    // The closure is given `live` so the final sample is not dropped.
                                    previewScale = live
                                    zoomScale = live
                                    pinchBaseScale = live
                                    pinchTranslation = .zero
                                }
                            }
                        )
                        .frame(width: 0, height: 0)
                    }
                }
                .scrollIndicators(.hidden)
                // Two-finger pinch is a UIPinchGestureRecognizer on the scroll view (see catcher)
                // so the live centroid is available. One-finger scroll and taps stay on this view.
                .simultaneousGesture(doubleTapResetZoom)
                .onPreferenceChange(TimelineWeekHeaderHeightKey.self) { height in
                    zoomBridge.headerHeight = height
                }
                .onAppear {
                    let hour = calendar.component(.hour, from: now)
                    proxy.scrollTo(max(0, hour - 2), anchor: .top)
                }
            }
        }
    }

    /// Double-tap resets zoom; simultaneous + count 2 so single-tap event buttons stay snappy.
    private var doubleTapResetZoom: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                guard zoomScale != 1 || previewScale != 1 else { return }
                // No scale animation: the scroll offset has to land on the same frame as the scale
                // or the point under the viewport center drifts while the grid eases.
                let offset = zoomBridge.offsetKeepingCenter(at: 1)
                zoomBridge.armOffset(offset, scale: 1)
                var transaction = Transaction()
                transaction.animation = nil
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    resetZoom()
                    pinchTranslation = .zero
                }
            }
    }

    fileprivate static func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, minZoom), maxZoom)
    }

    private func resetZoom() {
        zoomScale = 1
        previewScale = 1
        pinchBaseScale = 1
    }

    private func hourLabel(_ hour: Int) -> String {
        // Fixed January date: no DST gap, so every hour exists.
        var components = DateComponents()
        components.year = 2001
        components.month = 1
        components.day = 1
        components.hour = hour
        guard let date = calendar.date(from: components) else { return "\(hour)" }
        return date.formatted(.dateTime.hour())
    }

}

// MARK: - Window + pure layout

extension TimelineWeekView {
    struct WeekWindow: Hashable {
        /// Seven local day starts, oldest first; the last one is the anchor day.
        let days: [Date]
        let from: Date
        let to: Date

        static func ending(weeksFromToday offset: Int, now: Date, calendar: Calendar) -> WeekWindow {
            let today = calendar.startOfDay(for: now)
            let anchorRaw = calendar.date(byAdding: .day, value: 7 * offset, to: today) ?? today
            let anchor = calendar.startOfDay(for: anchorRaw)
            let days = (0..<7).map { index -> Date in
                let raw = calendar.date(byAdding: .day, value: index - 6, to: anchor) ?? anchor
                return calendar.startOfDay(for: raw)
            }
            let end = calendar.date(byAdding: .day, value: 1, to: anchor).map { calendar.startOfDay(for: $0) }
                ?? anchor.addingTimeInterval(86_400)
            return WeekWindow(days: days, from: days[0], to: end)
        }
    }

    /// One block in the grid: a single-day segment of an event or running timer, already packed.
    struct WeekBlock: Identifiable {
        let id: String
        let item: CalendarItem
        let dayIndex: Int
        /// Minutes since local midnight (wall clock), after the minimum visual height is applied.
        let startMinute: Double
        let endMinute: Double
        let column: Int
        let columnCount: Int
    }

    struct LayoutInterval: Equatable {
        let id: String
        let start: Double
        let end: Double
    }

    struct LayoutSlot: Equatable {
        let column: Int
        let columnCount: Int
    }

    static let minutesPerDay: Double = 24 * 60
    /// Instants (and very short sessions) still get a tappable block.
    static let minimumBlockMinutes: Double = 15

    /// Interval-graph column packing for one day. Transitively overlapping intervals form a cluster;
    /// each interval takes the first column whose previous occupant has ended, and every member of a
    /// cluster shares the cluster's column count (block width = dayWidth / columnCount).
    /// Touching intervals (`a.end == b.start`) do not overlap.
    static func layout(_ intervals: [LayoutInterval]) -> [String: LayoutSlot] {
        let sorted = intervals.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end > b.end }
            return a.id < b.id
        }
        var result: [String: LayoutSlot] = [:]
        var cluster: [(id: String, column: Int)] = []
        var columnEnds: [Double] = []
        var clusterEnd = -Double.infinity

        func flushCluster() {
            for member in cluster {
                result[member.id] = LayoutSlot(column: member.column, columnCount: columnEnds.count)
            }
            cluster.removeAll()
            columnEnds.removeAll()
            clusterEnd = -Double.infinity
        }

        for interval in sorted {
            if !cluster.isEmpty, interval.start >= clusterEnd {
                flushCluster()
            }
            let end = max(interval.end, interval.start)
            if let free = columnEnds.firstIndex(where: { $0 <= interval.start }) {
                columnEnds[free] = end
                cluster.append((interval.id, free))
            } else {
                columnEnds.append(end)
                cluster.append((interval.id, columnEnds.count - 1))
            }
            clusterEnd = max(clusterEnd, end)
        }
        flushCluster()
        return result
    }

    /// Wall-clock minutes since local midnight, so DST days still line up with the hour rows.
    static func minuteOfDay(_ date: Date, calendar: Calendar) -> Double {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) + Double(c.second ?? 0) / 60
    }

    /// Portion of `start ..< end` inside `[dayStart, dayEnd)` in minutes; instants match when
    /// `dayStart <= start < dayEnd` (same predicate as the store range query).
    static func daySpan(
        start: Date,
        end: Date,
        dayStart: Date,
        dayEnd: Date,
        calendar: Calendar
    ) -> (start: Double, end: Double)? {
        guard start < dayEnd, end > dayStart || start >= dayStart else { return nil }
        let s = start <= dayStart ? 0 : minuteOfDay(start, calendar: calendar)
        let e = end >= dayEnd ? minutesPerDay : minuteOfDay(end, calendar: calendar)
        return (s, max(s, e))
    }

    /// Stretch spans shorter than `minimumBlockMinutes`, keeping them inside the day.
    static func visualSpan(start: Double, end: Double) -> (start: Double, end: Double) {
        guard end - start < minimumBlockMinutes else { return (start, end) }
        let stretchedEnd = min(minutesPerDay, start + minimumBlockMinutes)
        return (stretchedEnd - minimumBlockMinutes, stretchedEnd)
    }

    /// Split events (and the active timer, open-ended at `now`) into per-day segments and pack each day.
    static func blocks(
        events: [EventDTO],
        timer: TimerDTO?,
        window: WeekWindow,
        now: Date,
        calendar: Calendar
    ) -> [WeekBlock] {
        var items = events
            .filter { $0.deletedAt == nil }
            .map { CalendarItem(source: .event($0)) }
        if let timer {
            items.append(CalendarItem(source: .timer(timer)))
        }

        var blocks: [WeekBlock] = []
        for (dayIndex, dayStart) in window.days.enumerated() {
            let dayEnd = dayIndex + 1 < window.days.count ? window.days[dayIndex + 1] : window.to
            var spans: [(item: CalendarItem, start: Double, end: Double)] = []
            for item in items {
                let start = item.startedAt
                let end = max(item.endedAt(now: now) ?? start, start)
                guard let span = daySpan(start: start, end: end, dayStart: dayStart, dayEnd: dayEnd, calendar: calendar)
                else { continue }
                let visual = visualSpan(start: span.start, end: span.end)
                spans.append((item, visual.start, visual.end))
            }
            let slots = layout(spans.map { LayoutInterval(id: $0.item.id.uuidString, start: $0.start, end: $0.end) })
            for span in spans.sorted(by: { $0.start < $1.start }) {
                let slot = slots[span.item.id.uuidString] ?? LayoutSlot(column: 0, columnCount: 1)
                blocks.append(
                    WeekBlock(
                        id: "\(span.item.id.uuidString)-\(dayIndex)",
                        item: span.item,
                        dayIndex: dayIndex,
                        startMinute: span.start,
                        endMinute: span.end,
                        column: slot.column,
                        columnCount: slot.columnCount
                    )
                )
            }
        }
        return blocks
    }
}

// MARK: - Calendar item (event or active timer)

struct CalendarItem: Identifiable, Hashable {
    enum Source: Hashable {
        case event(EventDTO)
        case timer(TimerDTO)
    }

    let source: Source

    var id: UUID {
        switch source {
        case .event(let e): return e.id
        case .timer(let t): return t.id
        }
    }

    /// Open block for the active (running or paused) timer.
    var isRunning: Bool {
        if case .timer = source { return true }
        return false
    }

    var isPaused: Bool {
        if case .timer(let t) = source { return t.isPaused }
        return false
    }

    var startedAt: Date {
        switch source {
        case .event(let e): return e.startedAt
        case .timer(let t): return t.startedAt
        }
    }

    /// `nil` for instants; `now` for the active timer (the block spans start → now, pauses included).
    func endedAt(now: Date) -> Date? {
        switch source {
        case .event(let e): return e.endedAt
        case .timer(let t): return max(now, t.startedAt)
        }
    }

    private var typeKey: String {
        switch source {
        case .event(let e): return e.type
        case .timer(let t):
            if RunningTimerLabel.isSleep(kind: t.kind) { return EventType.sleep.rawValue }
            if ActivityKind(timerKind: t.kind) != nil { return EventType.activity.rawValue }
            return EventType.feedBreast.rawValue
        }
    }

    /// Walk / car ride / crying for `activity` events and their timers.
    private var activity: ActivityKind? {
        switch source {
        case .event(let e): return ActivityKind(event: e)
        case .timer(let t): return ActivityKind(timerKind: t.kind)
        }
    }

    private var side: String? {
        switch source {
        case .event(let e): return e.side
        case .timer(let t): return t.side
        }
    }

    var color: Color {
        let type = typeKey
        if type.hasPrefix("feed_") { return DesignTokens.feed }
        if type == EventType.diaper.rawValue { return DesignTokens.diaper }
        if type == EventType.sleep.rawValue { return DesignTokens.sleep }
        if type == EventType.medicine.rawValue { return DesignTokens.medicine }
        if type == EventType.pump.rawValue { return DesignTokens.bottle }
        if type == EventType.activity.rawValue { return DesignTokens.accent(for: activity ?? .walk) }
        return DesignTokens.textSecondary
    }

    var systemImage: String {
        if case .timer(let t) = source {
            return t.isPaused ? "pause.fill" : RunningTimerLabel.systemImage(kind: t.kind)
        }
        switch typeKey {
        case EventType.feedBreast.rawValue: return "drop.fill"
        case EventType.feedBottle.rawValue: return "cup.and.saucer.fill"
        case EventType.feedSolid.rawValue: return "fork.knife"
        case EventType.diaper.rawValue: return "circle.grid.cross.fill"
        case EventType.sleep.rawValue: return "moon.fill"
        case EventType.pump.rawValue: return "drop.halffull"
        case EventType.medicine.rawValue: return "pills.fill"
        case EventType.temperature.rawValue: return "thermometer.medium"
        case EventType.growth.rawValue: return "ruler"
        case EventType.milestone.rawValue: return "star.fill"
        case EventType.note.rawValue: return "note.text"
        case EventType.activity.rawValue: return activity?.systemImage ?? "figure.walk"
        default: return "circle.fill"
        }
    }

    /// Compact block title, e.g. "Sleep", "Wet", "Nursing: Left", "Bottle".
    var shortTitle: String {
        if case .timer(let t) = source { return RunningTimerLabel.title(kind: t.kind, side: t.side) }
        guard case .event(let e) = source else { return "" }
        switch e.type {
        case EventType.feedBreast.rawValue:
            return NursingLabels.title(side: e.side)
        case EventType.feedBottle.rawValue: return "Bottle"
        case EventType.feedSolid.rawValue: return "Solids"
        case EventType.diaper.rawValue: return e.subtype.map { $0.capitalized } ?? "Diaper"
        case EventType.sleep.rawValue: return "Sleep"
        case EventType.medicine.rawValue: return e.subtype ?? "Medicine"
        case EventType.pump.rawValue:
            return "Pump" + (e.side.map { " \($0.uppercased())" } ?? "")
        case EventType.activity.rawValue: return activity?.title ?? "Outing"
        default: return Self.humanize(e.type)
        }
    }

    /// Type name for the detail sheet.
    var typeName: String {
        if case .timer(let t) = source {
            if RunningTimerLabel.isSleep(kind: t.kind) { return "Sleep" }
            return activity?.title ?? "Nursing"
        }
        switch typeKey {
        case EventType.feedBreast.rawValue: return "Nursing"
        case EventType.feedBottle.rawValue: return "Bottle"
        case EventType.feedSolid.rawValue: return "Solids"
        case EventType.medicine.rawValue: return "Medicine"
        case EventType.pump.rawValue: return "Pump"
        case EventType.activity.rawValue: return activity?.title ?? "Outing"
        default: return Self.humanize(typeKey)
        }
    }

    /// Spoken title, e.g. "Nursing left", "Diaper, wet", "Sleep".
    var spokenTitle: String {
        if case .timer(let t) = source { return RunningTimerLabel.spokenTitle(kind: t.kind, side: t.side) }
        guard case .event(let e) = source else { return "" }
        switch e.type {
        case EventType.feedBreast.rawValue:
            return RunningTimerLabel.spokenTitle(kind: e.type, side: e.side)
        case EventType.diaper.rawValue:
            return e.subtype.map { "Diaper, \($0)" } ?? "Diaper"
        default:
            return typeName
        }
    }

    var sideName: String? {
        switch side?.uppercased() {
        case "L": return "Left"
        case "R": return "Right"
        case nil: return nil
        case let other?: return other
        }
    }

    var amountText: String? {
        guard case .event(let e) = source, let amount = e.amountValue else { return nil }
        return "\(Self.formatAmount(amount)) \(e.amountUnit ?? "oz")"
    }

    var subtypeName: String? {
        guard case .event(let e) = source, let subtype = e.subtype, !subtype.isEmpty else { return nil }
        return Self.humanize(subtype)
    }

    var notes: String? {
        guard case .event(let e) = source, let notes = e.notes, !notes.isEmpty else { return nil }
        return notes
    }

    /// Active time, excluding pauses; the block geometry still spans start → end.
    func duration(now: Date) -> TimeInterval? {
        switch source {
        case .event(let e): return e.activeDuration
        case .timer(let t): return t.elapsed(at: now)
        }
    }

    /// Total time spent paused (completed pauses plus the one in progress).
    func pausedTime(now: Date) -> TimeInterval {
        switch source {
        case .event(let e):
            return TimeInterval(e.pausedSeconds)
        case .timer(let t):
            let open = t.pausedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
            return TimeInterval(t.pausedSeconds) + open
        }
    }

    /// Second line in a block, e.g. "1h 20m", "3oz".
    func compactDetail(now: Date) -> String? {
        if case .event(let e) = source, let amount = e.amountValue {
            return "\(Self.formatAmount(amount))\(e.amountUnit ?? "oz")"
        }
        return duration(now: now).map { PrototypeFormatters.compactDuration($0) }
    }

    func accessibilityLabel(now: Date) -> String {
        let day = startedAt.formatted(.dateTime.weekday(.wide))
        let start = PrototypeFormatters.shortTime(startedAt)
        if isRunning {
            let elapsed = RunningTimerLabel.spokenDuration(duration(now: now) ?? 0)
            let state = isPaused ? "paused" : "running"
            return "\(spokenTitle) timer \(state), started \(day) \(start), \(elapsed)"
        }
        var parts = [spokenTitle, day]
        if let end = endedAt(now: now), let duration = duration(now: now) {
            parts.append("\(start) to \(PrototypeFormatters.shortTime(end))")
            parts.append(RunningTimerLabel.spokenDuration(duration))
        } else {
            parts.append(start)
        }
        if let amountText { parts.append(amountText) }
        return parts.joined(separator: ", ")
    }

    static func formatAmount(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    private static func humanize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - Block view

private struct WeekBlockView: View {
    let item: CalendarItem
    let now: Date
    let width: CGFloat
    let height: CGFloat

    private var showTitle: Bool { width >= 30 && height >= 24 }
    private var showIcon: Bool { width >= 12 && height >= 12 }

    var body: some View {
        let color = item.color
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(color.opacity(item.isRunning ? (item.isPaused ? 0.07 : 0.14) : 0.32))
            if item.isPaused {
                PauseStripes()
                    .stroke(color.opacity(0.22), lineWidth: 1)
            }
            if item.isRunning {
                shape.strokeBorder(
                    color.opacity(item.isPaused ? 0.55 : 1),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                )
            } else {
                Rectangle()
                    .fill(color)
                    .frame(width: 2.5)
            }
            label(color: color)
        }
        .clipShape(shape)
    }

    @ViewBuilder
    private func label(color: Color) -> some View {
        if showTitle {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 2) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(color)
                    Text(item.shortTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DesignTokens.textPrimary)
                }
                if height >= 38, let detail = item.compactDetail(now: now) {
                    Text(detail)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .dynamicTypeSize(...DynamicTypeSize.large)
            .padding(.leading, 4)
            .padding(.trailing, 1)
            .padding(.top, 2)
        } else if showIcon {
            Image(systemName: item.systemImage)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Diagonal hatch drawn over a paused timer block.
private struct PauseStripes: Shape {
    var spacing: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}


// MARK: - Pinch-stable grid pieces
//
// These stay equal for the whole gesture (`zoomScale` is frozen), so SwiftUI does not
// rebuild event frames, the week path, or hour labels on each touch sample. The parent
// applies `pinchRatio` as a visual scale instead.

private struct TimelineWeekHourColumn: View, Equatable {
    var labels: [String]
    var hourHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { hour, label in
                Text(label)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.trailing, 6)
                    .offset(y: -7)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .frame(height: hourHeight, alignment: .top)
                    .id(hour)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct TimelineWeekDayHeaderLabels: View, Equatable {
    var days: [Date]
    var dayWidth: CGFloat
    var now: Date

    private var calendar: Calendar { .current }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let isToday = calendar.isDate(day, inSameDayAs: now)
                VStack(spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isToday ? DesignTokens.textPrimary : DesignTokens.textTertiary)
                    Text(day.formatted(.dateTime.day()))
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(isToday ? DesignTokens.bgCanvas : DesignTokens.textSecondary)
                        .frame(minWidth: 26, minHeight: 26)
                        .background {
                            if isToday {
                                Circle().fill(DesignTokens.textPrimary)
                            }
                        }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: dayWidth)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    day.formatted(.dateTime.weekday(.wide).month(.wide).day()) + (isToday ? ", today" : "")
                )
            }
        }
        .frame(width: dayWidth * CGFloat(max(days.count, 1)), alignment: .leading)
    }
}

/// Event geometry at the committed layout scale. `Equatable` so a live pinch (which does not
/// change these inputs) does not rebuild the path or block frames.
private struct TimelineWeekDayCanvas: View, Equatable {
    var window: TimelineWeekView.WeekWindow
    var now: Date
    var events: [EventDTO]
    var timer: TimerDTO?
    var dayWidth: CGFloat
    var hourHeight: CGFloat
    var daysWidth: CGFloat
    var onSelect: (CalendarItem) -> Void

    static func == (lhs: TimelineWeekDayCanvas, rhs: TimelineWeekDayCanvas) -> Bool {
        lhs.window == rhs.window
            && lhs.now == rhs.now
            && lhs.events == rhs.events
            && lhs.timer == rhs.timer
            && lhs.dayWidth == rhs.dayWidth
            && lhs.hourHeight == rhs.hourHeight
            && lhs.daysWidth == rhs.daysWidth
    }

    private var calendar: Calendar { .current }

    var body: some View {
        let blocks = TimelineWeekView.blocks(
            events: events,
            timer: timer,
            window: window,
            now: now,
            calendar: calendar
        )
        let minuteHeight = hourHeight / 60
        let height = hourHeight * 24
        let todayIndex = window.days.firstIndex { calendar.isDate($0, inSameDayAs: now) }
        let size = CGSize(width: daysWidth, height: height)

        ZStack(alignment: .topLeading) {
            if let todayIndex {
                Rectangle()
                    .fill(DesignTokens.bgCard.opacity(0.6))
                    .frame(width: dayWidth, height: height)
                    .offset(x: CGFloat(todayIndex) * dayWidth)
            }

            gridLines(size: size, dayWidth: dayWidth, days: window.days.count)

            ForEach(blocks) { block in
                blockButton(block, dayWidth: dayWidth, minuteHeight: minuteHeight)
            }

            if let todayIndex {
                nowLine(dayWidth: dayWidth)
                    .offset(
                        x: CGFloat(todayIndex) * dayWidth,
                        y: CGFloat(TimelineWeekView.minuteOfDay(now, calendar: calendar)) * minuteHeight - 3.5
                    )
            }
        }
        .frame(width: daysWidth, height: height, alignment: .topLeading)
    }

    private func gridLines(size: CGSize, dayWidth: CGFloat, days: Int) -> some View {
        Path { path in
            for hour in 0...24 {
                let y = CGFloat(hour) * hourHeight
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            for day in 0...days {
                let x = CGFloat(day) * dayWidth
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
        }
        .stroke(DesignTokens.bgCardElevated, lineWidth: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func nowLine(dayWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(DesignTokens.active)
                .frame(width: dayWidth, height: 1.5)
            Circle()
                .fill(DesignTokens.active)
                .frame(width: 7, height: 7)
                .offset(x: -3.5)
        }
        .frame(width: dayWidth, height: 7, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func blockButton(_ block: TimelineWeekView.WeekBlock, dayWidth: CGFloat, minuteHeight: CGFloat) -> some View {
        let columnWidth = dayWidth / CGFloat(max(block.columnCount, 1))
        let x = CGFloat(block.dayIndex) * dayWidth + CGFloat(block.column) * columnWidth
        let y = CGFloat(block.startMinute) * minuteHeight
        let height = max(CGFloat(block.endMinute - block.startMinute) * minuteHeight, 2)
        let width = max(columnWidth - 2, 2)
        let drawnHeight = max(height - 1, 2)
        return Button {
            onSelect(block.item)
        } label: {
            WeekBlockView(item: block.item, now: now, width: width, height: drawnHeight)
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
        .frame(width: width, height: drawnHeight)
        .contentShape(Rectangle())
        .position(x: x + 1 + width / 2, y: y + drawnHeight / 2)
        .accessibilityLabel(block.item.accessibilityLabel(now: now))
        .accessibilityHint("Shows details")
    }
}

// MARK: - Pinch anchor

/// Height of the sticky day header (does not scale). The hour grid below it does.
private struct TimelineWeekHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// Pure pinch-anchor math. Scale grows away from `scaleOrigin` (right of the hour gutter,
/// below the day header). The content point that was under `oldCentroid` is mapped through
/// that scale and placed back under `newCentroid` by shifting both scroll offsets.
private enum TimelineWeekZoomMath {
    static func anchoredContentOffset(
        oldOffset: CGPoint,
        oldCentroid: CGPoint,
        newCentroid: CGPoint,
        scaleOrigin: CGPoint,
        oldScale: CGFloat,
        newScale: CGFloat
    ) -> CGPoint {
        let factor = oldScale > 0 ? newScale / oldScale : 1
        let oldContent = CGPoint(x: oldOffset.x + oldCentroid.x, y: oldOffset.y + oldCentroid.y)
        let newContent = CGPoint(
            x: scaledAxis(oldContent.x, origin: scaleOrigin.x, factor: factor),
            y: scaledAxis(oldContent.y, origin: scaleOrigin.y, factor: factor)
        )
        return CGPoint(x: newContent.x - newCentroid.x, y: newContent.y - newCentroid.y)
    }

    /// Points in the non-scaling chrome (gutter / header) stay put; the grid scales away from `origin`.
    static func scaledAxis(_ content: CGFloat, origin: CGFloat, factor: CGFloat) -> CGFloat {
        guard content >= origin else { return content }
        return origin + (content - origin) * factor
    }

    static func clampedOffset(
        _ offset: CGPoint,
        contentSize: CGSize,
        viewport: CGSize,
        inset: UIEdgeInsets
    ) -> CGPoint {
        let minX = -inset.left
        let minY = -inset.top
        let maxX = max(minX, contentSize.width - viewport.width + inset.right)
        let maxY = max(minY, contentSize.height - viewport.height + inset.bottom)
        return CGPoint(
            x: min(max(offset.x, minX), maxX),
            y: min(max(offset.y, minY), maxY)
        )
    }
}

/// Owns the pinch recognizer's scroll-offset chain. A class (not `@State` offset) so finger
/// tracking does not invalidate the week grid every sample — live scale is a visual transform.
/// SwiftUI resets `contentOffset` to the top-left when content size changes; observers write the
/// centroid anchor back before the frame is shown.
private final class TimelineWeekZoomBridge {
    weak var scrollView: UIScrollView?
    var zoomScale: CGFloat = 1
    var previewScale: CGFloat = 1
    var pinchBaseScale: CGFloat = 1
    var baseHourHeight: CGFloat = 44
    var gutterWidth: CGFloat = 44
    var headerHeight: CGFloat = 0
    var onZoom: ((CGFloat, CGSize) -> Void)?
    var onEnded: ((CGFloat) -> Void)?

    private let gridInset: CGFloat = 10
    private let trailing: CGFloat = 4
    private var gestureBaseScale: CGFloat = 1
    /// Scale and offset at the finger-down sample. Later samples anchor against these,
    /// not against a clamped intermediate, so the centroid does not drift.
    private var startScale: CGFloat = 1
    private var startOffset: CGPoint = .zero
    private var startCentroid: CGPoint?
    private var latestCentroid: CGPoint?
    /// Visual scale the offset math is targeting. The gesture owns this while a pinch or
    /// a post-layout enforce is in flight.
    private var visualScale: CGFloat = 1
    /// Double-tap has no finger centroid; the armed point is the whole target.
    private var armedOffset: CGPoint?
    private var isPinching = false
    private var needsOffsetSync = false
    private var correctingOffset = false
    private var enforceGeneration = 0
    private var enforceFramesRemaining = 0
    private var contentOffsetObservation: NSKeyValueObservation?
    private var contentSizeObservation: NSKeyValueObservation?

    var scaleOrigin: CGPoint {
        CGPoint(x: gutterWidth, y: headerHeight + gridInset)
    }

    func attach(scrollView: UIScrollView) {
        self.scrollView = scrollView
        guard contentOffsetObservation == nil else { return }
        contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.correctOffsetIfNeeded()
        }
        contentSizeObservation = scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            self?.correctOffsetIfNeeded()
        }
    }

    func detachScrollView() {
        contentOffsetObservation?.invalidate()
        contentSizeObservation?.invalidate()
        contentOffsetObservation = nil
        contentSizeObservation = nil
        scrollView = nil
    }

    func noteRendered(
        preview: CGFloat,
        layout: CGFloat,
        pinchBase: CGFloat,
        baseHourHeight: CGFloat,
        gutterWidth: CGFloat
    ) {
        self.baseHourHeight = baseHourHeight
        self.gutterWidth = gutterWidth
        zoomScale = layout
        pinchBaseScale = pinchBase
        previewScale = preview
        // A stale SwiftUI update must not rewind the scale the fingers just produced,
        // including the commit frame where `isPinching` is already false.
        if !isPinching && !needsOffsetSync {
            visualScale = preview
        }
    }

    func beginPinch(at centroid: CGPoint) {
        gestureBaseScale = pinchBaseScale
        startScale = visualScale
        visualScale = startScale
        isPinching = true
        needsOffsetSync = true
        armedOffset = nil
        startCentroid = centroid
        latestCentroid = centroid
        // Cancel a leftover enforce from the previous gesture so it cannot
        // write the previous anchor over this one.
        enforceGeneration += 1
        enforceFramesRemaining = 0
        guard let scrollView else { return }
        // Two fingers belong to the pinch. A one-finger pan still scrolls.
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        // Kill deceleration so the sampled offset is the one on screen.
        let offset = scrollView.contentOffset
        correctingOffset = true
        scrollView.setContentOffset(offset, animated: false)
        correctingOffset = false
        startOffset = offset
    }

    func pinchChanged(recognizerScale: CGFloat, centroid: CGPoint) {
        let live = TimelineWeekView.clampedZoom(gestureBaseScale * recognizerScale)
        guard let scrollView else {
            visualScale = live
            latestCentroid = centroid
            onZoom?(live, .zero)
            return
        }
        if startCentroid == nil {
            startCentroid = centroid
            startOffset = scrollView.contentOffset
            startScale = visualScale
        }
        latestCentroid = centroid
        visualScale = live
        armedOffset = nil
        // Layout size stays frozen. The view applies this translation on top of the
        // visual scale; writing contentOffset here fights SwiftUI and snaps to the top-left.
        needsOffsetSync = false
        onZoom?(live, currentTranslation())
    }

    func endPinch() {
        isPinching = false
        needsOffsetSync = true
        let live = visualScale
        onEnded?(live)
        scheduleEnforce()
    }

    /// Double-tap reset. Keeps the content under the viewport center stable — there is no finger centroid.
    func offsetKeepingCenter(at newScale: CGFloat) -> CGPoint {
        guard let scrollView else { return .zero }
        let centroid = CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY)
        let target = TimelineWeekZoomMath.anchoredContentOffset(
            oldOffset: scrollView.contentOffset,
            oldCentroid: centroid,
            newCentroid: centroid,
            scaleOrigin: scaleOrigin,
            oldScale: visualScale,
            newScale: newScale
        )
        let viewport = scrollView.bounds.size
        let predicted = predictedContentSize(scale: newScale, viewport: viewport)
        return TimelineWeekZoomMath.clampedOffset(
            target,
            contentSize: predicted,
            viewport: viewport,
            inset: scrollView.adjustedContentInset
        )
    }

    /// Arm the offset before the SwiftUI scale commit so the following layout writes it.
    func armOffset(_ offset: CGPoint, scale: CGFloat) {
        visualScale = scale
        armedOffset = offset
        startCentroid = nil
        latestCentroid = nil
        needsOffsetSync = true
        scheduleEnforce()
    }

    /// Write the anchored offset once the scroll view's content size matches `visualScale`.
    func applyLiveOffset() {
        correctOffsetIfNeeded()
    }

    private func scheduleEnforce() {
        enforceGeneration += 1
        enforceFramesRemaining = 8
        pump(token: enforceGeneration)
    }

    private func pump(token: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.enforceGeneration == token else { return }
            self.correctOffsetIfNeeded()
            self.enforceFramesRemaining -= 1
            if self.enforceFramesRemaining > 0 {
                self.pump(token: token)
            } else if !self.isPinching {
                self.needsOffsetSync = false
            }
        }
    }

    /// Recomputed from the finger-down sample every time, so a late layout cannot apply
    /// an offset that belonged to a previous scale step.
    private func idealOffset() -> CGPoint? {
        if startCentroid == nil, let armedOffset { return armedOffset }
        return unclampedTarget()
    }

    private func unclampedTarget() -> CGPoint? {
        guard let originCentroid = startCentroid, let centroid = latestCentroid else { return nil }
        return TimelineWeekZoomMath.anchoredContentOffset(
            oldOffset: startOffset,
            oldCentroid: originCentroid,
            newCentroid: centroid,
            scaleOrigin: scaleOrigin,
            oldScale: startScale,
            newScale: visualScale
        )
    }

    /// On-screen shift that previews `idealOffset` while content offset is still `startOffset`.
    private func currentTranslation() -> CGSize {
        guard isPinching, let target = unclampedTarget() else { return .zero }
        return CGSize(width: startOffset.x - target.x, height: startOffset.y - target.y)
    }

    private func correctOffsetIfNeeded() {
        guard !correctingOffset else { return }
        // Live samples are anchored visually. Offset is written once, after commit,
        // when the scroll content has actually resized.
        guard !isPinching, needsOffsetSync else { return }
        guard let scrollView, let target = idealOffset() else { return }
        let viewport = scrollView.bounds.size
        guard viewport.width > 1, viewport.height > 1 else { return }
        guard headerHeight > 0, baseHourHeight > 0 else { return }
        let gridHeight = scrollView.contentSize.height - headerHeight - gridInset * 2
        let measuredScale = gridHeight / (baseHourHeight * 24)
        // Wait until the committed layout is actually the scale we anchored against.
        guard abs(measuredScale - visualScale) < 0.012 else { return }
        let writable = TimelineWeekZoomMath.clampedOffset(
            target,
            contentSize: scrollView.contentSize,
            viewport: viewport,
            inset: scrollView.adjustedContentInset
        )
        let deltaX = abs(scrollView.contentOffset.x - writable.x)
        let deltaY = abs(scrollView.contentOffset.y - writable.y)
        guard deltaX > 0.5 || deltaY > 0.5 else { return }
        correctingOffset = true
        UIView.performWithoutAnimation {
            scrollView.setContentOffset(writable, animated: false)
        }
        correctingOffset = false
    }

    private func predictedContentSize(scale: CGFloat, viewport: CGSize) -> CGSize {
        let dayLane = max(viewport.width - gutterWidth - trailing, 1)
        let daysWidth = dayLane * scale
        let width = max(gutterWidth + daysWidth + trailing, viewport.width)
        let height = headerHeight + gridInset * 2 + baseHourHeight * scale * 24
        return CGSize(width: width, height: height)
    }
}

/// Installs a pinch recognizer on the week scroll view. Zero-sized so it does not change the grid.
private struct TimelineWeekPinchCatcher: UIViewRepresentable {
    var bridge: TimelineWeekZoomBridge
    var zoomScale: CGFloat
    var previewScale: CGFloat
    var pinchBaseScale: CGFloat
    var baseHourHeight: CGFloat
    var gutterWidth: CGFloat
    var onZoom: (CGFloat, CGSize) -> Void
    var onEnded: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    func makeUIView(context: Context) -> TimelineWeekPinchSurface {
        let view = TimelineWeekPinchSurface()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.attachIfNeeded()
            coordinator?.bridge.applyLiveOffset()
        }
        return view
    }

    func updateUIView(_ uiView: TimelineWeekPinchSurface, context: Context) {
        let bridge = context.coordinator.bridge
        bridge.noteRendered(
            preview: previewScale,
            layout: zoomScale,
            pinchBase: pinchBaseScale,
            baseHourHeight: baseHourHeight,
            gutterWidth: gutterWidth
        )
        bridge.onZoom = onZoom
        bridge.onEnded = onEnded
        context.coordinator.hostView = uiView
        context.coordinator.attachIfNeeded()
    }

    static func dismantleUIView(_ uiView: TimelineWeekPinchSurface, coordinator: Coordinator) {
        coordinator.detach()
        uiView.onLayout = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let bridge: TimelineWeekZoomBridge
        weak var hostView: UIView?
        private let proxy = PinchProxy()
        private var recognizer: UIPinchGestureRecognizer?

        init(bridge: TimelineWeekZoomBridge) {
            self.bridge = bridge
            super.init()
            proxy.coordinator = self
        }

        func attachIfNeeded() {
            guard recognizer == nil, let hostView else { return }
            guard let scrollView = Self.scrollView(from: hostView) else { return }
            let pinch = UIPinchGestureRecognizer(target: proxy, action: #selector(PinchProxy.pinched(_:)))
            pinch.delegate = self
            pinch.cancelsTouchesInView = false
            scrollView.addGestureRecognizer(pinch)
            scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
            recognizer = pinch
            bridge.attach(scrollView: scrollView)
        }

        func detach() {
            if let recognizer, let view = recognizer.view {
                view.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            bridge.detachScrollView()
            proxy.coordinator = nil
        }

        func pinched(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                let host = bridge.scrollView ?? recognizer.view
                let centroid = host.map { recognizer.location(in: $0) } ?? .zero
                bridge.beginPinch(at: centroid)
            case .changed:
                guard let scrollView = bridge.scrollView else { return }
                bridge.pinchChanged(
                    recognizerScale: recognizer.scale,
                    centroid: recognizer.location(in: scrollView)
                )
            case .ended, .cancelled, .failed:
                bridge.endPinch()
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Keep one-finger scrolling and button taps. Two-finger pans are capped off
            // so they cannot drag the content out from under the pinch centroid.
            true
        }

        private static func scrollView(from view: UIView) -> UIScrollView? {
            var current: UIView? = view
            while let node = current {
                if let scroll = node as? UIScrollView { return scroll }
                current = node.superview
            }
            return nil
        }
    }

    /// Breaks the recognizer → coordinator retain cycle.
    final class PinchProxy: NSObject {
        weak var coordinator: Coordinator?
        @objc func pinched(_ recognizer: UIPinchGestureRecognizer) {
            coordinator?.pinched(recognizer)
        }
    }
}

private final class TimelineWeekPinchSurface: UIView {
    var onLayout: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onLayout?()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

// MARK: - Frozen row / column while the other axis scrolls

/// Pins a gutter or header inside the week `ScrollView` without publishing scroll offset
/// (a `@State` offset would relayout the 7-day Path on every frame).
private struct TimelineWeekPinnedAxes: ViewModifier {
    var axes: Axis.Set

    func body(content: Content) -> some View {
        content.visualEffect { effect, proxy in
            var dx: CGFloat = 0
            var dy: CGFloat = 0
            if axes.contains(.horizontal) {
                let minX = proxy.frame(in: .scrollView(axis: .horizontal)).minX
                if minX < 0 { dx = -minX }
            }
            if axes.contains(.vertical) {
                let minY = proxy.frame(in: .scrollView(axis: .vertical)).minY
                if minY < 0 { dy = -minY }
            }
            return effect.offset(x: dx, y: dy)
        }
    }
}

// MARK: - Selected-tab minute clock

/// Tiny selected-only schedule that advances `now` once a minute for the now-line /
/// open timer block. Kept out of the main week tree so glass-free layout only
/// invalidates when the minute actually flips.
private struct TimelineWeekMinuteTick: View {
    @Binding var now: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Color.clear
                .accessibilityHidden(true)
                .task(id: minuteBucket(context.date)) {
                    bump(context.date)
                }
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func minuteBucket(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970) / 60
    }

    private func bump(_ date: Date) {
        let cal = Calendar.current
        if cal.component(.minute, from: date) != cal.component(.minute, from: now)
            || !cal.isDate(date, inSameDayAs: now) {
            now = date
        }
    }
}

// MARK: - Detail sheet

private struct CalendarItemDetailSheet: View {
    let item: CalendarItem
    /// Running timers are edited from the timer screen, so this is only offered for logged events.
    var onEdit: ((EventDTO) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private var editableEvent: EventDTO? {
        if case .event(let event) = item.source { return event }
        return nil
    }

    private struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    var body: some View {
        NavigationStack {
            Group {
                // Only running (non-paused) items need a live duration; avoid a 30s
                // TimelineView schedule around static event chrome / ContinuousCornerCard glass.
                if item.isRunning && !item.isPaused {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        detailScroll(now: context.date)
                    }
                } else {
                    detailScroll(now: .now)
                }
            }
            .background(DesignTokens.bgCanvas.ignoresSafeArea())
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if let event = editableEvent, let onEdit {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") { onEdit(event) }
                            .fontWeight(.semibold)
                            .accessibilityHint("Change or delete this entry")
                    }
                }
            }
            .benitoNavigationBarGlass()
        }
        .benitoSheetDetents()
    }

    private func detailScroll(now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: item.systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(item.color)
                        .accessibilityHidden(true)
                    Text(item.shortTitle)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(DesignTokens.textPrimary)
                    Spacer(minLength: 0)
                    if item.isRunning {
                        StatusChip(text: item.isPaused ? "Paused" : "Running", accent: item.color, inverted: false)
                    }
                }

                ContinuousCornerCard {
                    VStack(spacing: 10) {
                        ForEach(rows(now: now)) { row in
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.label)
                                    .foregroundStyle(DesignTokens.textSecondary)
                                Spacer(minLength: 12)
                                Text(row.value)
                                    .foregroundStyle(DesignTokens.textPrimary)
                                    .multilineTextAlignment(.trailing)
                            }
                            .font(.subheadline)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                if let notes = item.notes {
                    ContinuousCornerCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Notes")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DesignTokens.textSecondary)
                            Text(notes)
                                .font(.body)
                                .foregroundStyle(DesignTokens.textPrimary)
                        }
                    }
                }
            }
            .padding(DesignTokens.gutter)
        }
    }

    private func rows(now: Date) -> [Row] {
        var rows = [Row(label: "Type", value: item.typeName)]
        if let subtype = item.subtypeName { rows.append(Row(label: "Subtype", value: subtype)) }
        if let side = item.sideName { rows.append(Row(label: "Side", value: side)) }
        if let amount = item.amountText { rows.append(Row(label: "Amount", value: amount)) }

        let start = item.startedAt
        if let end = item.endedAt(now: now) {
            let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
            rows.append(Row(label: "Start", value: start.formatted(date: .abbreviated, time: .shortened)))
            if item.isRunning {
                rows.append(Row(label: "End", value: item.isPaused ? "Paused" : "Still running"))
            } else {
                rows.append(Row(
                    label: "End",
                    value: sameDay
                        ? PrototypeFormatters.shortTime(end)
                        : end.formatted(date: .abbreviated, time: .shortened)
                ))
            }
            if let duration = item.duration(now: now) {
                rows.append(Row(label: "Duration", value: PrototypeFormatters.compactDuration(duration)))
            }
            let paused = item.pausedTime(now: now)
            if paused > 0 {
                rows.append(Row(label: "Paused", value: PrototypeFormatters.compactDuration(paused)))
            }
        } else {
            rows.append(Row(label: "Time", value: start.formatted(date: .abbreviated, time: .shortened)))
        }
        return rows
    }
}

#Preview {
    TimelineWeekView(model: AppModel(serverURLString: BenitoServerPresets.loopback))
}
