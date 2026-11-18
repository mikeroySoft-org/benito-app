import BenitoKit
import Foundation

/// Body of `POST /admin/invites`. Absent fields take the server's defaults.
struct InviteRequest: Encodable, Sendable {
    var familyId: String?
    var role: FamilyRole
    var expiresInHours: Int?
    var accessHours: Int?
    var label: String?

    enum CodingKeys: String, CodingKey {
        case role, label
        case familyId = "family_id"
        case expiresInHours = "expires_in_hours"
        case accessHours = "access_hours"
    }
}
