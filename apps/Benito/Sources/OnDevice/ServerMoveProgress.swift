import Foundation

/// Where a move from this iPhone to a family server is, for Account › Connect to a server.
struct ServerMoveProgress: Equatable {
    enum Phase: Equatable {
        case connecting
        case uploading(done: Int, total: Int)
        case finishing
    }

    var server: URL
    var phase: Phase
}
