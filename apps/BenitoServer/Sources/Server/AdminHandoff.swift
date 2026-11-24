import Foundation

/// `admin.json`: written by the server at startup, with a token that changes on every start.
struct AdminHandoff: Decodable, Sendable, Equatable {
    var url: URL
    var token: String
    var pid: Int
    var startedAt: Date

    enum CodingKeys: String, CodingKey {
        case url, token, pid
        case startedAt = "started_at"
    }
}
