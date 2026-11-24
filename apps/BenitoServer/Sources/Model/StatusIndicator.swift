import SwiftUI

/// What the menubar icon and the status dot say at a glance.
enum StatusIndicator: Equatable, Sendable {
    case checking
    /// The app is installing, starting, stopping or otherwise changing the service.
    case working
    case running
    case needsAttention
    case stopped

    var symbolName: String {
        switch self {
        case .checking: "ellipsis.circle"
        case .working: "arrow.triangle.2.circlepath"
        case .running: "server.rack"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .checking: "Benito Server, checking"
        case .working: "Benito Server, working"
        case .running: "Benito Server, running"
        case .needsAttention: "Benito Server, needs attention"
        case .stopped: "Benito Server, stopped"
        }
    }

    var color: Color {
        switch self {
        case .checking, .working: .secondary
        case .running: .green
        case .needsAttention: .orange
        case .stopped: .red
        }
    }
}
