import AppKit
import SwiftUI

/// Read-only, selectable log text.
///
/// AppKit rather than a SwiftUI `ScrollView`: selection has to span lines, a few thousand lines
/// must stay cheap to replace, and following the tail needs to know whether the user scrolled up,
/// which SwiftUI on macOS 14 cannot report.
struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
            weight: .regular
        )
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.setAccessibilityLabel("Server log")
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        let visibleBottom = scrollView.contentView.bounds.maxY
        let wasAtBottom = visibleBottom >= textView.frame.height - 4
        textView.string = text
        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }
}
