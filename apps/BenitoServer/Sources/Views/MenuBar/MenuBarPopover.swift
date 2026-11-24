import SwiftUI

struct MenuBarPopover: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusLine()
                .font(.headline)
            if model.isRunning {
                PopoverDetails()
            } else if let explanation = model.explanation {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PopoverServiceNotice()
            ErrorBanner()
            Divider()
            PopoverActions()
        }
        .padding(16)
        .frame(width: 320)
    }
}
