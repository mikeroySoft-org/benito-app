import SwiftUI

/// One line of the checklist: the verdict, what was found, why it matters, and what to do.
struct ReliabilityRow<Action: View>: View {
    let title: String
    let state: CheckState
    /// What the check found, as a sentence.
    let finding: String
    /// Why a parent should care, as a sentence.
    let why: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.systemImage)
                .foregroundStyle(state.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text("\(state.title): \(finding)")
                    .textSelection(.enabled)
                Text(why)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            action
        }
        .padding(.vertical, 2)
    }
}
