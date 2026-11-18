import BenitoKit
import SwiftUI

struct DeviceRow: View {
    @Environment(ServerModel.self) private var model

    let device: MemberDeviceDTO
    let ownerName: String

    @State private var isConfirmingRevoke = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Group {
                    if let modelName = device.model {
                        Text(modelName)
                    }
                    LastSeenText(date: device.lastSeenAt)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Revoke…") {
                isConfirmingRevoke = true
            }
            .controlSize(.small)
        }
        .padding(.leading, 12)
        .confirmationDialog(
            "Revoke \(ownerName)'s device \"\(device.name)\"?",
            isPresented: $isConfirmingRevoke
        ) {
            Button("Revoke \(device.name)", role: .destructive) {
                Task { await model.revokeDevice(device) }
            }
        } message: {
            Text("\"\(device.name)\" is signed out and can no longer sync. \(ownerName) stays in the family, and that device needs a new invite to connect again.")
        }
    }
}
