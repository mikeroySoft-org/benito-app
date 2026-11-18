import AppKit

/// Asks where to put an export and writes it there.
@MainActor
enum ExportSaver {
    /// The saved file, or `nil` when the person cancelled.
    static func save(_ data: Data, suggestedName: String, format: ExportFormat) async throws -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true

        let response: NSApplication.ModalResponse
        if let window = NSApplication.shared.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        guard response == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: .atomic)
        return url
    }
}
