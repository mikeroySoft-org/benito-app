import Foundation
import UIKit
import BenitoKit

/// Why joining or inviting stopped, phrased for the person holding the phone.
enum SharingError: LocalizedError {
    case expired
    case alreadyInFamily
    case unreachable(familyName: String)
    case notSignedIn
    case unsupportedServer
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .expired:
            "This invite has expired. Ask for a new one."
        case .alreadyInFamily:
            "This phone is already in a family. Leave it in Account first."
        case .unreachable(let familyName):
            "Can't reach the \(familyName) server. Join the same Wi-Fi as the family (or their Tailscale), then try again."
        case .notSignedIn:
            "Sign in first."
        case .unsupportedServer:
            "This Benito server needs an update before it can share without passwords."
        case .failed(let message):
            message
        }
    }
}

// MARK: - Device key (passwordless sign-in)

extension AppModel {
    private static let deviceIdsKey = "benito.deviceIds"
    private static let endpointsKey = "benito.endpoints"
    private static let serverIdKey = "benito.serverId"
    /// Stops a server that keeps rejecting fresh sessions from causing a reconnect loop.
    @MainActor private static var lastDeviceResume: Date?

    /// Passwordless people get a placeholder address; never show it.
    var isPasswordless: Bool { signedInEmail.hasSuffix("@device.benito.invalid") }

    /// Parents manage sharing. Servers that predate roles report none: treat as parent.
    var isParent: Bool { role != .caregiver }

    /// Name for the account row: the person's name, or their email for password accounts.
    var accountDisplayName: String {
        if !signedInName.isEmpty { return signedInName }
        return isPasswordless ? "This iPhone" : signedInEmail
    }

    static var deviceName: String { UIDevice.current.name }
    static var deviceModel: String { UIDevice.current.model }

    func storedDeviceId(for url: URL? = nil) -> String? {
        guard let url = url ?? serverBaseURL else { return nil }
        let map = UserDefaults.standard.dictionary(forKey: Self.deviceIdsKey) as? [String: String] ?? [:]
        return map[SessionTokenStoreKey.account(for: url)]
    }

    func storeDeviceId(_ id: String?, for url: URL) {
        var map = UserDefaults.standard.dictionary(forKey: Self.deviceIdsKey) as? [String: String] ?? [:]
        map[SessionTokenStoreKey.account(for: url)] = id
        UserDefaults.standard.set(map, forKey: Self.deviceIdsKey)
    }

    func forgetDeviceId() {
        guard let url = serverBaseURL else { return }
        storeDeviceId(nil, for: url)
    }

    /// Existing password accounts: attach this phone's key once, so the session can renew itself
    /// and the account keeps working if the password is ever forgotten.
    func ensureDeviceKey(serverSupportsKeys: Bool) async {
        guard serverSupportsKeys, let url = serverBaseURL, let api else { return }
        if storedDeviceId(for: url) == nil {
            do {
                let id = try await api.registerDevice(
                    identity: deviceIdentity,
                    deviceName: Self.deviceName,
                    model: Self.deviceModel
                )
                storeDeviceId(id, for: url)
                BenitoLog.ui.notice("device key registered")
            } catch {
                BenitoLog.ui.error("device key register failed: \(String(describing: error), privacy: .public)")
            }
        }
        if knownEndpoints.isEmpty, let info = try? await api.serverInfo() {
            rememberEndpoints([url] + info.advertisedUrls.compactMap(URL.init(string:)), serverId: info.serverId)
        }
    }

    /// Signs this phone's key for a fresh session (no prompt). False when there is no key for this
    /// server or the server said no.
    func resumeWithDeviceKey() async -> Bool {
        guard let url = serverBaseURL, let deviceId = storedDeviceId(for: url) else { return false }
        if let last = Self.lastDeviceResume, Date.now.timeIntervalSince(last) < 30 { return false }
        Self.lastDeviceResume = .now
        let created = APIClient(baseURL: url, clientId: clientId)
        do {
            let res = try await created.deviceSession(deviceId: deviceId, identity: deviceIdentity)
            try tokenStore.setToken(res.token, for: url)
            BenitoLog.ui.notice("device session resumed")
            return true
        } catch {
            BenitoLog.ui.error("device session failed: \(String(describing: error), privacy: .public)")
            if case .httpStatus(403, _)? = error as? APIClientError {
                // Removed from the family, or caregiver access ended. The key is no use here now.
                storeDeviceId(nil, for: url)
                status = "Your access to this family has ended. Ask a parent for a new invite."
            }
            return false
        }
    }
}

// MARK: - Server addresses (LAN + tailnet)

extension AppModel {
    /// Every address this server is known by, preferred first.
    var knownEndpoints: [URL] {
        (UserDefaults.standard.stringArray(forKey: Self.endpointsKey) ?? []).compactMap(URL.init(string:))
    }

    func rememberEndpoints(_ urls: [URL], serverId: String) {
        var seen = Set<String>()
        let origins = urls.map { SessionTokenStoreKey.account(for: $0) }.filter { seen.insert($0).inserted }
        UserDefaults.standard.set(origins, forKey: Self.endpointsKey)
        UserDefaults.standard.set(serverId, forKey: Self.serverIdKey)
    }

    /// The current address doesn't answer but another known one does (left home Wi-Fi, so use
    /// Tailscale; or back home). Moves the session over. True when the server address changed.
    func failOverIfUnreachable() async -> Bool {
        guard let current = serverBaseURL else { return false }
        let currentKey = SessionTokenStoreKey.account(for: current)
        let others = knownEndpoints.filter { SessionTokenStoreKey.account(for: $0) != currentKey }
        guard !others.isEmpty else { return false }
        if await Self.probe(current, timeout: 2) != nil { return false }
        let serverId = UserDefaults.standard.string(forKey: Self.serverIdKey)
        guard let next = await Self.firstReachable(others, serverId: serverId) else { return false }
        BenitoLog.ui.notice("server failover → \(SessionTokenStoreKey.account(for: next), privacy: .public)")
        if let token = try? tokenStore.token(for: current) {
            try? tokenStore.setToken(token, for: next)
        }
        if let deviceId = storedDeviceId(for: current) {
            storeDeviceId(deviceId, for: next)
        }
        await switchServer(to: next)
        return true
    }

    /// Points the app at `url` without touching the saved sessions for any server.
    func switchServer(to url: URL) async {
        let value = ServerURLField.normalized(url.absoluteString) ?? url.absoluteString
        guard value != serverURLString else { return }
        serverURLString = value
        try? await store.setPreference("server_url", value: value)
    }

    /// `GET /server/info` with a short timeout. Nil when unreachable or not a Benito server.
    nonisolated static func probe(_ base: URL, timeout: TimeInterval = 3) async -> ServerInfoDTO? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: base.appending(path: "server/info"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(ServerInfoDTO.self, from: data)
        } catch {
            return nil
        }
    }

    /// Probes all addresses at once; returns the earliest-listed one that answers as `serverId`.
    nonisolated static func firstReachable(_ endpoints: [URL], serverId: String?) async -> URL? {
        let hits = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, url) in endpoints.enumerated() {
                group.addTask {
                    guard let info = await probe(url) else { return (index, false) }
                    return (index, serverId == nil || info.serverId == serverId)
                }
            }
            var ok: [Int] = []
            for await (index, reachable) in group where reachable { ok.append(index) }
            return ok
        }
        return hits.min().map { endpoints[$0] }
    }
}

// MARK: - Onboarding: new family, join from an invite

extension AppModel {
    /// First run: a passwordless account on `server`, then the family. No email, no password.
    func startFamily(server: URL, yourName: String, familyName: String, childName: String) async throws {
        if isSignedIn { tearDownSession() }
        await switchServer(to: server)
        let created = APIClient(baseURL: server, clientId: clientId)
        let res: DeviceAuthResponseDTO
        do {
            res = try await created.deviceSignup(
                name: yourName,
                identity: deviceIdentity,
                deviceName: Self.deviceName,
                model: Self.deviceModel
            )
        } catch {
            if case .httpStatus(404, _)? = error as? APIClientError { throw SharingError.unsupportedServer }
            throw SharingError.failed(Self.message(for: error))
        }
        adoptSession(token: res.token, user: res.user, deviceId: res.deviceId, client: created, base: server)
        if let info = try? await created.serverInfo() {
            rememberEndpoints([server] + info.advertisedUrls.compactMap(URL.init(string:)), serverId: info.serverId)
        }
        self.familyName = familyName
        self.childName = childName
        await createFamily()
        guard hasFamily else { throw SharingError.failed(status) }
        role = .parent
    }

    /// Redeems an invite link: finds an address that answers (home Wi-Fi first, then tailnet),
    /// creates a passwordless account named `name` (or reuses this phone's family-less account
    /// on the same server) and joins the family.
    func join(with link: FamilyInviteLink, name: String) async throws {
        guard !link.isExpired else { throw SharingError.expired }
        if isSignedIn, hasFamily { throw SharingError.alreadyInFamily }

        var client: APIClient?
        var base: URL?
        if isSignedIn, let api, let current = serverBaseURL,
           await Self.probe(current)?.serverId == link.serverId {
            client = api
            base = current
        }
        if client == nil {
            guard let endpoint = await Self.firstReachable(link.endpoints, serverId: link.serverId) else {
                throw SharingError.unreachable(familyName: link.familyName)
            }
            if isSignedIn { tearDownSession() }
            client = APIClient(baseURL: endpoint, clientId: clientId)
            base = endpoint
        }
        guard let client, let base else { throw SharingError.notSignedIn }

        let res: RedeemInviteResponseDTO
        do {
            res = try await client.redeemInvite(
                link,
                name: name,
                identity: deviceIdentity,
                deviceName: Self.deviceName,
                model: Self.deviceModel
            )
        } catch {
            throw SharingError.failed(Self.message(for: error))
        }
        await switchServer(to: base)
        adoptSession(token: res.token, user: res.user, deviceId: res.deviceId, client: client, base: base)
        rememberEndpoints([base] + link.endpoints, serverId: link.serverId)
        hasFamily = true
        familyName = res.family.name
        role = res.role
        accessExpiresAt = res.accessExpiresAt
        status = "Joined \(res.family.name)"
        await refreshMe()
        connectSync()
        await flushOutbox()
    }

    private func adoptSession(token: String, user: UserDTO, deviceId: String, client: APIClient, base: URL) {
        do {
            try tokenStore.setToken(token, for: base)
        } catch {
            BenitoLog.ui.error("session token save failed: \(String(describing: error), privacy: .public)")
        }
        storeDeviceId(deviceId, for: base)
        api = client
        wireStateRefetcher(api: client)
        isSignedIn = true
        signedInEmail = user.email
        signedInName = user.name
        status = "Signed in"
    }
}

// MARK: - Account › Sharing

extension AppModel {
    /// The signed-in session's client. Unlike `client()`, never builds a tokenless one: a sharing
    /// call that races launch (session not restored yet) must not 401 and tear the session down.
    func sessionClient() throws -> APIClient {
        guard isSignedIn, let api else { throw SharingError.notSignedIn }
        return api
    }

    func refreshSharing() async throws {
        do {
            let c = try sessionClient()
            members = try await c.familyMembers()
            pendingInvites = isParent ? try await c.pendingInvites() : []
        } catch {
            if handleUnauthorized(error) { throw SharingError.notSignedIn }
            if case .httpStatus(404, _)? = error as? APIClientError { throw SharingError.unsupportedServer }
            throw SharingError.failed(Self.message(for: error))
        }
    }

    /// Mints a single-use invite and the link that carries it (Messages, AirDrop, SharePlay, QR).
    func makeInvite(role: FamilyRole, accessHours: Int?) async throws -> FamilyInviteLink {
        guard let current = serverBaseURL else { throw SharingError.notSignedIn }
        let dto: FamilyInviteDTO
        do {
            dto = try await sessionClient().createInvite(role: role, accessHours: role == .caregiver ? accessHours : nil)
        } catch {
            if handleUnauthorized(error) { throw SharingError.notSignedIn }
            if case .httpStatus(404, _)? = error as? APIClientError { throw SharingError.unsupportedServer }
            throw SharingError.failed(Self.message(for: error))
        }
        guard let link = FamilyInviteLink(invite: dto, currentServer: current) else {
            throw SharingError.failed("The server didn't return an invite.")
        }
        try? await refreshSharing()
        return link
    }

    func revokeInvite(_ invite: FamilyInviteDTO) async {
        do {
            try await sessionClient().revokeInvite(id: invite.id)
            pendingInvites.removeAll { $0.id == invite.id }
        } catch {
            if handleUnauthorized(error) { return }
            status = "Couldn't cancel invite: \(Self.message(for: error))"
        }
    }

    func removeMember(_ member: FamilyMemberDTO) async {
        do {
            try await sessionClient().removeMember(userId: member.userId)
            members.removeAll { $0.userId == member.userId }
        } catch {
            if handleUnauthorized(error) { return }
            status = "Couldn't remove \(member.name): \(Self.message(for: error))"
        }
    }

    /// Text that travels with the link in Messages / AirDrop.
    static func inviteMessage(for link: FamilyInviteLink) -> String {
        let expires = link.expiresAt.formatted(.relative(presentation: .named))
        let what = link.role == .caregiver ? "help look after the baby" : "share the baby log"
        return "\(link.inviterName) invited you to \(what) in \(link.familyName) on Benito. Open this link on your iPhone to join (expires \(expires)): \(link.url.absoluteString)"
    }
}

extension FamilyInviteLink: @retroactive Identifiable {
    public var id: String { inviteId }
}
