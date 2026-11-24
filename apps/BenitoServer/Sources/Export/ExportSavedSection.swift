import SwiftUI

/// Where the last export went, with a way to find it.
struct ExportSavedSection: View {
    let file: URL

    var body: some View {
        Section("Saved") {
            HStack(spacing: 8) {
                Label(file.path(percentEncoded: false), systemImage: "checkmark.circle")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Reveal in Finder") {
                    Desktop.revealInFinder(file)
                }
                .controlSize(.small)
            }
        }
    }
}
