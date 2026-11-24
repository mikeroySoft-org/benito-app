import Foundation

/// Outcome of fetching `/health` through one of the addresses phones are given.
enum ReachabilityResult: Equatable, Sendable {
    case testing
    case reachable(version: String?)
    case notReachable(String)
}
