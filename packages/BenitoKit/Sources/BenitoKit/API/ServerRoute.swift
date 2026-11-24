import Foundation

/// Which address of the family's server the app is talking to right now.
/// The saved Server URL is the primary; a fallback is another address of the *same* server
/// (matching `server_id`), used only while the primary doesn't answer.
public enum ServerRoute: Equatable, Sendable {
    case primary(URL)
    case fallback(URL)

    public var url: URL {
        switch self {
        case .primary(let url), .fallback(let url): url
        }
    }

    /// How the status line names a fallback ("home network"); nil on the primary.
    public var label: String? {
        guard case .fallback(let url) = self else { return nil }
        let host = url.host() ?? url.absoluteString
        return Self.isHomeNetwork(host) ? "home network" : host
    }

    /// Only "couldn't reach it" moves to another address. Any HTTP answer (401, 403, 500)
    /// came from the server, so another route would get the same answer.
    public static func isUnreachable(_ error: Error) -> Bool {
        switch error {
        case APIClientError.transport: true
        case is URLError: true
        default: false
        }
    }

    /// Primary first. When it doesn't answer, the first candidate that answers as `serverId`;
    /// a server with another id (or an id never learned) is never used. Nothing answers: stay on
    /// the primary, offline. `candidates` is only asked for when the primary is down.
    public static func choose(
        primary: URL,
        candidates: () async -> [URL],
        serverId: String?,
        probe: (URL) async -> ServerInfoDTO?
    ) async -> ServerRouteChoice {
        if let info = await probe(primary) {
            return ServerRouteChoice(route: .primary(primary), primaryInfo: info)
        }
        guard let serverId else { return ServerRouteChoice(route: .primary(primary), primaryInfo: nil) }
        let primaryKey = SessionTokenStoreKey.account(for: primary)
        for url in await candidates() where SessionTokenStoreKey.account(for: url) != primaryKey {
            if await probe(url)?.serverId == serverId {
                return ServerRouteChoice(route: .fallback(url), primaryInfo: nil)
            }
        }
        return ServerRouteChoice(route: .primary(primary), primaryInfo: nil)
    }

    private static func isHomeNetwork(_ host: String) -> Bool {
        if host.hasSuffix(".local") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}

/// `primaryInfo` is the primary's `/server/info` when it answered, so callers can learn its
/// other addresses and identity for the next fallback.
public struct ServerRouteChoice: Sendable {
    public let route: ServerRoute
    public let primaryInfo: ServerInfoDTO?
}
