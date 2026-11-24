import SwiftUI

/// Stands in for the server's details while an installed service is not answering.
struct OverviewUnavailableSection: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        Section("Server") {
            LabeledContent("Status") {
                StatusLine()
            }
            if let explanation = model.explanation {
                Text(explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
