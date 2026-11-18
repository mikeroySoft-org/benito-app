import Foundation

/// One `benito-YYYYmmdd-HHMMSS.db` file in the backup folder.
struct BackupSnapshot: Decodable, Sendable, Hashable, Identifiable {
    var name: String
    var path: String
    var sizeBytes: Int64
    var modifiedAt: Date

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name, path
        case sizeBytes = "size_bytes"
        case modifiedAt = "modified_at"
    }
}
