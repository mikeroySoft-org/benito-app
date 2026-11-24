import Foundation

enum TailscaleLoadState: Equatable, Sendable {
    case checking
    case notInstalled
    /// The command-line tool is there but did not give a usable answer.
    case unavailable(String)
    case loaded(TailscaleSnapshot)

    /// `.unknown` unless Tailscale answered, so a Tailscale that is merely closed does not make
    /// Apply drop the tailnet address from invites.
    var serve: TailscaleServeState {
        switch self {
        case .loaded(let snapshot): snapshot.serve
        case .notInstalled: .notForwarding
        case .checking, .unavailable: .unknown
        }
    }
}
