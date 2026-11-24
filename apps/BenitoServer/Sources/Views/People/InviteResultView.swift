import BenitoKit
import SwiftUI

struct InviteResultView: View {
    @Environment(\.dismiss) private var dismiss

    let created: CreatedInvite

    private var linkText: String { created.link.absoluteString }

    var body: some View {
        VStack(spacing: 16) {
            Text("\(created.invite.role.title) Invite for \(created.invite.familyName)")
                .font(.headline)
            Text("Scan this with the phone's camera, or send the link.")
                .foregroundStyle(.secondary)
            if let qrCode = created.qrCode {
                QRCodeView(image: qrCode)
            }
            Text(linkText)
                .font(.callout.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 6))
                .accessibilityLabel("Invite link")
                .accessibilityValue(linkText)
            Text("Expires \(Format.dateTime(created.invite.expiresAt)). It works once: after one phone joins with it, it stops working.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy Link", systemImage: "doc.on.doc") {
                    Desktop.copy(linkText)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
