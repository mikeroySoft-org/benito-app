import Foundation

/// The span a "daily" total covers. Today this is the device's local calendar day,
/// midnight to midnight in `calendar.timeZone`; every daily-total request (`/summary/daily`
/// from/to, the offline fallbacks) and the caption that labels those totals come from here,
/// so a future configurable day start only has to change `init(containing:calendar:)`.
public struct DayWindow: Equatable, Hashable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    /// The day that contains `date`.
    public init(containing date: Date, calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: date)
        self.start = start
        self.end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }

    /// The day `offset` days from the one containing `date` (negative = earlier).
    public init(offset: Int, from date: Date, calendar: Calendar = .current) {
        let base = DayWindow(containing: date, calendar: calendar).start
        let shifted = calendar.date(byAdding: .day, value: offset, to: base) ?? base
        self.init(containing: shifted, calendar: calendar)
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// Caption for totals over this window: "Since 12 AM" while `now` is inside it,
    /// otherwise the whole span ("Midnight to midnight", or "6 AM – 6 AM" for other cut-offs).
    public func coverageLabel(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        contains(now) ? sinceLabel(calendar: calendar, locale: locale) : spanLabel(calendar: calendar, locale: locale)
    }

    /// "Since 12 AM" / "Since 00:00", in the user's 12/24-hour setting.
    public func sinceLabel(calendar: Calendar = .current, locale: Locale = .current) -> String {
        "Since \(Self.cutoffText(start, calendar: calendar, locale: locale))"
    }

    /// "Midnight to midnight" when both ends are midnight, otherwise "6 AM – 6 AM".
    public func spanLabel(calendar: Calendar = .current, locale: Locale = .current) -> String {
        if Self.isMidnight(start, calendar: calendar), Self.isMidnight(end, calendar: calendar) {
            return "Midnight to midnight"
        }
        let from = Self.cutoffText(start, calendar: calendar, locale: locale)
        let to = Self.cutoffText(end, calendar: calendar, locale: locale)
        return "\(from) – \(to)"
    }

    private static func isMidnight(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return parts.hour == 0 && parts.minute == 0
    }

    /// "12 AM" on the hour in 12-hour locales (no ":00"), else the locale's short time ("00:00", "6:30 AM").
    private static func cutoffText(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let onTheHour = calendar.component(.minute, from: date) == 0
        if onTheHour, uses12HourClock(locale) {
            let hourOnly = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .hour(.defaultDigits(amPM: .abbreviated))
            return date.formatted(hourOnly)
        }
        let short = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        return date.formatted(short)
    }

    private static func uses12HourClock(_ locale: Locale) -> Bool {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        return pattern.contains("a")
    }
}
