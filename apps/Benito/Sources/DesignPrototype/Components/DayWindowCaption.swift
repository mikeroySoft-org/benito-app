import BenitoKit
import SwiftUI

/// Subtle caption naming the span a daily-totals strip covers: "Since 12 AM" for today,
/// "Midnight to midnight" for a past day. Text comes from `DayWindow`, the same value
/// that bounds the summary request, so the label always matches the numbers.
struct DayWindowCaption: View {
    let window: DayWindow
    let now: Date

    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    var body: some View {
        let text = window.coverageLabel(now: now, calendar: calendar, locale: locale)
        Text(text)
            .font(.caption)
            .foregroundStyle(DesignTokens.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(spokenLabel(text))
    }

    /// "Totals since 12 AM" / "Totals from midnight to midnight".
    private func spokenLabel(_ text: String) -> String {
        let phrase = text.prefix(1).lowercased() + text.dropFirst()
        return window.contains(now) ? "Totals \(phrase)" : "Totals from \(phrase)"
    }
}
