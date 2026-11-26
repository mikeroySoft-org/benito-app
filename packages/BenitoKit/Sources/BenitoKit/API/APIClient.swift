import Foundation
import OSLog

public enum APIClientError: Error, Sendable, LocalizedError {
    case invalidURL
    case httpStatus(Int, Data?)
    case decoding(Error)
    case transport(Error)

    /// Prefer server `{"error":"..."}` when present; otherwise UTF-8 body or status only.
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "invalidURL"
        case .httpStatus(let code, let data):
            if let data, !data.isEmpty {
                if let msg = Self.serverErrorMessage(from: data) {
                    return "httpStatus \(code): \(msg)"
                }
                if let body = String(data: data, encoding: .utf8), !body.isEmpty {
                    return "httpStatus \(code): \(body)"
                }
            }
            return "httpStatus \(code)"
        case .decoding(let error):
            return "decoding: \(error.localizedDescription)"
        case .transport(let error):
            return "transport: \(error.localizedDescription)"
        }
    }

    public static func serverErrorMessage(from data: Data) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let err = obj["error"] as? String,
            !err.isEmpty
        else { return nil }
        return err
    }
}

/// HTTP client for benito-server (v1a).
public actor APIClient {
    public var baseURL: URL
    public var token: String?
    /// Optional stable id sent as `X-Client-Id` so WS peers can de-dupe.
    public var clientId: String

    public init(baseURL: URL, token: String? = nil, clientId: String = UUID().uuidString) {
        self.baseURL = baseURL
        self.token = token
        self.clientId = clientId
    }

    // MARK: - Auth / family

    public func health() async throws -> [String: String] {
        let data = try await get(path: "/health")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return obj.mapValues { "\($0)" }
    }

    public func register(name: String, email: String, password: String) async throws -> AuthResponseDTO {
        let body = ["name": name, "email": email, "password": password]
        let data = try await post(path: "/auth/register", json: body)
        let res: AuthResponseDTO = try decode(data)
        token = res.token
        return res
    }

    public func login(email: String, password: String) async throws -> AuthResponseDTO {
        let body = ["email": email, "password": password]
        let data = try await post(path: "/auth/login", json: body)
        let res: AuthResponseDTO = try decode(data)
        token = res.token
        return res
    }

    public func me() async throws -> MeResponseDTO {
        try decode(await get(path: "/me"))
    }

    public func createFamily(
        name: String,
        childName: String,
        childBirthdate: String? = nil,
        childSex: String? = nil
    ) async throws -> CreateFamilyResponseDTO {
        struct Body: Encodable {
            let name: String
            let child_name: String
            let child_birthdate: String?
            let child_sex: String?
        }
        let data = try await post(
            path: "/families",
            json: Body(name: name, child_name: childName, child_birthdate: childBirthdate, child_sex: childSex)
        )
        return try decode(data)
    }

    public func joinFamily(inviteCode: String) async throws -> FamilyDTO {
        struct Body: Encodable { let invite_code: String }
        let data = try await post(path: "/families/join", json: Body(invite_code: inviteCode))
        return try decode(data)
    }

    /// Mints a short-lived, single-use pairing token for the caller's family.
    public func createPairingToken() async throws -> PairingTokenDTO {
        try decode(await postEmpty(path: "/families/pairing-tokens"))
    }

    /// Redeems a pairing token minted by a family member; joins that family.
    public func pair(token: String) async throws -> FamilyDTO {
        struct Body: Encodable { let token: String }
        return try decode(await post(path: "/families/pair", json: Body(token: token)))
    }

    /// Removes the caller from their family so they can create or join another.
    public func leaveFamily() async throws {
        _ = try await postEmpty(path: "/families/leave")
    }

    /// Deletes the caller's account on the server; the session token stops working.
    /// Servers older than `DELETE /me` answer 404 or 405.
    public func deleteAccount() async throws {
        _ = try await delete(path: "/me")
    }

    public func listChildren() async throws -> [ChildDTO] {
        try decode(await get(path: "/children"))
    }

    public func createChild(name: String, birthdate: String? = nil, sex: String? = nil) async throws -> ChildDTO {
        struct Body: Encodable {
            let name: String
            let birthdate: String?
            let sex: String?
        }
        let data = try await post(path: "/children", json: Body(name: name, birthdate: birthdate, sex: sex))
        return try decode(data)
    }

    // MARK: - Events / timers / state / export

    public func createEvent(_ request: CreateEventRequestDTO) async throws -> EventDTO {
        try decode(await post(path: "/events", json: request))
    }

    /// `PATCH /events/{id}`; only non-nil fields in `changes` are sent.
    public func updateEvent(id: UUID, _ changes: UpdateEventRequestDTO) async throws -> EventDTO {
        try decode(await patch(path: "/events/\(id.uuidString)", json: changes))
    }

    public func deleteEvent(id: UUID) async throws {
        _ = try await delete(path: "/events/\(id.uuidString)")
    }

    public func timeline(childId: UUID? = nil, limit: Int? = nil) async throws -> [EventDTO] {
        var parts: [String] = []
        if let childId { parts.append("child_id=\(childId.uuidString)") }
        if let limit { parts.append("limit=\(limit)") }
        let q = parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
        return try decode(await get(path: "/timeline\(q)"))
    }

    public func state(childId: UUID) async throws -> BabyStateDTO {
        try decode(await get(path: "/state?child_id=\(childId.uuidString)"))
    }

    /// Change feed: events (tombstones included) whose `updated_at` is strictly after `since`,
    /// ordered `updated_at ASC`. Drives `CatchUpSync`.
    public func eventChanges(childId: UUID, since: Date, limit: Int) async throws -> [EventDTO] {
        var comps = URLComponents()
        comps.path = "/events"
        comps.queryItems = [
            URLQueryItem(name: "child_id", value: childId.uuidString),
            URLQueryItem(name: "since", value: BenitoJSON.string(from: since)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        // URLComponents leaves `+` literal in queries; servers decode it as a space, which would
        // corrupt a `+00:00` offset.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let path = comps.string ?? "/events"
        return try decode(await get(path: path))
    }

    public func startTimer(childId: UUID, kind: String, side: String? = nil, at: Date = Date()) async throws -> TimerDTO {
        struct Body: Encodable {
            let child_id: UUID
            let kind: String
            let side: String?
            let at: Date
        }
        // Phone wall clock is the timer authority; server stores `at` as `started_at`.
        return try decode(await post(path: "/timers", json: Body(child_id: childId, kind: kind, side: side, at: at)))
    }

    /// Same server, another address (`ServerRoute`): the session token stays valid.
    public func route(to url: URL) {
        baseURL = url
    }

    public func stopTimer(id: UUID, at: Date = Date()) async throws -> TimerDTO {
        struct Body: Encodable { let at: Date }
        return try decode(await post(path: "/timers/\(id.uuidString)/stop", json: Body(at: at)))
    }

    public func pauseTimer(id: UUID, at: Date = Date()) async throws -> TimerDTO {
        struct Body: Encodable { let at: Date }
        return try decode(await post(path: "/timers/\(id.uuidString)/pause", json: Body(at: at)))
    }

    public func resumeTimer(id: UUID, at: Date = Date()) async throws -> TimerDTO {
        struct Body: Encodable { let at: Date }
        return try decode(await post(path: "/timers/\(id.uuidString)/resume", json: Body(at: at)))
    }

    /// `PATCH /timers/{id}`: move an active (running or paused) timer's start time.
    /// `at` is the phone's "now" so future/24h checks use the same clock as `startedAt`.
    public func adjustTimerStart(id: UUID, startedAt: Date, at: Date = Date()) async throws -> TimerDTO {
        struct Body: Encodable {
            let started_at: Date
            let at: Date
        }
        return try decode(await patch(path: "/timers/\(id.uuidString)", json: Body(started_at: startedAt, at: at)))
    }

    public func listTimers(childId: UUID? = nil) async throws -> [TimerDTO] {
        var path = "/timers"
        if let childId { path += "?child_id=\(childId.uuidString)" }
        return try decode(await get(path: path))
    }

    public func exportBundle() async throws -> ExportBundleDTO {
        try decode(await get(path: "/export"))
    }

    public func dailySummary(childId: UUID, day: String? = nil, from: Date? = nil, to: Date? = nil) async throws -> DailySummaryDTO {
        var items: [URLQueryItem] = [URLQueryItem(name: "child_id", value: childId.uuidString)]
        if let day { items.append(URLQueryItem(name: "day", value: day)) }
        if let from {
            items.append(URLQueryItem(name: "from", value: BenitoJSON.string(from: from)))
        }
        if let to {
            items.append(URLQueryItem(name: "to", value: BenitoJSON.string(from: to)))
        }
        var comps = URLComponents()
        comps.path = "/summary/daily"
        comps.queryItems = items
        // Same + → %2B fix as eventChanges (RFC3339 offsets).
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let path = comps.string ?? "/summary/daily"
        return try decode(await get(path: path))
    }

    public func rotateInvite() async throws -> FamilyDTO {
        try decode(await postEmpty(path: "/families/invite/rotate"))
    }

    // MARK: - Live Activity push tokens (ActivityKit update tokens)

    /// Registers this device's ActivityKit update push token for family `end` fan-out.
    /// Pass `apnsEnv` from `ApnsEnvironment.current` (sandbox or production).
    public func registerLiveActivityToken(
        token: String,
        apnsEnv: String,
        activityId: String? = nil
    ) async throws {
        struct Body: Encodable {
            let token: String
            let apns_env: String
            let activity_id: String?
        }
        _ = try await post(
            path: "/live-activity/tokens",
            json: Body(token: token, apns_env: apnsEnv, activity_id: activityId)
        )
    }

    /// Deletes Live Activity tokens for this `X-Client-Id` (call on sign-out).
    public func deleteLiveActivityTokens() async throws {
        _ = try await delete(path: "/live-activity/tokens")
    }

    public func exportCSV() async throws -> Data {
        try await get(path: "/export.csv")
    }


    /// Replay an outbox row (method + path + optional JSON body).
    @discardableResult
    public func rawRequest(method: String, path: String, body: Data?) async throws -> Data {
        try await request(method: method, path: path, body: body)
    }

    // MARK: - HTTP

    func get(path: String) async throws -> Data {
        try await request(method: "GET", path: path, body: nil)
    }

    func post(path: String, json: some Encodable) async throws -> Data {
        let body = try BenitoJSON.encoder.encode(json)
        return try await request(method: "POST", path: path, body: body)
    }

    func postEmpty(path: String) async throws -> Data {
        try await request(method: "POST", path: path, body: nil)
    }

    func patch(path: String, json: some Encodable) async throws -> Data {
        let body = try BenitoJSON.encoder.encode(json)
        return try await request(method: "PATCH", path: path, body: body)
    }

    func delete(path: String) async throws -> Data {
        try await request(method: "DELETE", path: path, body: nil)
    }

    private func request(method: String, path: String, body: Data?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            BenitoLog.api.error("invalidURL \(method, privacy: .public) \(path, privacy: .public)")
            throw APIClientError.invalidURL
        }
        BenitoLog.api.notice("\(method, privacy: .public) \(path, privacy: .public)")
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                BenitoLog.api.error("non-HTTP response \(method, privacy: .public) \(path, privacy: .public)")
                throw APIClientError.httpStatus(-1, data)
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyText = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
                BenitoLog.api.error("HTTP \(http.statusCode, privacy: .public) \(method, privacy: .public) \(path, privacy: .public) body=\(bodyText, privacy: .public)")
                throw APIClientError.httpStatus(http.statusCode, data)
            }
            return data
        } catch let error as APIClientError {
            throw error
        } catch {
            BenitoLog.api.error("transport \(method, privacy: .public) \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw APIClientError.transport(error)
        }
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try BenitoJSON.decoder.decode(T.self, from: data)
        } catch {
            throw APIClientError.decoding(error)
        }
    }
}
