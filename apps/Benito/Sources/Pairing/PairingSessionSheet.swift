import SwiftUI

/// Confirmation + progress for a live SharePlay invite; presented on both phones.
struct PairingSessionSheet: View {
    @Bindable var pairing: PairingCoordinator
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            // Scrolls so the Confirm / Decline buttons stay reachable on short windows
            // (iPhone Duo outer display, medium detent, large Dynamic Type).
            ScrollView {
                VStack(spacing: 20) {
                    content
                }
                .padding(DesignTokens.gutter)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.center)
            .scrollBounceBehavior(.basedOnSize)
            .background(DesignTokens.bgCanvas.ignoresSafeArea())
            .navigationTitle("SharePlay invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(pairing.phase.isFinished ? "Done" : "Cancel") { pairing.dismiss() }
                        .disabled(pairing.phase.isWorking)
                }
            }
        }
        .benitoSheetDetents()
        .interactiveDismissDisabled(pairing.phase.isWorking)
    }

    @ViewBuilder
    private var content: some View {
        switch pairing.phase {
        case .idle:
            EmptyView()
        case .waitingForPartner:
            status("person.2.wave.2", "Waiting for them to tap Join on their phone…", progress: true)
        case .confirmPartner(let identity):
            prompt(
                systemImage: "person.badge.plus",
                title: "Add \(identity.displayName)?",
                detail: identity.name.isEmpty || identity.email.isEmpty ? nil : identity.email,
                note: "They'll see and log everything in your family. You can remove them any time under Account › Sharing."
            )
            actionButtons(confirm: "Add to family", decline: "Decline") {
                pairing.approvePartner()
            } onDecline: {
                pairing.declinePartner()
            }
        case .confirmJoin(let activity):
            prompt(
                systemImage: "house",
                title: "\(PairingActivity.joinTitle(familyName: activity.familyName))?",
                detail: "Invited by \(activity.inviterName)",
                note: nil
            )
            TextField("Your name", text: $pairing.joinName)
                .textContentType(.givenName)
                .submitLabel(.join)
                .focused($nameFocused)
                .onSubmit(pairing.confirmJoin)
                .padding(.horizontal, 16)
                .frame(minHeight: DesignTokens.thumbMin)
                .background(DesignTokens.bgCard, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
                .onAppear { nameFocused = pairing.joinName.isEmpty }
            Text("So your family knows who's logging. No account or password needed.")
                .font(.footnote)
                .foregroundStyle(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
            actionButtons(confirm: "Join", decline: "Not now") {
                pairing.confirmJoin()
            } onDecline: {
                pairing.dismiss()
            }
        case .waitingForApproval:
            status("hourglass", "Waiting for them to confirm on their phone…", progress: true)
        case .working(let message):
            status("arrow.triangle.2.circlepath", message, progress: true)
        case .done(let message):
            status("checkmark.circle.fill", message, tint: DesignTokens.active)
        case .failed(let message):
            status("exclamationmark.triangle.fill", message, tint: DesignTokens.fault)
        }
    }

    private func prompt(systemImage: String, title: String, detail: String?, note: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(DesignTokens.sleep)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func actionButtons(
        confirm: String,
        decline: String,
        onConfirm: @escaping () -> Void,
        onDecline: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Button(action: onConfirm) {
                Text(confirm)
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: DesignTokens.thumbMin)
                    .foregroundStyle(DesignTokens.onAccent)
                    .background(DesignTokens.sleep, in: Capsule(style: .continuous))
            }
            .buttonStyle(BenitoBorderlessButtonStyle())
            Button(role: .cancel, action: onDecline) {
                Text(decline)
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: DesignTokens.thumbMin)
                    .foregroundStyle(DesignTokens.textPrimary)
                    .background(DesignTokens.bgCardElevated, in: Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(DesignTokens.textSecondary.opacity(0.28), lineWidth: 1)
                    )
            }
            .buttonStyle(BenitoBorderlessButtonStyle())
        }
    }

    private func status(_ systemImage: String, _ message: String, progress: Bool = false, tint: Color = DesignTokens.sleep) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .multilineTextAlignment(.center)
            if progress {
                ProgressView()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Receives SharePlay invite sessions for the app's lifetime and presents the confirmation sheet.
    func benitoPartnerPairing(_ pairing: PairingCoordinator) -> some View {
        modifier(PartnerPairingModifier(pairing: pairing))
    }
}

private struct PartnerPairingModifier: ViewModifier {
    @Bindable var pairing: PairingCoordinator

    func body(content: Content) -> some View {
        content
            .environment(pairing)
            .task { await pairing.receiveSessions() }
            .sheet(
                isPresented: Binding(
                    get: { pairing.isSheetPresented && !pairing.isHostedByInviteSheet },
                    set: { if !$0 { pairing.isSheetPresented = false } }
                ),
                onDismiss: { if !pairing.isHostedByInviteSheet { pairing.dismiss() } }
            ) {
                PairingSessionSheet(pairing: pairing)
            }
    }
}
