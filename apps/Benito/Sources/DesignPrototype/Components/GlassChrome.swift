import SwiftUI

/// Liquid Glass chrome for Benito’s HUD (light and dark).
///
/// - iOS 26+: system `.glassEffect` (optionally tinted / interactive)
/// - iOS 18–25: ultra-thin material + warm card wash so contrast stays readable
///
/// Page canvas (`DesignTokens.bgCanvas`) stays solid so glass cards float above it.
/// Shape language: continuous capsule for floating chrome / thumbs; continuous
/// rounded rect for cards — never square buttons stuffed inside a pill.
enum BenitoGlass {
    static let cardTint = DesignTokens.bgCard
    static let elevatedTint = DesignTokens.bgCardElevated
    static let chromeTint = DesignTokens.bgCanvas

    /// Prefer opaque chrome when Reduce Transparency or Increase Contrast is on.
    @MainActor
    static func prefersOpaqueChrome(
        reduceTransparency: Bool,
        contrast: ColorSchemeContrast
    ) -> Bool {
        reduceTransparency || contrast == .increased
    }

    @available(iOS 26.0, *)
    static func regularGlass(interactive: Bool, tint: Color?) -> Glass {
        let base = interactive ? Glass.regular.interactive() : Glass.regular
        if let tint {
            return base.tint(tint)
        }
        return base
    }

    /// Shared `glassEffectID` / union keys for Home Feed/Diaper/Sleep morphing pill.
    enum ThumbEffectID {
        static let feed = "benito.home.thumb.feed"
        static let diaper = "benito.home.thumb.diaper"
        static let sleep = "benito.home.thumb.sleep"
        static let pause = "benito.timer.thumb.pause"
        static let stop = "benito.timer.thumb.stop"
        /// Union keeps thumbs as one continuous capsule while visible.
        static let union = "benito.thumb.capsule"
    }

    /// Zoom sheet morph IDs (`matchedTransitionSource` / `navigationTransition(.zoom)`).
    enum SheetTransitionID {
        static let feed = "benito.home.sheet.feed"
        static let diaper = "benito.home.sheet.diaper"
        static let sleep = "benito.home.sheet.sleep"
    }

    /// Snappy spring for opening feed/diaper/sleep flows (skipped under Reduce Motion).
    static let sheetPresentationAnimation: Animation = .spring(response: 0.30, dampingFraction: 0.84)

    /// Slightly softer spring when a timer starts / floating chrome settles.
    static let activityStartAnimation: Animation = .smooth(duration: 0.42)
}

extension View {
    /// Card / chip surface. Replaces `.background(fill).clipShape(...)`.
    func benitoGlass(
        tint: Color = BenitoGlass.cardTint,
        cornerRadius: CGFloat = DesignTokens.cardRadius,
        interactive: Bool = false,
        fallbackOpacity: Double = 0.72
    ) -> some View {
        modifier(
            BenitoGlassShapeModifier(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                tint: tint,
                interactive: interactive,
                fallbackOpacity: fallbackOpacity
            )
        )
    }

    /// Capsule glass (unselected pills / chips). Selected solid accents stay solid.
    func benitoGlassCapsule(
        tint: Color = BenitoGlass.elevatedTint,
        interactive: Bool = false,
        fallbackOpacity: Double = 0.65
    ) -> some View {
        modifier(
            BenitoGlassShapeModifier(
                shape: Capsule(style: .continuous),
                tint: tint,
                interactive: interactive,
                fallbackOpacity: fallbackOpacity
            )
        )
    }

    /// Full-bleed dock behind chrome that must span the safe area.
    /// Prefer floating capsule thumbs (`ThumbActionBar`) over this for primary actions.
    func benitoGlassChrome(fallbackOpacity: Double = 0.55) -> some View {
        modifier(
            BenitoGlassShapeModifier(
                shape: Rectangle(),
                tint: BenitoGlass.chromeTint,
                interactive: false,
                fallbackOpacity: fallbackOpacity
            )
        )
    }

    /// Floating continuous-capsule chrome (OpenBBQ Cook thumb grammar).
    func benitoFloatingCapsuleChrome(
        tint: Color = BenitoGlass.elevatedTint,
        interactive: Bool = false,
        fallbackOpacity: Double = 0.92
    ) -> some View {
        modifier(
            BenitoGlassShapeModifier(
                shape: Capsule(style: .continuous),
                tint: tint,
                interactive: interactive,
                fallbackOpacity: fallbackOpacity
            )
        )
    }

    /// Navigation bar: system Liquid Glass on iOS 26; material fallback below.
    /// Bar content follows the OS light/dark appearance.
    @ViewBuilder
    func benitoNavigationBarGlass() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            self.toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
    }

    /// Tab bar: system Liquid Glass on iOS 26; material fallback below.
    @ViewBuilder
    func benitoTabBarGlass() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            self.toolbarBackground(.ultraThinMaterial, for: .tabBar)
        }
    }

    /// Selected = solid accent (CTA); unselected = glass capsule.
    @ViewBuilder
    func benitoSelectableCapsule(selected: Bool, solid: Color, glassTint: Color = BenitoGlass.elevatedTint) -> some View {
        if selected {
            self
                .background(solid, in: Capsule(style: .continuous))
        } else {
            self.benitoGlassCapsule(tint: glassTint, interactive: true)
        }
    }

    /// Selected = solid accent; unselected = glass rounded rect.
    @ViewBuilder
    func benitoSelectableCard(
        selected: Bool,
        solid: Color,
        glassTint: Color = BenitoGlass.elevatedTint,
        cornerRadius: CGFloat = 12
    ) -> some View {
        if selected {
            self
                .background(solid, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.benitoGlass(tint: glassTint, cornerRadius: cornerRadius, interactive: true)
        }
    }
}

/// Shape-backed glass (cards, capsules, docks).
private struct BenitoGlassShapeModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color
    let interactive: Bool
    let fallbackOpacity: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(glassStyle, in: shape)
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(tint.opacity(fallbackOpacity))
                    }
                }
                .clipShape(shape)
        }
    }

    @available(iOS 26.0, *)
    private var glassStyle: Glass {
        let base = Glass.regular.tint(tint)
        return interactive ? base.interactive(true) : base
    }
}

/// List / Form row background with warm glass wash.
struct BenitoGlassListRowBackground: View {
    var tint: Color = BenitoGlass.cardTint
    var cornerRadius: CGFloat = 10

    @ViewBuilder
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(Glass.regular.tint(tint), in: shape)
                .padding(.vertical, 1)
        } else {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(tint.opacity(0.72))
            }
            .padding(.vertical, 1)
        }
    }
}


/// Label only. iOS 26 `.plain` / automatic button styles can still paint a
/// rounded-rect plate; inside a capsule or glass row that reads as rect-in-pill.
struct BenitoBorderlessButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// Capsule track + capsule segments. Do not drop a system segmented picker
/// (rounded-rect thumb) into this chrome.
struct CapsuleSegmentBar<Option: Hashable>: View {
    let options: [Option]
    let selection: Option
    let title: (Option) -> String
    var accent: Color
    var minHeight: CGFloat = 40
    /// Extra inset inside each segment. Default keeps existing pills unchanged.
    var horizontalPadding: CGFloat = 0
    var accessibilityLabel: String?
    let onSelect: (Option) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let selected = selection == option
                Button {
                    onSelect(option)
                } label: {
                    Text(title(option))
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, horizontalPadding)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: minHeight)
                        .foregroundStyle(selected ? DesignTokens.onAccent : DesignTokens.textPrimary)
                        .background(
                            selected ? accent : Color.clear,
                            in: Capsule(style: .continuous)
                        )
                        .contentShape(Capsule(style: .continuous))
                }
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
        .padding(4)
        .background {
            ZStack {
                Capsule(style: .continuous).fill(.ultraThinMaterial)
                Capsule(style: .continuous).fill(DesignTokens.bgCardElevated.opacity(0.55))
            }
        }
        .clipShape(Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(DesignTokens.textSecondary.opacity(0.2), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .modifier(CapsuleSegmentAccessibilityLabel(text: accessibilityLabel))
    }
}

private struct CapsuleSegmentAccessibilityLabel: ViewModifier {
    var text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.accessibilityLabel(text)
        } else {
            content
        }
    }
}
