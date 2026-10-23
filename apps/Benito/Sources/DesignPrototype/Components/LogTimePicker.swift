import SwiftUI

/// Compact "When" control shared by every log sheet.
/// `date == nil` means "now" (resolved by the model at log time).
struct LogTimePicker: View {
    @Binding var date: Date?
    var title: String = "When"
    var accent: Color = DesignTokens.feed

    @State private var choice: Choice = .now
    @State private var customDate = Date()

    /// Custom entries may go back one week.
    private static let maxLookback: TimeInterval = 7 * 24 * 60 * 60

    private enum Choice: Hashable, CaseIterable {
        case now, minus15, minus30, minus60, custom

        var title: String {
            switch self {
            case .now: return "Now"
            case .minus15: return "15m ago"
            case .minus30: return "30m ago"
            case .minus60: return "1h ago"
            case .custom: return "Custom…"
            }
        }

        var spokenLabel: String {
            switch self {
            case .now: return "Now"
            case .minus15: return "15 minutes ago"
            case .minus30: return "30 minutes ago"
            case .minus60: return "1 hour ago"
            case .custom: return "Custom time"
            }
        }

        var minutesAgo: Int? {
            switch self {
            case .minus15: return 15
            case .minus30: return 30
            case .minus60: return 60
            case .now, .custom: return nil
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                LogFieldLabel(text: title)
                Spacer(minLength: 8)
                Text(summary)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(date == nil ? DesignTokens.textSecondary : accent)
            }
            .accessibilityElement(children: .combine)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Choice.allCases, id: \.self) { item in
                    ChoicePill(
                        title: item.title,
                        selected: choice == item,
                        accent: accent,
                        spokenLabel: item.spokenLabel
                    ) {
                        select(item)
                    }
                }
            }

            if choice == .custom {
                DatePicker(
                    "Time",
                    selection: $customDate,
                    in: Date().addingTimeInterval(-Self.maxLookback)...Date(),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .tint(accent)
                .foregroundStyle(DesignTokens.textPrimary)
                .frame(minHeight: 44)
            }
        }
        .onAppear {
            // Re-entering a sheet with a preset date: show it as a custom time.
            if let date {
                choice = .custom
                customDate = date
            }
        }
        .onChange(of: customDate) { _, newValue in
            if choice == .custom { date = newValue }
        }
    }

    private var summary: String {
        guard let date else { return "Now" }
        if Calendar.current.isDateInToday(date) {
            return PrototypeFormatters.shortTime(date)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private func select(_ item: Choice) {
        choice = item
        switch item {
        case .now:
            date = nil
        case .custom:
            customDate = date ?? Date()
            date = customDate
        case .minus15, .minus30, .minus60:
            date = Date().addingTimeInterval(-TimeInterval((item.minutesAgo ?? 0) * 60))
        }
    }
}

/// Small uppercase field caption used across log sheets.
struct LogFieldLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(DesignTokens.textSecondary)
    }
}

/// Large, thumb-friendly single-choice pill (≥44pt tall).
struct ChoicePill: View {
    let title: String
    let selected: Bool
    var accent: Color = DesignTokens.feed
    var spokenLabel: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .foregroundStyle(selected ? DesignTokens.onAccent : DesignTokens.textPrimary)
                .benitoSelectableCapsule(selected: selected, solid: accent)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(DesignTokens.textSecondary.opacity(selected ? 0 : 0.25), lineWidth: 1)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
        .accessibilityLabel(spokenLabel ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview {
    LogTimePicker(date: .constant(nil))
        .padding()
        .background(DesignTokens.bgCard)
}
