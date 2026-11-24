import Foundation

/// The parts of `tailscale serve status --json` this app reads. With nothing served it is `{}`.
struct TailscaleServeConfig: Decodable, Sendable, Equatable {
    /// Keyed by `<host>:<port>`.
    var web: [String: Site]?

    struct Site: Decodable, Sendable, Equatable {
        var handlers: [String: Handler]?

        enum CodingKeys: String, CodingKey {
            case handlers = "Handlers"
        }
    }

    struct Handler: Decodable, Sendable, Equatable {
        var proxy: String?

        enum CodingKeys: String, CodingKey {
            case proxy = "Proxy"
        }
    }

    enum CodingKeys: String, CodingKey {
        case web = "Web"
    }

    private static let httpsSuffix = ":443"

    /// What `/` on port 443 is forwarded to, by host, in a stable order.
    private var rootProxies: [(host: String, proxy: String)] {
        (web ?? [:])
            .sorted { $0.key < $1.key }
            .compactMap { key, site -> (host: String, proxy: String)? in
                guard key.hasSuffix(Self.httpsSuffix), let proxy = site.handlers?["/"]?.proxy else { return nil }
                return (String(key.dropLast(Self.httpsSuffix.count)), proxy)
            }
    }

    /// The tailnet host whose `/` on port 443 is forwarded to `http://127.0.0.1:<port>`.
    func host(forwardingToLoopbackPort port: Int) -> String? {
        rootProxies.first { Self.isLoopback($0.proxy, port: port) }?.host
    }

    /// Where port 443 goes today, for telling the person what Turn On would replace.
    var currentTarget: String? {
        rootProxies.first?.proxy
    }

    func state(forLoopbackPort port: Int) -> TailscaleServeState {
        host(forwardingToLoopbackPort: port).map { .forwarding(host: $0) } ?? .notForwarding
    }

    private static func isLoopback(_ proxy: String, port: Int) -> Bool {
        guard
            let components = URLComponents(string: proxy),
            components.scheme?.lowercased() == "http",
            let host = components.host?.lowercased()
        else { return false }
        return (host == "127.0.0.1" || host == "localhost") && (components.port ?? 80) == port
    }
}
