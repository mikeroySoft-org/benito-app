import Foundation

enum PrivateAddress {
    /// Dotted IPv4 in 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16: the ranges home routers hand out.
    static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (172, 16...31): return true
        default: return false
        }
    }
}
