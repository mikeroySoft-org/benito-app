import Foundation

/// Passwordless device auth, family members and invites (server ≥ 0.x with migration 006).
extension APIClient {
    private struct DeviceKeyBody: Encodable {
        let public_key: String
        let device_name: String
        let model: String?
    }

    public func serverInfo() async throws -> ServerInfoDTO {
        try decode(await get(path: "/server/info"))
    }

    /// Creates a passwordless account bound to `identity` and signs in.
    public func deviceSignup(
        name: String,
        identity: any DeviceIdentity,
        deviceName: String,
        model: String?
    ) async throws -> DeviceAuthResponseDTO {
        struct Body: Encodable {
            let name: String
            let public_key: String
            let device_name: String
            let model: String?
        }
        let body = Body(name: name, public_key: try identity.publicKeyBase64(), device_name: deviceName, model: model)
        let res: DeviceAuthResponseDTO = try decode(await post(path: "/auth/device/signup", json: body))
        token = res.token
        return res
    }

    /// Exchanges a fresh signature for a bearer session (no password, no prompt).
    public func deviceSession(deviceId: String, identity: any DeviceIdentity) async throws -> DeviceAuthResponseDTO {
        struct Body: Encodable {
            let device_id: String
            let timestamp: Int
            let signature: String
        }
        let ts = Int(Date.now.timeIntervalSince1970)
        let signature = try identity.sign(DeviceAuthMessage.make(deviceId: deviceId, timestamp: ts))
        let res: DeviceAuthResponseDTO = try decode(
            await post(path: "/auth/device/session", json: Body(device_id: deviceId, timestamp: ts, signature: signature))
        )
        token = res.token
        return res
    }

    /// Attaches this phone's key to the signed-in (password) account. Idempotent.
    @discardableResult
    public func registerDevice(identity: any DeviceIdentity, deviceName: String, model: String?) async throws -> String {
        struct Res: Decodable { let device_id: String }
        let body = DeviceKeyBody(public_key: try identity.publicKeyBase64(), device_name: deviceName, model: model)
        let res: Res = try decode(await post(path: "/devices", json: body))
        return res.device_id
    }

    public func familyMembers() async throws -> [FamilyMemberDTO] {
        try decode(await get(path: "/families/members"))
    }

    public func removeMember(userId: String) async throws {
        _ = try await delete(path: "/families/members/\(userId)")
    }

    public func createInvite(role: FamilyRole, accessHours: Int? = nil, expiresInHours: Int? = nil) async throws -> FamilyInviteDTO {
        struct Body: Encodable {
            let role: String
            let access_hours: Int?
            let expires_in_hours: Int?
        }
        return try decode(
            await post(
                path: "/families/invites",
                json: Body(role: role.rawValue, access_hours: accessHours, expires_in_hours: expiresInHours)
            )
        )
    }

    public func pendingInvites() async throws -> [FamilyInviteDTO] {
        try decode(await get(path: "/families/invites"))
    }

    public func revokeInvite(id: String) async throws {
        _ = try await delete(path: "/families/invites/\(id)")
    }

    /// Joins the invite's family. Sends the current bearer token when there is one (an existing
    /// account without a family); otherwise creates a passwordless account named `name`.
    public func redeemInvite(
        _ link: FamilyInviteLink,
        name: String,
        identity: any DeviceIdentity,
        deviceName: String,
        model: String?
    ) async throws -> RedeemInviteResponseDTO {
        struct Body: Encodable {
            let invite_id: String
            let secret: String
            let name: String
            let public_key: String
            let device_name: String
            let model: String?
        }
        let body = Body(
            invite_id: link.inviteId,
            secret: link.secret,
            name: name,
            public_key: try identity.publicKeyBase64(),
            device_name: deviceName,
            model: model
        )
        let res: RedeemInviteResponseDTO = try decode(await post(path: "/invites/redeem", json: body))
        token = res.token
        return res
    }
}
