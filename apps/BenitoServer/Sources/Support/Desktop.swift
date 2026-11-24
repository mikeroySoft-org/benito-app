import AppKit

/// Pasteboard and Finder, the two places this app hands things to the rest of the Mac.
@MainActor
enum Desktop {
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    static func revealInFinder(path: String) {
        revealInFinder(URL(fileURLWithPath: path))
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
