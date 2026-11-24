import BenitoKit
import SwiftUI

struct FamilySection: View {
    let family: AdminFamily

    private var childNames: String {
        family.children.map(\.name).formatted(.list(type: .and))
    }

    var body: some View {
        Section {
            ForEach(family.members) { member in
                MemberRow(member: member, family: family)
            }
        } header: {
            Text(family.name)
        } footer: {
            if !family.children.isEmpty {
                Text("Children: \(childNames)")
            }
        }
        if !family.invites.isEmpty {
            Section("Pending Invites for \(family.name)") {
                ForEach(family.invites) { invite in
                    PendingInviteRow(invite: invite)
                }
            }
        }
    }
}
