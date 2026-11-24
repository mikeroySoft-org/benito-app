import SwiftUI

struct InviteSheet: View {
    @State private var created: CreatedInvite?

    var body: some View {
        Group {
            if let created {
                InviteResultView(created: created)
            } else {
                InviteForm { created = $0 }
            }
        }
        .frame(width: 440)
    }
}
