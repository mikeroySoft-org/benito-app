import Foundation

/// Puts a finished file in place with one `rename`, so nothing ever reads half of it. The new
/// file is a new inode: a process that has the old one open (a running server) keeps the old one.
enum AtomicFile {
    static func write(_ data: Data, to destination: URL, permissions: Int) throws {
        let staging = stagingURL(for: destination)
        try? FileManager.default.removeItem(at: staging)
        try data.write(to: staging)
        try finish(staging, as: destination, permissions: permissions)
    }

    static func copy(_ source: URL, to destination: URL, permissions: Int) throws {
        let staging = stagingURL(for: destination)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: source, to: staging)
        try finish(staging, as: destination, permissions: permissions)
    }

    private static func stagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
    }

    private static func finish(_ staging: URL, as destination: URL, permissions: Int) throws {
        let stagingPath = staging.path(percentEncoded: false)
        do {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: stagingPath)
            guard rename(stagingPath, destination.path(percentEncoded: false)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}
