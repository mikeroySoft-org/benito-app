import Foundation

/// TCP ports on 127.0.0.1, where the server's public listener sits behind Tailscale Serve.
enum LoopbackPort {
    /// True when something accepts a connection on the port right now.
    static func isInUse(_ port: Int) -> Bool {
        guard let port = UInt16(exactly: port) else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = loopbackAddress(port: port)
        return withSocketAddress(&address) { connect(descriptor, $0, $1) } == 0
    }

    /// A port nothing is listening on, chosen by the system. Another program can still take it
    /// before the server binds it; the server then fails to start and says so in its log.
    static func available() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var address = loopbackAddress(port: 0)
        guard withSocketAddress(&address, { bind(descriptor, $0, $1) }) == 0 else { return nil }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0 else { return nil }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return address
    }

    private static func withSocketAddress(
        _ address: inout sockaddr_in,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32
    ) -> Int32 {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}
