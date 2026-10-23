import Foundation

/// Readable version footer for Account: marketing version, build number, git short SHA.
enum AppBuildInfo {
    static var footerLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let sha = BenitoGitSHA.short.trimmingCharacters(in: .whitespacesAndNewlines)
        if sha.isEmpty || sha == "unknown" {
            return "\(version) (\(build))"
        }
        return "\(version) (\(build)) · \(sha)"
    }
}
