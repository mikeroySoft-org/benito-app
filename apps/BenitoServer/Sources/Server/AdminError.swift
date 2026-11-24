import Foundation

enum AdminError: LocalizedError, Sendable {
    /// No `admin.json`: the server is not running, or runs without the admin API.
    case handoffMissing
    case handoffUnreadable(String)
    /// Nothing accepted the connection at the address in `admin.json`.
    case unreachable(String)
    case unauthorized
    case server(status: Int, message: String)
    case invalidResponse(String)

    /// The admin API did not answer at all, as opposed to answering with an error.
    var meansNotRunning: Bool {
        switch self {
        case .handoffMissing, .handoffUnreadable, .unreachable, .unauthorized: true
        case .server, .invalidResponse: false
        }
    }

    /// The handoff we used may belong to a previous server process.
    var suggestsStaleHandoff: Bool {
        switch self {
        case .unreachable, .unauthorized: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .handoffMissing:
            "The server is not running, or it was started without the admin API."
        case .handoffUnreadable(let detail):
            "The server's admin file could not be read: \(detail)"
        case .unreachable(let detail):
            "The server did not answer: \(detail)"
        case .unauthorized:
            "The server did not accept this app's admin token."
        case .server(_, let message):
            message
        case .invalidResponse(let detail):
            "The server sent an answer this app does not understand: \(detail)"
        }
    }
}
