import Foundation

/// Everything a new phone needs to join a family, carried in one link:
/// `https://benito.mikeroysoft.com/join#p=<base64url JSON>`. Sent by Messages, AirDrop, QR or SharePlay.
///
/// With Benito installed the https link opens the app (universal link). Without it, the web page
/// (site/join) shows the invite and hands off to `benito://join?p=…`, which the app also accepts.
/// The payload sits after `#`, so it never reaches the web server.
///
/// The secret is single use and expires (72 h by default); the server only stores its hash.
public struct FamilyInviteLink: Codable, Sendable, Hashable {
    public static let scheme = "benito"
    public static let host = "join"
    /// Web home of invite links (site/ in this repo, served by GitHub Pages).
    public static let webHost = "benito.mikeroysoft.com"
    public static let webPath = "/join"
    public static let currentVersion = 1

    public var version: Int
    public var inviteId: String
    public var secret: String
    public var familyName: String
    public var inviterName: String
    public var role: FamilyRole
    public var expiresAt: Date
    public var serverId: String
    /// Server origins in the order a joiner should try them (LAN first, then tailnet / WAN).
    public var endpoints: [URL]

    public init(
        inviteId: String,
        secret: String,
        familyName: String,
        inviterName: String,
        role: FamilyRole,
        expiresAt: Date,
        serverId: String,
        endpoints: [URL]
    ) {
        self.version = Self.currentVersion
        self.inviteId = inviteId
        self.secret = secret
        self.familyName = familyName
        self.inviterName = inviterName
        self.role = role
        self.expiresAt = expiresAt
        self.serverId = serverId
        self.endpoints = endpoints
    }

    /// Builds the link from a freshly created invite, putting the inviter's current server first
    /// and de-duplicating by origin.
    public init?(invite: FamilyInviteDTO, currentServer: URL) {
        guard let secret = invite.secret else { return nil }
        var seen = Set<String>()
        var ordered: [URL] = []
        let advertised = invite.endpoints.compactMap(URL.init(string:))
        // LAN-looking origins first so a babysitter on home Wi-Fi never needs Tailscale.
        let lan = advertised.filter(Self.looksLocal)
        let rest = advertised.filter { !Self.looksLocal($0) }
        for url in lan + [currentServer] + rest {
            let key = SessionTokenStoreKey.account(for: url)
            if seen.insert(key).inserted, let origin = URL(string: key) {
                ordered.append(origin)
            }
        }
        self.init(
            inviteId: invite.id,
            secret: secret,
            familyName: invite.familyName,
            inviterName: invite.inviterName,
            role: invite.role,
            expiresAt: invite.expiresAt,
            serverId: invite.serverId,
            endpoints: ordered
        )
    }

    public var isExpired: Bool { expiresAt <= .now }

    /// The link people share: `https://benito.mikeroysoft.com/join#p=…`.
    public var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.webHost
        components.path = Self.webPath
        components.fragment = "p=" + Self.encodePayload(self)
        return components.url ?? appURL
    }

    /// `benito://join?p=…`: opens the app directly. Used between two phones that both run
    /// Benito (pairing), and by the web page's "Open in Benito" button.
    public var appURL: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [URLQueryItem(name: "p", value: Self.encodePayload(self))]
        return components.url!
    }

    /// Accepts the https link, the `benito://join?p=…` URL, or text containing either.
    public init?(url: URL) {
        guard let p = Self.payload(in: url), let decoded = Self.decodePayload(p) else { return nil }
        self = decoded
    }

    private static func payload(in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let queryP = components.queryItems?.first(where: { $0.name == "p" })?.value
        switch url.scheme?.lowercased() {
        case scheme?:
            return url.host?.lowercased() == host ? queryP : nil
        case "https":
            let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
            guard url.host?.lowercased() == webHost, path == webPath else { return nil }
            if let fragment = components.fragment, !fragment.isEmpty {
                var fragmentParts = URLComponents()
                fragmentParts.percentEncodedQuery = fragment
                return fragmentParts.queryItems?.first(where: { $0.name == "p" })?.value ?? fragment
            }
            return queryP
        default:
            return nil
        }
    }

    public init?(text: String) {
        let pattern = #"(benito://join\?p=|https://benito\.mikeroysoft\.com/join/?#p=)[A-Za-z0-9_\-]+"#
        guard
            let range = text.range(of: pattern, options: .regularExpression),
            let url = URL(string: String(text[range]))
        else { return nil }
        self.init(url: url)
    }

    /// Short keys keep the link (and QR code) small.
    enum CodingKeys: String, CodingKey {
        case version = "v"
        case inviteId = "i"
        case secret = "s"
        case familyName = "f"
        case inviterName = "by"
        case role = "r"
        case expiresAt = "x"
        case serverId = "sid"
        case endpoints = "e"
    }

    static func encodePayload(_ link: FamilyInviteLink) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(link)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodePayload(_ payload: String) -> FamilyInviteLink? {
        var b64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let link = try? decoder.decode(FamilyInviteLink.self, from: data),
              link.version <= Self.currentVersion,
              !link.endpoints.isEmpty
        else { return nil }
        return link
    }

    /// `.local`, RFC 1918 and link-local hosts.
    public static func looksLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
