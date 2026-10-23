import SwiftUI
import TipKit
import BenitoKit

enum TimelineDisplayMode: String, CaseIterable, Identifiable {
    case week
    case day
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "Week"
        case .day: return "Day"
        case .list: return "List"
        }
    }
}

struct TimelinePrototypeView: View {
    var model: AppModel
    /// TabView keeps inactive tabs alive — skip the week-grid minute publisher off-tab.
    var isSelected: Bool = true
    @AppStorage("benito.timelineMode") private var mode: TimelineDisplayMode = .week
    @State private var editing: EventDTO?
    @State private var pendingDelete: EventDTO?
    private let dayTip = TimelineDayTip()

    private var glance: PrototypeGlance {
        PrototypeGlanceBuilder.from(model: model)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .week:
                    TimelineWeekView(model: model, isSelected: isSelected)
                case .day:
                    TimelineDayView(model: model, isSelected: isSelected)
                case .list:
                    if glance.timeline.isEmpty {
                        emptyState
                    } else {
                        List {
                            ForEach(glance.timeline) { item in
                                listRow(item)
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
            .background(DesignTokens.bgCanvas.ignoresSafeArea())
            .onChange(of: mode) { _, newMode in
                if newMode == .day { dayTip.invalidate(reason: .actionPerformed) }
            }
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .benitoNavigationBarGlass()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    CapsuleSegmentBar(
                        options: Array(TimelineDisplayMode.allCases),
                        selection: mode,
                        title: \.title,
                        accent: DesignTokens.feed,
                        minHeight: 30,
                        horizontalPadding: 14,
                        accessibilityLabel: "Timeline view"
                    ) { mode = $0 }
                    .fixedSize(horizontal: true, vertical: false)
                    .popoverTip(mode == .day ? nil : dayTip, arrowEdge: .top)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refreshState() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(DesignTokens.textSecondary)
                    }
                    .buttonStyle(BenitoBorderlessButtonStyle())
                    .accessibilityLabel("Refresh")
                }
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
    }

    /// Demo glance rows have no backing event; only real events are editable.
    private func event(for item: PrototypeTimelineItem) -> EventDTO? {
        model.timeline.first { $0.id == item.id }
    }

    @ViewBuilder
    private func listRow(_ item: PrototypeTimelineItem) -> some View {
        if let event = event(for: item) {
            Button {
                editing = event
            } label: {
                timelineCard(item)
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
        } else {
            timelineCard(item)
        }
    }

    private func timelineCard(_ item: PrototypeTimelineItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(accentColor(item.accent))
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(DesignTokens.textPrimary)
                    Spacer()
                    Text(PrototypeFormatters.shortTime(item.at))
                        .font(.caption)
                        .foregroundStyle(DesignTokens.textSecondary)
                }
                if let detail = item.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(DesignTokens.textSecondary)
                }
            }
        }
        .padding(14)
        // List rows are Buttons; interactive glass re-samples on scroll/highlight for no gain.
        .benitoGlass(interactive: false)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 40))
                .foregroundStyle(DesignTokens.textSecondary)
            Text("No events yet")
                .font(.headline)
                .foregroundStyle(DesignTokens.textPrimary)
            Text("Log a feed, diaper, or sleep to fill the timeline.")
                .font(.subheadline)
                .foregroundStyle(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func accentColor(_ accent: TimelineAccent) -> Color {
        switch accent {
        case .feed: return DesignTokens.feed
        case .diaper: return DesignTokens.diaper
        case .sleep: return DesignTokens.sleep
        case .outing: return DesignTokens.outing
        case .crying: return DesignTokens.crying
        case .other: return DesignTokens.textSecondary
        }
    }
}

#Preview {
    TimelinePrototypeView(model: AppModel(serverURLString: BenitoServerPresets.loopback))
}
