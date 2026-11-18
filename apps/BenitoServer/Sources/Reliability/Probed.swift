import Foundation

/// The answer to a question put to macOS, which may not have been answerable.
enum Probed<Value: Sendable & Equatable>: Sendable, Equatable {
    case pending
    case value(Value)
    case unavailable(String)
}
