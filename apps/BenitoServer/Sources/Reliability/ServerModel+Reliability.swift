import Foundation

extension ServerModel {
    /// The database file the running server reports, else where this home keeps it.
    var databaseLocation: URL {
        status.map { URL(fileURLWithPath: $0.database.path) } ?? home.databaseFile
    }

    var backupFolder: URL? {
        status?.backup.dir.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Whether the server is set to accept phones on the home network, not just on this Mac.
    var hasLanListener: Bool {
        ConnectionDraft.lanPort(in: settings) != nil
    }
}
