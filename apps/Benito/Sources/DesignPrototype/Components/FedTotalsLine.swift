import BenitoKit
import SwiftUI

/// Compact "total fed" line: nursing minutes + bottle volume for one day.
/// Bottles display in ounces (the unit the app logs in); ml entries are converted.
struct FedTotalsLine: View {
    let totals: DailyFedTotals
    var emptyText = "No feeds yet"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "drop.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(DesignTokens.feed)
                .accessibilityHidden(true)
            Text("FED")
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(DesignTokens.feed)
            Text(valueText)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(totals.isEmpty ? DesignTokens.textSecondary : DesignTokens.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var nursingText: String? {
        guard totals.hasNursing else { return nil }
        return PrototypeFormatters.compactDuration(totals.nursingSeconds)
    }

    private var bottleText: String? {
        guard totals.hasBottle else { return nil }
        return totals.bottleOuncesTotal.formatted(.number.precision(.fractionLength(0...1)))
    }

    private var valueText: String {
        let parts = [
            nursingText.map { "\($0) nursing" },
            bottleText.map { "\($0) oz bottle" },
        ].compactMap { $0 }
        return parts.isEmpty ? emptyText : parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        let spokenParts = [
            totals.hasNursing
                ? Duration.seconds(totals.nursingSeconds).formatted(.units(allowed: [.hours, .minutes], width: .wide)) + " nursing"
                : nil,
            bottleText.map { "\($0) ounces by bottle" },
        ].compactMap { $0 }
        return spokenParts.isEmpty ? "Total fed: \(emptyText)" : "Total fed: " + spokenParts.joined(separator: ", ")
    }
}
