import Foundation

/// What a finished command-line tool left behind.
struct ProcessResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { exitCode == 0 }

    /// What the tool said went wrong, in one piece of text a person can read. `benito-server`
    /// prefixes its failures with "Error: ", which adds nothing inside a sentence of our own.
    var failureText: String {
        let said = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let message = said else { return "It exited with status \(exitCode)." }
        return message.hasPrefix("Error: ") ? String(message.dropFirst("Error: ".count)) : message
    }
}
