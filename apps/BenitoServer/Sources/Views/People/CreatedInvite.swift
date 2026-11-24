import BenitoKit
import CoreGraphics
import Foundation

/// A freshly created invite with the link that carries its one-time secret.
struct CreatedInvite {
    let invite: FamilyInviteDTO
    let link: URL
    let qrCode: CGImage?

    /// `nil` when the server's answer has no secret or no usable address.
    init?(invite: FamilyInviteDTO) {
        guard
            let server = invite.endpoints.first.flatMap({ URL(string: $0) }),
            let link = FamilyInviteLink(invite: invite, currentServer: server)
        else { return nil }
        self.invite = invite
        self.link = link.url
        qrCode = QRCode.image(for: link.url.absoluteString)
    }
}
