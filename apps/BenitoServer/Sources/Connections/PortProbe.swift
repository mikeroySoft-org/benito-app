import Darwin

enum PortProbe {
    /// Whether a listener could bind `0.0.0.0:<port>` right now. `SO_REUSEADDR` is set because
    /// the server's listener sets it too, so this answers what the server would be told.
    static func isFree(_ port: Int) -> Bool {
        guard let number = UInt16(exactly: port) else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = number.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
