import UniformTypeIdentifiers

enum ExportFormat: Sendable {
    case csv
    case json

    var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .json: "json"
        }
    }

    var contentType: UTType {
        switch self {
        case .csv: .commaSeparatedText
        case .json: .json
        }
    }
}
