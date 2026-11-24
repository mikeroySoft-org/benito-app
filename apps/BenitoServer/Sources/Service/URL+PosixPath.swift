import Foundation

extension URL {
    /// The path as launchd, the server and the shell expect it: not percent-encoded, and without
    /// the trailing slash a directory URL carries.
    var posixPath: String {
        let plain = path(percentEncoded: false)
        return plain.count > 1 && plain.hasSuffix("/") ? String(plain.dropLast()) : plain
    }
}
