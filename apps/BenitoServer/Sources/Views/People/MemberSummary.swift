import BenitoKit
import SwiftUI

/// Name, role, and the dates that matter for one family member.
struct MemberSummary: View {
    let member: FamilyMemberDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(member.name)
                    .font(.headline)
                Text(member.role.title)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
            }
            Group {
                if let email = member.email {
                    Text(email)
                        .textSelection(.enabled)
                }
                Text("Joined \(member.joinedAt.formatted(date: .abbreviated, time: .omitted))")
                if let accessExpiresAt = member.accessExpiresAt {
                    Text("Access ends \(Format.dateTime(accessExpiresAt))")
                }
                LastSeenText(date: member.lastSeenAt)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}
