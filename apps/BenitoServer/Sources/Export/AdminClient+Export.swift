import Foundation

extension AdminClient {
    /// A long history takes longer to write out than a status call.
    private static let exportTimeout: TimeInterval = 120

    /// `GET /admin/export.csv`: the body is the CSV text itself.
    func exportCSV(_ request: ExportRequest) async throws -> Data {
        var items = [URLQueryItem(name: "family_id", value: request.familyID)]
        if let childID = request.childID {
            items.append(URLQueryItem(name: "child_id", value: childID))
        }
        if let from = request.from {
            items.append(URLQueryItem(name: "from", value: from.formatted(.iso8601)))
        }
        if let to = request.to {
            items.append(URLQueryItem(name: "to", value: to.formatted(.iso8601)))
        }
        return try await send("GET", Self.path("/admin/export.csv", items), timeout: Self.exportTimeout)
    }

    /// `GET /admin/export.json`: everything the server holds for one family.
    func exportJSON(familyID: String) async throws -> Data {
        try await send(
            "GET",
            Self.path("/admin/export.json", [URLQueryItem(name: "family_id", value: familyID)]),
            timeout: Self.exportTimeout
        )
    }

    private static func path(_ path: String, _ items: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
    }
}
