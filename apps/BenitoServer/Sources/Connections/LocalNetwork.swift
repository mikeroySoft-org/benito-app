import Darwin
import Foundation

enum LocalNetwork {
    /// This Mac's private IPv4 addresses on interfaces that are up, `en0` first.
    static func privateIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var preferred: [String] = []
        var others: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard
                flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                let socketAddress = entry.pointee.ifa_addr,
                socketAddress.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let raw = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let address = "\(raw >> 24).\((raw >> 16) & 0xFF).\((raw >> 8) & 0xFF).\(raw & 0xFF)"
            guard PrivateAddress.isPrivateIPv4(address) else { continue }
            if String(cString: entry.pointee.ifa_name) == "en0" {
                preferred.append(address)
            } else {
                others.append(address)
            }
        }
        return preferred + others
    }
}
