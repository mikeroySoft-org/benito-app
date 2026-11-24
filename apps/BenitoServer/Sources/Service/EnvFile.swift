import Foundation

/// `benito.env`: the server's settings, one `KEY=value` per line.
///
/// Edits keep every line the app does not own (comments, blank lines, keys it does not know),
/// because people also edit this file by hand and `scripts/macos-service.sh` shares it.
/// Parsing matches `server/src/envfile.rs`: the first occurrence of a key wins, and one pair of
/// surrounding quotes is dropped.
struct EnvFile: Equatable, Sendable {
    private(set) var lines: [String]

    init(text: String = "") {
        lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
    }

    /// A missing file is an empty one: the first write creates it.
    static func load(from url: URL) throws -> EnvFile {
        do {
            return EnvFile(text: try String(contentsOf: url, encoding: .utf8))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return EnvFile()
        }
    }

    var values: [String: String] {
        var result: [String: String] = [:]
        for line in lines {
            guard let (key, value) = Self.parse(line), result[key] == nil else { continue }
            result[key] = value
        }
        return result
    }

    subscript(key: String) -> String? {
        for line in lines {
            if let (lineKey, value) = Self.parse(line), lineKey == key {
                return value
            }
        }
        return nil
    }

    /// Sets `key` in place (or appends it), and drops any later duplicates. `nil` removes it.
    mutating func set(_ key: String, to value: String?) {
        var replaced = false
        lines = lines.compactMap { line in
            guard let (lineKey, _) = Self.parse(line), lineKey == key else { return line }
            guard !replaced, let value else { return nil }
            replaced = true
            return "\(key)=\(value)"
        }
        if !replaced, let value {
            lines.append("\(key)=\(value)")
        }
    }

    mutating func apply(_ changes: [String: String?]) {
        for (key, value) in changes.sorted(by: { $0.key < $1.key }) {
            set(key, to: value)
        }
    }

    var text: String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Atomic, and readable only by the owner: the file holds `SESSION_SECRET`.
    func write(to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        try? manager.removeItem(at: staging)
        guard manager.createFile(
            atPath: staging.path(percentEncoded: false),
            contents: Data(text.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: staging.path(percentEncoded: false)])
        }
        do {
            _ = try manager.replaceItemAt(url, withItemAt: staging)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    private static func parse(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let separator = trimmed.firstIndex(of: "=")
        else { return nil }
        let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        var value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value)
    }
}
