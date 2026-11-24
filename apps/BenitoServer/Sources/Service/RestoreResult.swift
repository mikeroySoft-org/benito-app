import Foundation

/// The one JSON line `benito-server restore <file>` prints when it worked.
struct RestoreResult: Decodable, Sendable, Equatable {
    var database: String
    var restoredFrom: String
    /// Where the data from before the restore was saved. `nil` when there was no database yet.
    var preRestore: String?
    var users: Int
    var events: Int

    enum CodingKeys: String, CodingKey {
        case database, users, events
        case restoredFrom = "restored_from"
        case preRestore = "pre_restore"
    }
}
