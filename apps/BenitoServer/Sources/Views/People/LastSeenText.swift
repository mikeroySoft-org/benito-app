import SwiftUI

struct LastSeenText: View {
    let date: Date?

    var body: some View {
        if let date {
            HStack(spacing: 4) {
                Text("Last seen")
                RelativeTimeText(date: date)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("Not seen yet")
        }
    }
}
