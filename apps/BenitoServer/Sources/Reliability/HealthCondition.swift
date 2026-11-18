import Foundation

/// A problem worth interrupting a parent for.
enum HealthCondition: String, CaseIterable, Sendable {
    case serverDown
    case backupFailed
    case backupOverdue
    case lowDisk

    var title: String {
        switch self {
        case .serverDown: "Benito Server is not running"
        case .backupFailed: "A Benito backup failed"
        case .backupOverdue: "Benito backups are overdue"
        case .lowDisk: "This Mac is almost out of disk space"
        }
    }

    /// `detail` is the server's error for a failed backup and the free space for a full disk.
    func body(detail: String?) -> String {
        switch self {
        case .serverDown:
            "The server on this Mac has not answered for over a minute. Phones keep what is logged and send it once the server is back."
        case .backupFailed:
            detail.map { "The server said: \($0)" } ?? "Open Benito Server and look at Backups."
        case .backupOverdue:
            "The newest backup is older than twice the backup schedule. Open Benito Server and look at Backups."
        case .lowDisk:
            detail.map { "Only \($0) is free on the disk that holds Benito's data. The server needs room to save and back up." }
                ?? "Less than 1 GB is free on the disk that holds Benito's data."
        }
    }
}
