import BenitoKit
import SwiftUI

/// Elapsed digits of a running or paused timer. Only the digits redraw each second.
struct TimerClock: View {
    let timer: TimerDTO

    var body: some View {
        if timer.isPaused {
            digits(at: .now)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                digits(at: context.date)
            }
        }
    }

    private func digits(at date: Date) -> some View {
        Text(Format.clock(timer.elapsed(at: date)))
            .monospacedDigit()
    }
}
