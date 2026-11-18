import Foundation

/// Sorts the addresses in `BENITO_PUBLIC_URLS` into the kinds this app writes itself.
enum AdvertisedAddress {
    static func list(from setting: String?) -> [String] {
        (setting ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The IP of an `http://<private ip>[:port]` address, `nil` for anything else.
    static func lanHost(of address: String) -> String? {
        guard
            let components = URLComponents(string: address),
            components.scheme?.lowercased() == "http",
            let host = components.host,
            PrivateAddress.isPrivateIPv4(host)
        else { return nil }
        return host
    }

    static func isTailnet(_ address: String) -> Bool {
        URLComponents(string: address)?.host?.lowercased().hasSuffix(".ts.net") == true
    }

    /// The first home network address whose IP this Mac no longer has. `nil` when this Mac has no
    /// home network address at all, because then there is nothing to update it to.
    static func staleLanHost(in addresses: [String], current: [String]) -> String? {
        guard !current.isEmpty else { return nil }
        return addresses.lazy.compactMap(lanHost).first { !current.contains($0) }
    }

    /// Points every home network address at `current`, keeping each port.
    static func replacingLanHosts(in addresses: [String], with current: String) -> [String] {
        var result: [String] = []
        for address in addresses {
            var updated = address
            if lanHost(of: address) != nil, var components = URLComponents(string: address) {
                components.host = current
                updated = components.string ?? address
            }
            if !result.contains(updated) {
                result.append(updated)
            }
        }
        return result
    }
}
