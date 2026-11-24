import Foundation

/// What a command-line tool printed and how it ended.
struct CommandOutput: Sendable, Equatable {
    /// `nil` when the tool was stopped because it ran past its timeout.
    var exitStatus: Int32?
    var standardOutput: String
    var standardError: String

    var succeeded: Bool { exitStatus == 0 }
    var timedOut: Bool { exitStatus == nil }

    /// What the tool said went wrong: its error output, or its normal output when that is empty.
    var complaint: String {
        let errors = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return errors.isEmpty ? standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) : errors
    }
}
