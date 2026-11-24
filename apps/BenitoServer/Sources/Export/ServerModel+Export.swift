import Foundation

extension ServerModel {
    /// The export as the server wrote it, or `nil` after setting `lastError`.
    func exportData(_ request: ExportRequest, as format: ExportFormat) async -> Data? {
        lastError = nil
        do {
            switch format {
            case .csv: return try await client.exportCSV(request)
            case .json: return try await client.exportJSON(familyID: request.familyID)
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }
}
