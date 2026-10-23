import SwiftUI

/// Running nursing feed: the Feed sheet's Nursing panel without the Nursing | Bottle
/// switcher (no switching to bottle mid-feed). Same scaffold, Start Time, L/R sides,
/// pause/resume, and blue Save as `FeedLogSheet`.
struct RunningFeedSheet: View {
    var model: AppModel
    /// Chevron: hide the sheet, keep the timer running.
    var onHide: () -> Void
    /// Save stopped the timer.
    var onSaved: () -> Void

    @State private var isPresented = true

    var body: some View {
        LogSheetScaffold(title: "Feeding", isPresented: $isPresented) {
            NursingFeedPanel(model: model, onSaved: onSaved)
        }
        .onChange(of: isPresented) { _, shown in
            if !shown { onHide() }
        }
    }
}
