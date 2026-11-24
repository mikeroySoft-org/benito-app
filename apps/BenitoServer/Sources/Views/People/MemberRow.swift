import BenitoKit
import SwiftUI

struct MemberRow: View {
    @Environment(ServerModel.self) private var model

    let member: FamilyMemberDTO
    let family: AdminFamily

    @State private var isConfirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                MemberSummary(member: member)
                Spacer(minLength: 12)
                Button("Remove…", role: .destructive) {
                    isConfirmingRemoval = true
                }
            }
            ForEach(member.devices) { device in
                DeviceRow(device: device, ownerName: member.name)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Remove \(member.name) from \(family.name)?",
            isPresented: $isConfirmingRemoval
        ) {
            Button("Remove \(member.name)", role: .destructive) {
                Task { await model.removeMember(member, from: family) }
            }
        } message: {
            Text("This ends \(member.name)'s membership in \(family.name), signs them out, and removes all of their devices. They need a new invite to come back.")
        }
    }
}
