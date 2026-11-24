import Foundation

/// What Apply would write to `benito.env` for the choices in the Connections pane.
struct ConnectionPlan: Equatable, Sendable {
    /// Only the keys whose value differs from the file. `nil` removes the key.
    var changes: [String: String?] = [:]
    /// One plain sentence per change, in a fixed order.
    var summary: [String] = []
    /// Why the choices cannot be applied as entered.
    var problem: String?

    static func make(
        draft: ConnectionDraft,
        settings: [String: String],
        publicPort: Int,
        lanPort: LanPortCheck,
        lanAddress: String?,
        tailscale: TailscaleServeState
    ) -> ConnectionPlan {
        var desired: [String: String?] = [:]
        var lanURL: String?
        let loopback = "127.0.0.1:\(publicPort)"

        if draft.wifiEnabled {
            let port: Int
            switch lanPort {
            case .valid(let value): port = value
            case .invalid(let reason): return ConnectionPlan(problem: reason)
            }
            guard let lanAddress else {
                return ConnectionPlan(problem: "This Mac has no home network address right now. Connect it to Wi-Fi or Ethernet, then come back.")
            }
            let name = draft.bonjourName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                return ConnectionPlan(problem: "Enter the name phones should see for this server.")
            }
            lanURL = "http://\(lanAddress):\(port)"
            desired["BIND_ADDR"] = "\(loopback),0.0.0.0:\(port)"
            desired["BENITO_LAN_PORT"] = String(port)
            desired["BENITO_BONJOUR_NAME"] = name
            desired["BENITO_BONJOUR"] = .some(nil)
        } else {
            desired["BIND_ADDR"] = loopback
            desired["BENITO_LAN_PORT"] = .some(nil)
        }

        let addresses = publicURLs(
            existing: AdvertisedAddress.list(from: settings["BENITO_PUBLIC_URLS"]),
            lanURL: lanURL,
            tailscale: tailscale
        )
        let advertised: String? = addresses.isEmpty ? nil : addresses.joined(separator: ",")
        desired["BENITO_PUBLIC_URLS"] = .some(advertised)

        let changes = desired.filter { settings[$0.key] != $0.value }
        return ConnectionPlan(
            changes: changes,
            summary: summary(of: changes, wifiEnabled: draft.wifiEnabled, addresses: addresses)
        )
    }

    /// Home network address first, then the Tailscale name, then whatever else was there that
    /// this app did not write (a custom domain, for example).
    static func publicURLs(
        existing: [String],
        lanURL: String?,
        tailscale: TailscaleServeState
    ) -> [String] {
        var result: [String] = []
        if let lanURL {
            result.append(lanURL)
        }
        if case .forwarding(let host) = tailscale {
            result.append("https://\(host)")
        }
        for address in existing where !result.contains(address) {
            if AdvertisedAddress.lanHost(of: address) != nil { continue }
            if AdvertisedAddress.isTailnet(address), tailscale != .unknown { continue }
            result.append(address)
        }
        return result
    }

    private static func summary(
        of changes: [String: String?],
        wifiEnabled: Bool,
        addresses: [String]
    ) -> [String] {
        var lines: [String] = []
        if let listeners = changes["BIND_ADDR"] ?? nil {
            lines.append(wifiEnabled
                ? "The server also listens for phones on your home Wi-Fi (\(listeners))."
                : "The server stops listening on your home Wi-Fi and only answers on this Mac (\(listeners)).")
        }
        if let port = changes["BENITO_LAN_PORT"] {
            lines.append(port.map { "The home Wi-Fi port is saved as \($0)." }
                ?? "The saved home Wi-Fi port is cleared.")
        }
        if let name = changes["BENITO_BONJOUR_NAME"] ?? nil {
            lines.append("Phones on your Wi-Fi see this server as “\(name)”.")
        }
        if changes["BENITO_BONJOUR"] != nil {
            lines.append("Announcing the server on your Wi-Fi is turned back on, so phones can find it.")
        }
        if changes["BENITO_PUBLIC_URLS"] != nil {
            lines.append(addresses.isEmpty
                ? "Invites no longer carry a saved address."
                : "Invites give phones these addresses, in this order: \(addresses.joined(separator: ", ")).")
        }
        return lines
    }
}
