import BenitoKit
import SwiftUI

/// Read-only glance for one child: last feed, last diaper, last medicine, and any active timer.
struct ChildGlanceView: View {
    let child: ChildGlance

    private var isEmpty: Bool {
        child.lastFeed == nil && child.lastDiaper == nil && child.lastMedicine == nil
            && child.activeTimer == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(child.childName)
                .font(.headline)
            if let timer = child.activeTimer {
                GlanceRow(systemImage: GlanceText.timerSymbol(timer), text: GlanceText.timer(timer)) {
                    TimerClock(timer: timer)
                }
            }
            if let feed = child.lastFeed {
                GlanceRow(systemImage: "waterbottle", text: GlanceText.feed(feed)) {
                    RelativeTimeText(date: feed.startedAt)
                }
            }
            if let diaper = child.lastDiaper {
                GlanceRow(systemImage: "drop", text: GlanceText.diaper(diaper)) {
                    RelativeTimeText(date: diaper.startedAt)
                }
            }
            if let medicine = child.lastMedicine {
                GlanceRow(systemImage: "pills", text: GlanceText.medicine(medicine)) {
                    RelativeTimeText(date: medicine.startedAt)
                }
            }
            if isEmpty {
                Text("Nothing logged yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
