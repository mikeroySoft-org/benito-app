import Foundation

/// What the disks under the database and the backup folder look like.
struct StorageFacts: Sendable, Equatable {
    /// Free space on the volume that holds the database; `nil` when it could not be read.
    var freeBytes: Int64?
    /// Whether the backup folder is on the same volume as the database; `nil` when there is no
    /// backup folder or either volume could not be read.
    var backupsShareVolume: Bool?
}
