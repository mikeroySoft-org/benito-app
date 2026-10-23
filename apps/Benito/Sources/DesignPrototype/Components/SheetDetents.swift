import SwiftUI

extension View {
    /// Sheet detents for every Benito sheet: half + full on compact-width iPhones,
    /// full form sheet only in a regular-width window (iPad, iPhone Duo folded).
    ///
    /// Built with the iOS 27 SDK, a regular-width `.medium` sheet floats as a short card
    /// but lays its content out taller and clips the bottom (timer Stop bar, Feed L/R
    /// labels). `.large` there is the standard form sheet and shows everything.
    /// Apply to the sheet's content.
    func benitoSheetDetents() -> some View {
        modifier(BenitoSheetDetents())
    }

    /// Records the window's horizontal size class for `benitoSheetDetents()`.
    /// Apply once at the scene root. Sheet content sees its own (often compact)
    /// size class, so it can't tell a form sheet on iPad from an iPhone sheet.
    func benitoWindowSizeClassSource() -> some View {
        modifier(WindowSizeClassSource())
    }
}

extension EnvironmentValues {
    /// Horizontal size class of the window, not of the current presentation.
    @Entry var benitoWindowHorizontalSizeClass: UserInterfaceSizeClass? = nil
}

private struct WindowSizeClassSource: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.environment(\.benitoWindowHorizontalSizeClass, horizontalSizeClass)
    }
}

private struct BenitoSheetDetents: ViewModifier {
    @Environment(\.benitoWindowHorizontalSizeClass) private var windowSizeClass

    func body(content: Content) -> some View {
        content.presentationDetents(windowSizeClass == .regular ? [.large] : [.medium, .large])
    }
}
