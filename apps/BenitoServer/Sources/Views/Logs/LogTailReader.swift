import Foundation

/// Reads the end of the server log off the main actor, and only when the file changed.
actor LogTailReader {
    enum Reading: Sendable {
        case unchanged
        case missing
        case lines([String])
    }

    private struct Signature: Equatable {
        var size: UInt64
        var modified: Date
    }

    private static let tailBytes: UInt64 = 256 * 1024
    private static let ansiEscape = "\u{001B}\\[[0-9;?]*[ -/]*[@-~]"

    private let url: URL
    private var lastRead: Signature?

    init(url: URL) {
        self.url = url
    }

    func read() -> Reading {
        let path = url.path(percentEncoded: false)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            let modified = attributes[.modificationDate] as? Date
        else {
            lastRead = nil
            return .missing
        }
        let signature = Signature(size: size, modified: modified)
        guard signature != lastRead else { return .unchanged }

        let offset = size > Self.tailBytes ? size - Self.tailBytes : 0
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            data = try handle.readToEnd() ?? Data()
        } catch {
            lastRead = nil
            return .missing
        }
        lastRead = signature

        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: Self.ansiEscape, with: "", options: .regularExpression)
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        // A read that starts mid-file almost always starts mid-line.
        if offset > 0, lines.count > 1 {
            lines.removeFirst()
        }
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return .lines(lines.map(String.init))
    }
}
