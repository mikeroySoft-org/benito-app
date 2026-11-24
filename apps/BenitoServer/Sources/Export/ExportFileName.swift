import Foundation

enum ExportFileName {
    /// `benito-<child or family>-<yyyy-MM-dd>.<extension>`, with today's local date.
    static func suggested(
        subject: String,
        format: ExportFormat,
        date: Date = .now,
        timeZone: TimeZone = .current
    ) -> String {
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
        return "benito-\(slug(subject))-\(day).\(format.fileExtension)"
    }

    /// Lowercase letters and digits, everything else folded into single dashes.
    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let words = folded
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
        return words.isEmpty ? "export" : words.joined(separator: "-")
    }
}
