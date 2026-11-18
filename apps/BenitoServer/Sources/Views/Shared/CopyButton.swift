import SwiftUI

struct CopyButton: View {
    let value: String
    /// What VoiceOver and the tooltip call it, for example "Copy address".
    let title: String

    var body: some View {
        Button(title, systemImage: "doc.on.doc") {
            Desktop.copy(value)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help(title)
    }
}
