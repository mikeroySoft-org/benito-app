import Foundation

/// `GET /health` on the public listener of a server that has no admin API.
struct LegacyHealth: Decodable, Sendable, Equatable {
    static let expectedService = "benito-server"

    var service: String
    var version: String?
}
