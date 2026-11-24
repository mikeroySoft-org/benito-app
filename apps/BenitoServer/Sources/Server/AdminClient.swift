import BenitoKit
import Foundation

/// Talks to the loopback admin API of a running `benito-server`.
///
/// The token changes on every server start, so a 401 or a refused connection means the cached
/// `admin.json` may be stale: it is read again, and the request is repeated only when the file
/// names a different server process (so a request is never delivered twice to the same one).
actor AdminClient {
    private static let defaultTimeout: TimeInterval = 5
    /// A snapshot of a large database takes longer than a status call.
    private static let backupTimeout: TimeInterval = 300
    private static let legacyProbeTimeout: TimeInterval = 2

    private let home: ServerHome
    private let session: URLSession
    private var handoff: AdminHandoff?

    init(home: ServerHome) {
        self.home = home
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.defaultTimeout
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    // MARK: - Routes

    func status() async throws -> ServerStatus {
        try await get("/admin/status")
    }

    func glance() async throws -> [ChildGlance] {
        struct Response: Decodable { var children: [ChildGlance] }
        let response: Response = try await get("/admin/glance")
        return response.children
    }

    func people() async throws -> [AdminFamily] {
        struct Response: Decodable { var families: [AdminFamily] }
        let response: Response = try await get("/admin/people")
        return response.families
    }

    func createInvite(_ request: InviteRequest) async throws -> FamilyInviteDTO {
        let body = try BenitoJSON.encoder.encode(request)
        return try decode(await send("POST", "/admin/invites", body: body))
    }

    func revokeInvite(id: String) async throws {
        _ = try await send("DELETE", "/admin/invites/\(Self.segment(id))")
    }

    func revokeDevice(id: String) async throws {
        _ = try await send("DELETE", "/admin/devices/\(Self.segment(id))")
    }

    func removeMember(familyID: String, userID: String) async throws {
        _ = try await send(
            "DELETE",
            "/admin/families/\(Self.segment(familyID))/members/\(Self.segment(userID))"
        )
    }

    func backups() async throws -> BackupList {
        try await get("/admin/backups")
    }

    func createBackup() async throws -> BackupResult {
        try decode(await send("POST", "/admin/backups", timeout: Self.backupTimeout))
    }

    /// Asks port 8080 whether a server without the admin API is running. `nil` when this home
    /// does not probe, nothing answers, or the answer is not a Benito server.
    func legacyHealth() async -> LegacyHealth? {
        guard let url = home.legacyHealthURL else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.legacyProbeTimeout
        guard
            let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let health = try? JSONDecoder().decode(LegacyHealth.self, from: data),
            health.service == LegacyHealth.expectedService
        else { return nil }
        return health
    }

    // MARK: - Transport

    func get<Response: Decodable>(_ path: String) async throws -> Response {
        try decode(await send("GET", path))
    }

    func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try BenitoJSON.decoder.decode(Response.self, from: data)
        } catch {
            throw AdminError.invalidResponse(String(describing: error))
        }
    }

    func send(
        _ method: String,
        _ path: String,
        body: Data? = nil,
        timeout: TimeInterval = AdminClient.defaultTimeout
    ) async throws -> Data {
        let cached = handoff
        if let cached {
            do {
                return try await perform(method, path, body: body, timeout: timeout, using: cached)
            } catch let error as AdminError where error.suggestsStaleHandoff {
                let fresh = try readHandoff()
                guard fresh != cached else { throw error }
                handoff = fresh
                return try await perform(method, path, body: body, timeout: timeout, using: fresh)
            }
        }
        let fresh = try readHandoff()
        handoff = fresh
        return try await perform(method, path, body: body, timeout: timeout, using: fresh)
    }

    private func readHandoff() throws -> AdminHandoff {
        let data: Data
        do {
            data = try Data(contentsOf: home.adminFile)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            handoff = nil
            throw AdminError.handoffMissing
        } catch {
            handoff = nil
            throw AdminError.handoffUnreadable(error.localizedDescription)
        }
        do {
            return try BenitoJSON.decoder.decode(AdminHandoff.self, from: data)
        } catch {
            handoff = nil
            throw AdminError.handoffUnreadable("it is not a valid admin.json")
        }
    }

    private func perform(
        _ method: String,
        _ path: String,
        body: Data?,
        timeout: TimeInterval,
        using handoff: AdminHandoff
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: handoff.url) else {
            throw AdminError.invalidResponse("bad admin URL \(handoff.url.absoluteString)\(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(handoff.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where Self.connectionFailureCodes.contains(error.code) {
            throw AdminError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AdminError.invalidResponse("not an HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw AdminError.unauthorized
        default:
            struct ErrorBody: Decodable { var error: String }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw AdminError.server(
                status: http.statusCode,
                message: message ?? "The server answered with HTTP \(http.statusCode)."
            )
        }
    }

    private static let connectionFailureCodes: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut,
        .notConnectedToInternet, .dnsLookupFailed, .badServerResponse,
    ]

    private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }
}
