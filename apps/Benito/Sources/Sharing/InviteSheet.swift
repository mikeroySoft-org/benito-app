import BenitoKit
import CoreImage.CIFilterBuiltins
import MessageUI
import SwiftUI

/// "Invite to Family": pick parent or caregiver, then send one link by Messages, AirDrop or
/// SharePlay (or show a QR code). The invite is made as soon as the sheet opens, so the usual
/// path is two taps: Messages, Send.
struct InviteSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var role: FamilyRole = .parent
    @State private var access: CaregiverAccess = .threeDays
    @State private var link: FamilyInviteLink?
    @State private var errorText: String?
    @State private var showComposer = false

    enum CaregiverAccess: Int, CaseIterable, Identifiable {
        case tonight = 12
        case threeDays = 72
        case week = 168
        case month = 720
        case noEnd = 0

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .tonight: "Tonight (12 hours)"
            case .threeDays: "3 days"
            case .week: "1 week"
            case .month: "1 month"
            case .noEnd: "Until I remove them"
            }
        }

        var hours: Int? { self == .noEnd ? nil : rawValue }
    }

    private struct Config: Equatable {
        let role: FamilyRole
        let access: CaregiverAccess
        let signedIn: Bool
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    rolePicker
                    channels
                    qrCard
                    footnote
                }
                .padding(DesignTokens.gutter)
                .readableContentWidth()
            }
            .background(DesignTokens.bgCanvas.ignoresSafeArea())
            .navigationTitle("Invite to Family")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task(id: Config(role: role, access: access, signedIn: model.isSignedIn)) {
            guard model.isSignedIn else { return }
            await regenerate()
        }
        .onAppear { model.pairing.isHostedByInviteSheet = true }
        .onDisappear { model.pairing.isHostedByInviteSheet = false }
        .sheet(
            isPresented: Binding(
                get: { model.pairing.isSheetPresented },
                set: { if !$0 { model.pairing.isSheetPresented = false } }
            ),
            onDismiss: { model.pairing.dismiss() }
        ) {
            PairingSessionSheet(pairing: model.pairing)
        }
        .sheet(isPresented: $showComposer) {
            if let link {
                MessageComposer(body: AppModel.inviteMessage(for: link)) { showComposer = false }
                    .ignoresSafeArea()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "figure.2.and.child.holdinghands")
                .font(.system(size: 44))
                .foregroundStyle(DesignTokens.feed)
                .accessibilityHidden(true)
            Text("Share \(model.familyName)")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("They'll see and log feeds, sleep, and diapers for \(model.childName).")
                .font(.subheadline)
                .foregroundStyle(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var rolePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Invite as", selection: $role) {
                Text("Parent").tag(FamilyRole.parent)
                Text("Caregiver").tag(FamilyRole.caregiver)
            }
            .pickerStyle(.segmented)

            Text(role == .parent
                 ? "Parents can invite and remove people."
                 : "Caregivers log everything but can't manage sharing. Great for babysitters and grandparents.")
                .font(.footnote)
                .foregroundStyle(DesignTokens.textSecondary)

            if role == .caregiver {
                Picker("Access", selection: $access) {
                    ForEach(CaregiverAccess.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .tint(DesignTokens.sleep)
            }
        }
        .padding(DesignTokens.gutter)
        .background(DesignTokens.bgCard, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
    }

    private var channels: some View {
        HStack(spacing: 12) {
            ChannelTile(title: "Messages", systemImage: "message.fill", tint: DesignTokens.active) {
                sendText()
            }
            if let link {
                ShareLink(
                    item: link.url,
                    subject: Text("Join \(link.familyName) on Benito"),
                    message: Text(AppModel.inviteMessage(for: link)),
                    preview: SharePreview("Join \(link.familyName) on Benito")
                ) {
                    ChannelTile.Label(title: "AirDrop", systemImage: "airplayaudio", tint: DesignTokens.accentBlue)
                }
                .buttonStyle(BenitoBorderlessButtonStyle())
            } else {
                ChannelTile.Label(title: "AirDrop", systemImage: "airplayaudio", tint: DesignTokens.accentBlue)
                    .opacity(0.4)
            }
            if let invite = model.pairing.outgoingInvite, link != nil {
                ShareLink(
                    item: invite,
                    preview: SharePreview(PairingActivity.shareTitle(familyName: model.familyName))
                ) {
                    ChannelTile.Label(title: "SharePlay", systemImage: "shareplay", tint: DesignTokens.sleep)
                }
                .buttonStyle(BenitoBorderlessButtonStyle())
            } else {
                ChannelTile.Label(title: "SharePlay", systemImage: "shareplay", tint: DesignTokens.sleep)
                    .opacity(0.4)
            }
        }
        .disabled(link == nil)
    }

    private var qrCard: some View {
        VStack(spacing: 10) {
            Group {
                if let link, let image = QRCode.image(for: link.url.absoluteString) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("Invite QR code")
                } else if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.fault)
                        .font(.footnote)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 180, height: 180)
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text("In the same room? They can scan this with the Camera app.")
                .font(.footnote)
                .foregroundStyle(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.gutter)
        .background(DesignTokens.bgCard, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
    }

    @ViewBuilder
    private var footnote: some View {
        if let link {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Works once and expires \(link.expiresAt.formatted(.relative(presentation: .named))).",
                    systemImage: "lock.fill"
                )
                if link.endpoints.contains(where: FamilyInviteLink.looksLocal) {
                    Label("Anyone on your home Wi-Fi can join. Tailscale is only needed away from home.", systemImage: "wifi")
                } else {
                    Label(
                        "Your server only shares a Tailscale address, so they'll need Tailscale. Add your home Wi-Fi address to BENITO_PUBLIC_URLS on the server so babysitters can join without it.",
                        systemImage: "exclamationmark.circle"
                    )
                }
            }
            .font(.footnote)
            .foregroundStyle(DesignTokens.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sendText() {
        guard let link else { return }
        if MFMessageComposeViewController.canSendText() {
            showComposer = true
        } else {
            var components = URLComponents()
            components.scheme = "sms"
            components.path = ""
            components.queryItems = [URLQueryItem(name: "body", value: AppModel.inviteMessage(for: link))]
            if let url = URL(string: "sms:&" + (components.percentEncodedQuery ?? "")) {
                openURL(url)
            }
        }
    }

    /// One live invite per sheet: changing role or access replaces the unused one.
    private func regenerate() async {
        let previous = link
        link = nil
        errorText = nil
        do {
            let fresh = try await model.makeInvite(role: role, accessHours: access.hours)
            if let previous { try? await model.sessionClient().revokeInvite(id: previous.inviteId) }
            link = fresh
            model.pairing.prepareInvite(link: fresh)
        } catch is CancellationError {
            return
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct ChannelTile: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title: title, systemImage: systemImage, tint: tint)
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
    }

    struct Label: View {
        let title: String
        let systemImage: String
        let tint: Color

        var body: some View {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 52, height: 52)
                    .background(tint.opacity(0.16), in: Circle())
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .background(DesignTokens.bgCard, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
        }
    }
}

enum QRCode {
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// In-app Messages compose sheet with the invite text filled in; the user picks who.
struct MessageComposer: UIViewControllerRepresentable {
    let body: String
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.body = body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            onFinish()
        }
    }
}
