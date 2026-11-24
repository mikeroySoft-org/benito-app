import Foundation

/// `POST /admin/backups`: the snapshot just taken, what it holds, and how many old ones were pruned.
struct BackupResult: Decodable, Sendable, Equatable {
    var name: String
    var path: String
    var sizeBytes: Int64
    var modifiedAt: Date
    var users: Int
    var events: Int
    var pruned: Int

    enum CodingKeys: String, CodingKey {
        case name, path, users, events, pruned
        case sizeBytes = "size_bytes"
        case modifiedAt = "modified_at"
    }
}
