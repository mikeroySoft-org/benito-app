import CoreTransferable
import Foundation
import GroupActivities
import os

/// SharePlay activity a parent shares from Invite to Family (FaceTime, Messages, or by bringing
/// iPhones together). Carries no secrets: the one-time invite link only travels later, over the
/// session's end-to-end encrypted messenger, after the inviter confirms who is joining.
struct PairingActivity: GroupActivity, Hashable, Sendable {
    static let activityIdentifier = "com.mikeroysoft.benito.pair-partner"

    /// Matches the server invite id; lets the inviting phone recognise the session it started.
    let inviteID: UUID
    let familyName: String
    let inviterName: String
    /// Inviter's server origin, for display only. The joiner gets every reachable address
    /// in the invite link itself.
    let serverURL: String

    /// Invites this phone has offered. Metadata is read on each device, so the
    /// sharing phone can title the activity "Share …" and the other phone "Join …".
    /// A set, not the latest id: the share sheet can hold an older activity than the page.
    private static let outgoingInviteIDs = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    static func markOutgoing(_ id: UUID) {
        outgoingInviteIDs.withLock { _ = $0.insert(id) }
    }

    static func isOutgoing(_ id: UUID) -> Bool {
        outgoingInviteIDs.withLock { $0.contains(id) }
    }

    /// "Share <name> Family" / "Join <name> Family". No surname when the name is blank.
    static func shareTitle(familyName: String) -> String {
        titled("Share", familyName: familyName)
    }

    static func joinTitle(familyName: String) -> String {
        titled("Join", familyName: familyName)
    }

    private static func titled(_ verb: String, familyName: String) -> String {
        let name = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "\(verb) Family" : "\(verb) \(name) Family"
    }

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        let sharing = Self.isOutgoing(inviteID)
        metadata.title = sharing ? Self.shareTitle(familyName: familyName) : Self.joinTitle(familyName: familyName)
        metadata.subtitle = "Benito invite from \(inviterName)"
        metadata.type = .generic
        // Pairing is not a lasting activity. If the phone that started it leaves, end it for both.
        metadata.lifetimePolicy = .endsWhenInitiatorLeaves
        return metadata
    }
}

/// What the inviter's `ShareLink` offers; the share sheet / AirDrop turns it into a SharePlay session.
struct PartnerInvite: Transferable, Sendable {
    let activity: PairingActivity

    static var transferRepresentation: some TransferRepresentation {
        GroupActivityTransferRepresentation { invite in invite.activity }
    }
}

/// Who is asking to join; shown to the inviter for confirmation. `email` is empty for
/// passwordless (device-key) joiners.
struct PairingIdentity: Codable, Hashable, Sendable {
    let name: String
    let email: String

    var displayName: String {
        if !name.isEmpty { return name }
        return email.isEmpty ? "Someone" : email
    }
}

/// Messages exchanged over `GroupSessionMessenger` during pairing.
enum PairingMessage: Codable, Sendable {
    /// Joiner → inviter, after the joiner confirms.
    case joinRequest(PairingIdentity)
    /// Inviter → joiner only, after the inviter confirms: the one-time `benito://join` link.
    case approvedInvite(url: String)
    /// Inviter → joiner.
    case declined
    /// Joiner → inviter: invite redeemed, now a family member.
    case joined
    /// Either side: pairing cannot continue; `reason` is phrased for the receiving phone.
    case failed(reason: String)
}
