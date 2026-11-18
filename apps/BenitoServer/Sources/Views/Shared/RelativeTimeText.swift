import SwiftUI

/// "12 minutes ago" that keeps itself current without redrawing anything around it.
struct RelativeTimeText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Format.relative(date, to: context.date))
        }
    }
}
