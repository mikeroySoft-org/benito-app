import BenitoKit
import SwiftUI

struct PendingInviteRow: View {
    @Environment(ServerModel.self) private var model

    let invite: FamilyInviteDTO

    private var title: String {
        if let label = invite.label, !label.isEmpty {
            "\(label) (\(invite.role.title))"
        } else {
            "\(invite.role.title) invite"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Group {
                    Text("Created \(Format.dateTime(invite.createdAt)) as \(invite.inviterName)")
                    HStack(spacing: 4) {
                        Text("Expires")
                        RelativeTimeText(date: invite.expiresAt)
                    }
                    .accessibilityElement(children: .combine)
                    if let accessHours = invite.accessHours {
                        Text("Access lasts \(Format.hours(accessHours)) after joining")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Revoke") {
                Task { await model.revokeInvite(invite) }
            }
        }
    }
}
