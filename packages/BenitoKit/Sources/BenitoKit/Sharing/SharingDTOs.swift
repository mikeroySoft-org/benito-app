import Foundation

/// Family membership role. `caregiver` logs everything but can't manage sharing and may have
/// an access end date.
public enum FamilyRole: String, Codable, Sendable, CaseIterable, Identifiable {
    case parent
    case caregiver

    public var id: String { rawValue }
}

/// `POST /auth/device/signup` and `POST /auth/device/session`.
public struct DeviceAuthResponseDTO: Codable, Sendable {
    public var token: String
    public var user: UserDTO
    public var deviceId: String

    enum CodingKeys: String, CodingKey {
        case token, user
        case deviceId = "device_id"
    }
}

public struct MemberDeviceDTO: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var model: String?
    public var createdAt: Date
    public var lastSeenAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, model
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

/// One row in Account › Sharing.
public struct FamilyMemberDTO: Codable, Sendable, Hashable, Identifiable {
    public var userId: String
    public var name: String
    /// Real email for password accounts; `nil` for passwordless (device-key) people.
    public var email: String?
    public var role: FamilyRole
    public var joinedAt: Date
    public var accessExpiresAt: Date?
    public var lastSeenAt: Date?
    public var isYou: Bool
    public var devices: [MemberDeviceDTO]

    public var id: String { userId }

    public init(
        userId: String,
        name: String,
        email: String? = nil,
        role: FamilyRole,
        joinedAt: Date,
        accessExpiresAt: Date? = nil,
        lastSeenAt: Date? = nil,
        isYou: Bool = false,
        devices: [MemberDeviceDTO] = []
    ) {
        self.userId = userId
        self.name = name
        self.email = email
        self.role = role
        self.joinedAt = joinedAt
        self.accessExpiresAt = accessExpiresAt
        self.lastSeenAt = lastSeenAt
        self.isYou = isYou
        self.devices = devices
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case name, email, role, devices
        case joinedAt = "joined_at"
        case accessExpiresAt = "access_expires_at"
        case lastSeenAt = "last_seen_at"
        case isYou = "is_you"
    }
}

/// `POST /families/invites` (with `secret`) and `GET /families/invites` (without).
public struct FamilyInviteDTO: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var secret: String?
    public var familyId: String
    public var familyName: String
    public var inviterName: String
    public var role: FamilyRole
    public var accessHours: Int?
    public var label: String?
    public var createdAt: Date
    public var expiresAt: Date
    public var serverId: String
    public var endpoints: [String]

    enum CodingKeys: String, CodingKey {
        case id, secret, role, label, endpoints
        case familyId = "family_id"
        case familyName = "family_name"
        case inviterName = "inviter_name"
        case accessHours = "access_hours"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case serverId = "server_id"
    }
}

/// `POST /invites/redeem`.
public struct RedeemInviteResponseDTO: Codable, Sendable {
    public var token: String
    public var user: UserDTO
    public var deviceId: String
    public var family: FamilyDTO
    public var role: FamilyRole
    public var accessExpiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case token, user, family, role
        case deviceId = "device_id"
        case accessExpiresAt = "access_expires_at"
    }
}

/// `GET /server/info`.
public struct ServerInfoDTO: Codable, Sendable {
    public var service: String
    public var version: String
    public var serverId: String
    public var advertisedUrls: [String]
    public var features: [String]

    enum CodingKeys: String, CodingKey {
        case service, version, features
        case serverId = "server_id"
        case advertisedUrls = "advertised_urls"
    }
}
