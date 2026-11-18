import SwiftUI
import UserNotifications

struct NotificationsRow: View {
    let reliability: ReliabilityModel

    @AppStorage(HealthMonitor.notifyKey) private var notifyProblems = false

    private var isDenied: Bool { reliability.notificationStatus == .denied }

    private var state: CheckState {
        guard notifyProblems else { return .needsAttention }
        switch reliability.notificationStatus {
        case .authorized?, .provisional?: return .ok
        case .denied?, .notDetermined?: return .needsAttention
        default: return .couldNotCheck
        }
    }

    private var finding: String {
        guard notifyProblems else {
            return "Off. This app will not tell you when the server stops or a backup fails."
        }
        switch reliability.notificationStatus {
        case .authorized?, .provisional?:
            return "On. You get one notification when a problem starts."
        case .denied?:
            return "On here, but macOS does not let Benito Server show notifications. Allow them in Notifications settings."
        case .notDetermined?:
            return "On here, but macOS has not been told to allow notifications yet. Turn this off and on again to be asked."
        default:
            return "macOS did not say whether notifications are allowed."
        }
    }

    var body: some View {
        ReliabilityRow(
            title: "Notifications",
            state: state,
            finding: finding,
            why: "You hear about it when the server has been down for a minute, a backup fails or is overdue, or the disk is nearly full, while Benito Server is open in the menu bar."
        ) {
            VStack(alignment: .trailing, spacing: 6) {
                Toggle("Notify me about problems", isOn: $notifyProblems)
                    .labelsHidden()
                    .toggleStyle(.switch)
                if notifyProblems, isDenied {
                    Button("Open Notification Settings") {
                        SystemSettings.open(SystemSettings.notifications)
                    }
                    .controlSize(.small)
                }
            }
        }
        .onChange(of: notifyProblems) {
            if notifyProblems {
                Task { await reliability.requestNotifications() }
            }
        }
    }
}
