import SwiftUI

extension View {
    /// Caps content at `DesignTokens.readableContentWidth` and centers it in wider windows
    /// (iPad, iPhone Duo inner display). On portrait iPhones the window is already narrower
    /// than the cap, so layout is unchanged there.
    ///
    /// Apply it to the content inside a `ScrollView` / `List` / bottom bar — not to the
    /// scroll container or background — so scrolling and the canvas stay full-width.
    func readableContentWidth() -> some View {
        frame(maxWidth: DesignTokens.readableContentWidth)
            .frame(maxWidth: .infinity)
    }
}
