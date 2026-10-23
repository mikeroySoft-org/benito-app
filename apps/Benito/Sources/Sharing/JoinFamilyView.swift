import BenitoKit
import SwiftUI

/// Account › Join a family, for a signed-in phone without a family: paste an invite link,
/// or use an older-style invite code.
struct JoinFamilyView: View {
    @Bindable var model: AppModel
    @State private var pasteError: String?

    var body: some View {
        List {
            Section {
                Label("Ask someone in the family to open Account › Sharing › Invite to Family.", systemImage: "1.circle.fill")
                Label("Tap the link they send, scan their QR code, or accept their SharePlay.", systemImage: "2.circle.fill")
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        if let link = strings.lazy.compactMap(FamilyInviteLink.init(text:)).first {
                            pasteError = nil
                            model.pendingJoinLink = link
                        } else {
                            pasteError = "That doesn't contain a Benito invite."
                        }
                    }
                }
                .buttonBorderShape(.capsule)
                if let pasteError {
                    Text(pasteError).font(.footnote).foregroundStyle(DesignTokens.fault)
                }
            } header: {
                Text("With an invite")
            }
            .listRowBackground(BenitoGlassListRowBackground())

            Section {
                TextField("Invite code", text: $model.inviteCode)
                    .textInputAutocapitalization(.characters)
                    .font(.body.monospaced())
                Button("Join family") { Task { await model.joinFamily() } }
            } header: {
                Text("Or enter an invite code")
            } footer: {
                Text("For families on an older Benito server.")
            }
            .listRowBackground(BenitoGlassListRowBackground())
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .readableContentWidth()
        .background(DesignTokens.bgCanvas.ignoresSafeArea())
        .navigationTitle("Join a family")
        .navigationBarTitleDisplayMode(.inline)
        .benitoNavigationBarGlass()
    }
}
