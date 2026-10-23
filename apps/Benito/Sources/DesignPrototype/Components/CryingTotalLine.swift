import BenitoKit
import SwiftUI

/// Compact crying-total line under the fed totals: active crying minutes for one day
/// (clipped at midnight, paused time excluded). Callers hide it when there was none.
struct CryingTotalLine: View {
    let seconds: TimeInterval

    /// Under 30 s rounds to nothing worth showing (same cut-off as nursing).
    static func isVisible(seconds: TimeInterval) -> Bool { seconds >= 30 }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ActivityKind.crying.systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(DesignTokens.crying)
                .accessibilityHidden(true)
            Text("CRYING")
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(DesignTokens.crying)
            Text(PrototypeFormatters.compactDuration(seconds))
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Crying: \(spokenDuration)")
    }

    private var spokenDuration: String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }
}
