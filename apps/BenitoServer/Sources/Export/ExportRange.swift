import Foundation

enum ExportRange: String, CaseIterable, Identifiable, Sendable {
    case allTime
    case last7Days
    case last30Days
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .allTime: "All Time"
        case .last7Days: "Last 7 Days"
        case .last30Days: "Last 30 Days"
        case .custom: "Custom"
        }
    }

    /// Whole local days: `from` is a local midnight (inclusive) and `to` the local midnight after
    /// the last day (exclusive). "Last 7 days" is today and the six days before it.
    func bounds(
        customStart: Date,
        customEnd: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> (from: Date?, to: Date?) {
        switch self {
        case .allTime:
            return (nil, nil)
        case .last7Days:
            return Self.days(from: calendar.date(byAdding: .day, value: -6, to: now) ?? now, through: now, calendar: calendar)
        case .last30Days:
            return Self.days(from: calendar.date(byAdding: .day, value: -29, to: now) ?? now, through: now, calendar: calendar)
        case .custom:
            return Self.days(from: min(customStart, customEnd), through: max(customStart, customEnd), calendar: calendar)
        }
    }

    private static func days(from first: Date, through last: Date, calendar: Calendar) -> (from: Date?, to: Date?) {
        let lastMidnight = calendar.startOfDay(for: last)
        return (
            calendar.startOfDay(for: first),
            calendar.date(byAdding: .day, value: 1, to: lastMidnight) ?? lastMidnight
        )
    }
}
