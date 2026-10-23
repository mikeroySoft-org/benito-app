import SwiftUI

struct ThumbAction: Identifiable {
    var id: String { title + systemImage }
    let title: String
    let systemImage: String
    /// Optional one-line summary under the title (e.g. last feed side · ago).
    var detail: String? = nil
    /// Soft accent when a related timer is *running* — never a permanent selected/tab state.
    var runningEmphasis: Bool = false
    var accent: Color = DesignTokens.textSecondary
    /// Optional `matchedTransitionSource` id for sheet zoom morph.
    var transitionID: String? = nil
    /// Optional `glassEffectID` for Liquid Glass union morphing.
    var glassEffectID: String? = nil
    let action: () -> Void
}

/// OpenBBQ-style floating capsule thumb bar (≥52pt; taller when any thumb has detail).
/// Thumbs are capsule segments unioned into one continuous pill — never square cards
/// stuffed inside a pill chrome.
struct ThumbActionBar: View {
    let actions: [ThumbAction]
    /// Namespace for sheet zoom morph (`matchedTransitionSource`).
    var sheetTransitionNamespace: Namespace.ID? = nil

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var prefersOpaque: Bool {
        BenitoGlass.prefersOpaqueChrome(
            reduceTransparency: reduceTransparency,
            contrast: contrast
        )
    }

    /// Uniform row height: taller when any thumb carries a detail line (Feed).
    private var thumbHeight: CGFloat {
        actions.contains(where: { $0.detail != nil })
            ? DesignTokens.thumbMinTall
            : DesignTokens.thumbMin
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassCapsuleThumbRow(
                actions: actions,
                thumbHeight: thumbHeight,
                prefersOpaque: prefersOpaque,
                reduceMotion: reduceMotion,
                sheetTransitionNamespace: sheetTransitionNamespace
            )
        } else {
            legacyFloatingPill
        }
    }

    // MARK: - Pre-iOS 26

    private var legacyFloatingPill: some View {
        HStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, item in
                if index > 0 { segmentDivider }
                legacyThumb(item)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(minHeight: thumbHeight + 8)
        .background(DesignTokens.bgCardElevated.opacity(0.95), in: Capsule(style: .continuous))
        .padding(.horizontal, DesignTokens.gutter)
        .padding(.vertical, 8)
    }

    private var segmentDivider: some View {
        Rectangle()
            .fill(DesignTokens.textSecondary.opacity(0.28))
            .frame(width: 1, height: 28)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }

    private func legacyThumb(_ item: ThumbAction) -> some View {
        Button(action: item.action) {
            thumbLabel(item)
                .foregroundStyle(item.runningEmphasis ? item.accent : DesignTokens.textPrimary)
                .contentShape(Capsule(style: .continuous))
                .background {
                    if item.runningEmphasis {
                        Capsule(style: .continuous)
                            .fill(item.accent.opacity(0.22))
                            .padding(.vertical, 2)
                    }
                }
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
        .accessibilityLabel(item.detail.map { "\(item.title), \($0)" } ?? item.title)
        .modifier(SheetZoomSourceModifier(
            namespace: sheetTransitionNamespace,
            sourceID: item.transitionID
        ))
    }

    @ViewBuilder
    private func thumbLabel(_ item: ThumbAction) -> some View {
        VStack(spacing: item.detail == nil ? 4 : 2) {
            Image(systemName: item.systemImage)
                .font(.system(size: 22, weight: .semibold))
            Text(item.title)
                .font(.caption.weight(.semibold))
            if let detail = item.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: thumbHeight)
        .padding(.horizontal, 6)
    }
}

// MARK: - iOS 26 Liquid Glass morphing capsule

@available(iOS 26.0, *)
private struct GlassCapsuleThumbRow: View {
    let actions: [ThumbAction]
    let thumbHeight: CGFloat
    let prefersOpaque: Bool
    let reduceMotion: Bool
    let sheetTransitionNamespace: Namespace.ID?

    @Namespace private var thumbGlassNamespace

    /// Identity avoids matched-geometry glass morph during ambient sheet springs
    /// (Feed/Diaper/Sleep raise/lower) which re-rasterized the whole capsule each frame.
    private var glassTransition: GlassEffectTransition { .identity }

    /// Zero spacing keeps the unioned pill layout stable; non-zero spacing existed only
    /// to feed matched-geometry morphs we no longer run on interaction.
    private var containerSpacing: CGFloat { 0 }

    var body: some View {
        let row = GlassEffectContainer(spacing: containerSpacing) {
            HStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { segmentDivider }
                    glassThumb(item, index: index)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .frame(minHeight: thumbHeight + 8)
        }
        // Sheet springs use withAnimation at the call site; do not let that ambient
        // animation retarget Liquid Glass layout on every expand/collapse.
        .transaction { $0.animation = nil }

        if prefersOpaque {
            row
                .background(DesignTokens.bgCardElevated.opacity(0.95), in: Capsule(style: .continuous))
                .padding(.horizontal, DesignTokens.gutter)
                .padding(.vertical, 8)
        } else {
            row
                .padding(.horizontal, DesignTokens.gutter)
                .padding(.vertical, 8)
        }
    }

    private var segmentDivider: some View {
        Rectangle()
            .fill(DesignTokens.textSecondary.opacity(prefersOpaque ? 0.35 : 0.28))
            .frame(width: 1, height: 28)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }

    private func glassThumb(_ item: ThumbAction, index: Int) -> some View {
        let effectID = item.glassEffectID ?? "benito.thumb.\(index)"
        return Button(action: item.action) {
            VStack(spacing: item.detail == nil ? 4 : 2) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    // Bounce only when Reduce Motion is off; avoid re-triggering glass
                    // work on every runningEmphasis identity flicker during timer sync.
                    .symbolEffect(.bounce, value: reduceMotion ? false : item.runningEmphasis)
                Text(item.title)
                    .font(.caption.weight(.semibold))
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.65)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: thumbHeight)
            .foregroundStyle(thumbForeground(item))
            .padding(.horizontal, 6)
            .contentShape(Capsule(style: .continuous))
            .background {
                if item.runningEmphasis, prefersOpaque {
                    Capsule(style: .continuous)
                        .fill(item.accent)
                        .padding(.vertical, 2)
                }
            }
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
        .accessibilityLabel(item.detail.map { "\(item.title), \($0)" } ?? item.title)
        .modifier(ThumbGlassEffectModifier(
            enabled: !prefersOpaque,
            // Non-interactive glass: interactive Liquid Glass re-samples on touch and
            // fights Button hit-testing / spring panels while a timer is running.
            glass: BenitoGlass.regularGlass(
                interactive: false,
                tint: item.runningEmphasis ? item.accent.opacity(0.35) : nil
            ),
            effectID: effectID,
            unionID: BenitoGlass.ThumbEffectID.union,
            namespace: thumbGlassNamespace,
            transition: glassTransition
        ))
        .modifier(SheetZoomSourceModifier(
            namespace: sheetTransitionNamespace,
            sourceID: item.transitionID
        ))
    }

    /// Running emphasis via vibrant label on glass — not a stuffed filled square.
    private func thumbForeground(_ item: ThumbAction) -> Color {
        if item.runningEmphasis {
            if prefersOpaque { return DesignTokens.bgCanvas }
            return item.accent
        }
        return DesignTokens.textPrimary
    }
}

/// Applies per-thumb Liquid Glass + morph IDs when drawing the floating capsule.
@available(iOS 26.0, *)
private struct ThumbGlassEffectModifier: ViewModifier {
    let enabled: Bool
    let glass: Glass
    let effectID: String
    let unionID: String
    let namespace: Namespace.ID
    let transition: GlassEffectTransition

    func body(content: Content) -> some View {
        if enabled {
            content
                .glassEffect(glass, in: Capsule(style: .continuous))
                .glassEffectID(effectID, in: namespace)
                .glassEffectUnion(id: unionID, namespace: namespace)
                .glassEffectTransition(transition)
        } else {
            content
        }
    }
}

/// Marks a control as the zoom source for a presented sheet (iOS 18+).
private struct SheetZoomSourceModifier: ViewModifier {
    let namespace: Namespace.ID?
    let sourceID: String?

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace, let sourceID {
            content.matchedTransitionSource(id: sourceID, in: namespace)
        } else {
            content
        }
    }
}

struct BigActionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var accent: Color = DesignTokens.feed
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accent.opacity(0.18))
                        .frame(width: 52, height: 52)
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(DesignTokens.textPrimary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(DesignTokens.textSecondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            .padding(16)
            .frame(minHeight: DesignTokens.thumbMin + 16)
            .benitoGlass(interactive: false)
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
    }
}
