import SwiftUI

/// Label on the left, value on the right; for compact lists outside a `Form`.
struct FactRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

extension FactRow where Value == Text {
    init(_ label: String, value: String) {
        self.init(label: label) { Text(value) }
    }
}
