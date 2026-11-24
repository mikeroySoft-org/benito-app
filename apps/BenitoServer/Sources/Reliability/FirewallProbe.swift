import Foundation

enum FirewallProbe {
    private static let tool = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")

    static func read() async -> Probed<FirewallState> {
        let output: CommandOutput
        do {
            output = try await ExternalCommand.run(tool, arguments: ["--getglobalstate"], timeout: .seconds(5))
        } catch {
            return .unavailable(error.localizedDescription)
        }
        guard let state = state(inOutput: output.standardOutput) else {
            return .unavailable(output.timedOut ? "The firewall did not answer." : "The firewall did not report its state.")
        }
        return .value(state)
    }

    /// Reads `Firewall is enabled. (State = 1)`; state 2 is "block all incoming connections".
    static func state(inOutput text: String) -> FirewallState? {
        if let match = text.firstMatch(of: #/State = (\d+)/#), let number = Int(match.1) {
            switch number {
            case 0: return .off
            case 2: return .blockingAll
            default: return .on
            }
        }
        let lowered = text.lowercased()
        if lowered.contains("disabled") { return .off }
        if lowered.contains("enabled") { return .on }
        return nil
    }
}
