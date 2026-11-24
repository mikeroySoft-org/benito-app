import SwiftUI

/// The verdict on one line of the reliability checklist.
enum CheckState: Equatable, Sendable {
    case ok
    case needsAttention
    case couldNotCheck

    var title: String {
        switch self {
        case .ok: "OK"
        case .needsAttention: "Needs attention"
        case .couldNotCheck: "Could not check"
        }
    }

    var systemImage: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .couldNotCheck: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .needsAttention: .orange
        case .couldNotCheck: .secondary
        }
    }
}
