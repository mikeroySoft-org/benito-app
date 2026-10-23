import SwiftUI

struct ContinuousCornerCard<Content: View>: View {
    var padding: CGFloat = 14
    var fill: Color = DesignTokens.bgCard
    var interactive: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .benitoGlass(tint: fill, interactive: interactive)
    }
}

struct StatusChip: View {
    let text: String
    var accent: Color = DesignTokens.feed
    var inverted: Bool = true

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .tracking(1.1)
            .foregroundStyle(inverted ? DesignTokens.onAccent : accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(inverted ? accent : accent.opacity(0.18))
            .clipShape(Capsule(style: .continuous))
    }
}

struct HeroCard: View {
    let eyebrow: String
    /// Static value when `tickingValue` is nil.
    var value: String = ""
    /// When set, only the digit label schedules a TimelineView — glass stays outside the tick.
    var tickingValue: ((Date) -> String)? = nil
    var chip: String? = nil
    var chipAccent: Color = DesignTokens.feed
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(2)
                .foregroundStyle(DesignTokens.textSecondary)

            valueLabel

            if let chip {
                StatusChip(text: chip, accent: chipAccent)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, DesignTokens.gutter)
        // Non-interactive: Button already owns the hit target; interactive glass inside a
        // parent that refreshes (model / minute tick) was re-sampling Liquid Glass for free.
        .benitoGlass(interactive: false)
    }

    @ViewBuilder
    private var valueLabel: some View {
        if let tickingValue {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                valueText(tickingValue(context.date))
            }
        } else {
            valueText(value)
        }
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 56, weight: .bold, design: .rounded))
            .foregroundStyle(DesignTokens.textPrimary)
            .minimumScaleFactor(0.55)
            .lineLimit(1)
            .contentTransition(.numericText())
    }
}

struct GlanceMiniCard: View {
    let title: String
    var value: String = ""
    /// When set, only digit/detail labels schedule a TimelineView — glass stays outside the tick.
    var tickingValue: ((Date) -> String)? = nil
    var detail: String? = nil
    var tickingDetail: ((Date) -> String?)? = nil
    var accent: Color = DesignTokens.textSecondary

    private var needsTick: Bool { tickingValue != nil || tickingDetail != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(DesignTokens.textSecondary)
                .lineLimit(1)

            if needsTick {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    valueAndDetail(at: context.date)
                }
            } else {
                valueAndDetail(at: .now)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benitoGlass()
    }

    @ViewBuilder
    private func valueAndDetail(at date: Date) -> some View {
        valueText(tickingValue?(date) ?? value)
        Text((tickingDetail?(date) ?? detail) ?? " ")
            .font(.caption2)
            .foregroundStyle(accent.opacity(0.95))
            .lineLimit(1)
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 26, weight: .bold, design: .rounded))
            .foregroundStyle(DesignTokens.textPrimary)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
    }
}
