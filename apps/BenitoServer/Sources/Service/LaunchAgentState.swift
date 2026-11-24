import Foundation

/// What launchd says about one job in the user's GUI domain.
struct LaunchAgentState: Sendable, Equatable {
    var isLoaded: Bool
    /// `nil` while the job is loaded but has no process (between crash and restart, for example).
    var pid: Int?
    /// Exit status of the job's previous process; `nil` when it has never exited.
    var lastExitStatus: Int?

    static let notLoaded = LaunchAgentState(isLoaded: false)

    init(isLoaded: Bool, pid: Int? = nil, lastExitStatus: Int? = nil) {
        self.isLoaded = isLoaded
        self.pid = pid
        self.lastExitStatus = lastExitStatus
    }

    /// Reads the output of a successful `launchctl print`. That text is written for people and
    /// Apple does not promise its format, so a line this does not recognise is simply skipped:
    /// the job still counts as loaded, with no pid or exit status.
    init(printOutput: String) {
        self.init(isLoaded: true)
        for line in printOutput.split(whereSeparator: \.isNewline) {
            // The job's own properties sit one tab deep; nested dictionaries sit deeper.
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t"),
                  let separator = line.range(of: " = ")
            else { continue }
            let key = line[line.index(after: line.startIndex)..<separator.lowerBound]
            let value = line[separator.upperBound...]
            switch key {
            case "pid":
                pid = Int(value)
            case "last exit code", "last exit status":
                // "0", "78: EX_CONFIG" or "(never exited)".
                lastExitStatus = Int(value.prefix { $0.isNumber || $0 == "-" })
            default:
                break
            }
        }
    }
}
