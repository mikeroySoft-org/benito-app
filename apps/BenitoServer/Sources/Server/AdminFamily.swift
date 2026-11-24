import BenitoKit
import Foundation

/// One family in `GET /admin/people`.
struct AdminFamily: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var createdAt: Date
    var children: [Child]
    var members: [FamilyMemberDTO]
    var invites: [FamilyInviteDTO]

    struct Child: Decodable, Sendable, Hashable, Identifiable {
        var id: String
        var name: String
    }

    enum CodingKeys: String, CodingKey {
        case id, name, children, members, invites
        case createdAt = "created_at"
    }
}
