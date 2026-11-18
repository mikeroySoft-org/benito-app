import Foundation

enum TailscaleError: LocalizedError, Sendable, Equatable {
    case couldNotStart(String)
    case timedOut(said: String)
    case failed(String)
    case httpsNotEnabled(String)

    var errorDescription: String? {
        switch self {
        case .couldNotStart(let detail):
            "Tailscale's command-line tool could not be started: \(detail)"
        case .timedOut(let said):
            said.isEmpty
                ? "Tailscale did not answer within 15 seconds. Open the Tailscale app, check that it is connected, and try again."
                : "Tailscale did not finish within 15 seconds. It said: \(said)"
        case .failed(let detail):
            detail.isEmpty ? "Tailscale reported a problem but did not say what it was." : detail
        case .httpsNotEnabled(let detail):
            "\(detail)\n\nHTTPS is not turned on for your tailnet. In the Tailscale admin console, open DNS, turn on MagicDNS and HTTPS Certificates, then try again."
        }
    }
}
