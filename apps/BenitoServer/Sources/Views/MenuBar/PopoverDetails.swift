import SwiftUI

/// What the popover shows while the admin API answers.
struct PopoverDetails: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        if let status = model.status {
            PopoverFacts(status: status)
            Divider()
            PopoverGlance(children: model.glance)
            Divider()
            PopoverAddresses(addresses: status.advertisedUrls)
        }
    }
}
