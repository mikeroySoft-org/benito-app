import Foundation
import Network
import Observation

/// Finds Benito servers on this Wi-Fi (`_benito._tcp`, advertised by the server's LAN
/// listener) and resolves each to a plain `http://ip:port` the app can use.
@MainActor
@Observable
final class ServerBrowser {
    struct Found: Identifiable, Hashable {
        let name: String
        let url: URL
        var id: String { url.absoluteString }
    }

    private(set) var found: [Found] = []
    private(set) var isSearching = false

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var resolving: [String: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_benito._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.update(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.isSearching = true
                case .failed, .cancelled: self?.isSearching = false
                default: break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Browses briefly and returns what resolved in time (empty when nothing answers).
    static func discover(for duration: Duration = .seconds(1.5)) async -> [URL] {
        let browser = ServerBrowser()
        browser.start()
        try? await Task.sleep(for: duration)
        browser.stop()
        return browser.found.map(\.url)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving = [:]
        isSearching = false
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint,
                  resolving[name] == nil,
                  !found.contains(where: { $0.name == name }) else { continue }
            resolve(name: name, endpoint: result.endpoint)
        }
    }

    /// Connect once to learn the service's IPv4 address; IPv6 link-local URLs aren't usable in URLSession.
    private func resolve(name: String, endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: params)
        resolving[name] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                let remote = connection.currentPath?.remoteEndpoint
                connection.cancel()
                Task { @MainActor in self?.resolved(name: name, remote: remote) }
            case .failed, .waiting:
                connection.cancel()
                Task { @MainActor in self?.resolving[name] = nil }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func resolved(name: String, remote: NWEndpoint?) {
        resolving[name] = nil
        guard case let .hostPort(host, port)? = remote else { return }
        let hostString: String
        switch host {
        case .ipv4(let address): hostString = "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .name(let value, _): hostString = value
        default: return
        }
        guard let url = URL(string: "http://\(hostString):\(port.rawValue)"),
              !found.contains(where: { $0.url == url }) else { return }
        found.append(Found(name: name, url: url))
    }
}
