import Foundation

/// Fetches `/health` through an address the way a phone would, from this Mac.
enum HealthProbe {
    private static let timeout: TimeInterval = 5

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func check(_ address: String) async -> ReachabilityResult {
        guard let base = URL(string: address), base.scheme != nil, base.host() != nil else {
            return .notReachable("This is not a web address.")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: base.appending(path: "health"))
        } catch {
            return .notReachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode
            return .notReachable(code.map { "Something answered with HTTP \($0), but not a Benito server." }
                ?? "Something answered, but not a Benito server.")
        }
        guard
            let health = try? JSONDecoder().decode(LegacyHealth.self, from: data),
            health.service == LegacyHealth.expectedService
        else {
            return .notReachable("Something answered at this address, but it is not a Benito server.")
        }
        return .reachable(version: health.version)
    }
}
