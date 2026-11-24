import Foundation

enum SleepProbe {
    private static let tool = URL(fileURLWithPath: "/usr/bin/pmset")

    /// Minutes of idleness before this Mac sleeps on its current power source; 0 is never.
    static func read() async -> Probed<Int> {
        let output: CommandOutput
        do {
            output = try await ExternalCommand.run(tool, arguments: ["-g"], timeout: .seconds(5))
        } catch {
            return .unavailable(error.localizedDescription)
        }
        guard output.succeeded, let minutes = minutes(inPmsetOutput: output.standardOutput) else {
            return .unavailable(output.timedOut ? "pmset did not answer." : "pmset did not report a sleep setting.")
        }
        return .value(minutes)
    }

    /// The value on the ` sleep  <minutes> (…)` line of `pmset -g`.
    static func minutes(inPmsetOutput text: String) -> Int? {
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            if words.count >= 2, words[0] == "sleep", let minutes = Int(words[1]) {
                return minutes
            }
        }
        return nil
    }
}
