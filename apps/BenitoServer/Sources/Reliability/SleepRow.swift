import SwiftUI

struct SleepRow: View {
    let minutes: Probed<Int>

    private var state: CheckState {
        switch minutes {
        case .value(0): .ok
        case .value: .needsAttention
        case .pending, .unavailable: .couldNotCheck
        }
    }

    private var finding: String {
        switch minutes {
        case .pending:
            "Checking…"
        case .value(0):
            "This Mac does not go to sleep on its own."
        case .value(let minutes):
            "This Mac goes to sleep after \(minutes) idle \(minutes == 1 ? "minute" : "minutes")."
        case .unavailable(let reason):
            reason
        }
    }

    var body: some View {
        ReliabilityRow(
            title: "Sleep",
            state: state,
            finding: finding,
            why: "While this Mac sleeps, phones cannot sync. They keep what is logged and send it when the Mac wakes, but nobody sees the other parent's entries until then."
        ) {
            Button("Open Energy Settings") {
                SystemSettings.open(SystemSettings.energy)
            }
            .controlSize(.small)
        }
    }
}
