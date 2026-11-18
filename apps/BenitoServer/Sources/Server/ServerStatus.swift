import Foundation

/// `GET /admin/status`.
struct ServerStatus: Decodable, Sendable, Equatable {
    var service: String
    var version: String
    var pid: Int
    var serverId: String
    var startedAt: Date
    var uptimeSeconds: Double
    var database: Database
    var counts: Counts
    var lastEventAt: Date?
    var listeners: [String]
    var advertisedUrls: [String]
    var bonjourName: String?
    var syncConnections: Int
    var apnsConfigured: Bool
    var backup: BackupSettings

    struct Database: Decodable, Sendable, Equatable {
        var path: String
        var sizeBytes: Int64
        var walBytes: Int64

        enum CodingKeys: String, CodingKey {
            case path
            case sizeBytes = "size_bytes"
            case walBytes = "wal_bytes"
        }
    }

    struct Counts: Decodable, Sendable, Equatable {
        var users: Int
        var families: Int
        var children: Int
        var events: Int
        var devices: Int
    }

    struct BackupSettings: Decodable, Sendable, Equatable {
        var enabled: Bool
        var dir: String?
        var keep: Int
        var intervalHours: Int
        var latest: BackupSnapshot?
        var lastError: String?

        enum CodingKeys: String, CodingKey {
            case enabled, dir, keep, latest
            case intervalHours = "interval_hours"
            case lastError = "last_error"
        }

        /// The schedule is on and the newest snapshot (or, with none yet, the server start) is
        /// more than two intervals old.
        func isOverdue(serverStartedAt: Date, now: Date = .now) -> Bool {
            guard enabled, intervalHours > 0 else { return false }
            let reference = latest?.modifiedAt ?? serverStartedAt
            return now.timeIntervalSince(reference) > TimeInterval(intervalHours) * 2 * 3600
        }
    }

    enum CodingKeys: String, CodingKey {
        case service, version, pid, database, counts, listeners, backup
        case serverId = "server_id"
        case startedAt = "started_at"
        case uptimeSeconds = "uptime_seconds"
        case lastEventAt = "last_event_at"
        case advertisedUrls = "advertised_urls"
        case bonjourName = "bonjour_name"
        case syncConnections = "sync_connections"
        case apnsConfigured = "apns_configured"
    }

    var backupNeedsAttention: Bool {
        backup.lastError != nil || backup.isOverdue(serverStartedAt: startedAt)
    }
}
