import ServiceManagement
import SwiftUI

struct LoginItemRow: View {
    @Bindable var reliability: ReliabilityModel

    private var state: CheckState {
        switch reliability.loginItemStatus {
        case .enabled: return .ok
        case .notRegistered, .requiresApproval: return .needsAttention
        case .notFound: return .couldNotCheck
        @unknown default: return .couldNotCheck
        }
    }

    private var finding: String {
        if let error = reliability.loginItemError {
            return "macOS did not accept the change: \(error)"
        }
        switch reliability.loginItemStatus {
        case .enabled:
            return "Benito Server opens when you log in."
        case .notRegistered:
            return "Benito Server does not open when you log in."
        case .requiresApproval:
            return "macOS is waiting for you to allow Benito Server under Login Items."
        case .notFound:
            return "macOS could not find this app as a login item. Move Benito Server to the Applications folder and open it again."
        @unknown default:
            return "macOS gave an answer this app does not know."
        }
    }

    var body: some View {
        ReliabilityRow(
            title: "Benito Server opens at login",
            state: state,
            finding: finding,
            why: "The server keeps running without this app, but only this app can tell you when a backup fails or the server stops."
        ) {
            VStack(alignment: .trailing, spacing: 6) {
                Toggle("Open at login", isOn: $reliability.opensAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                if reliability.loginItemStatus == .requiresApproval {
                    Button("Open Login Items Settings") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    .controlSize(.small)
                }
            }
        }
        .onChange(of: reliability.opensAtLogin) {
            reliability.applyOpensAtLogin()
        }
    }
}
