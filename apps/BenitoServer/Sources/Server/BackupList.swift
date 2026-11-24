import Foundation

/// `GET /admin/backups`, newest first.
struct BackupList: Decodable, Sendable, Equatable {
    var enabled: Bool
    var dir: String?
    var backups: [BackupSnapshot]
}
