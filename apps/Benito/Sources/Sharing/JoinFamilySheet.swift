import BenitoKit
import SwiftUI

extension View {
    /// Opens invite links (universal https links and `benito://join`) as a one-tap join sheet.
    func benitoJoinLinks(model: AppModel) -> some View {
        modifier(JoinLinksModifier(model: model))
    }
}

private struct JoinLinksModifier: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                guard let link = FamilyInviteLink(url: url) else { return }
                model.pendingJoinLink = link
            }
            .sheet(item: $model.pendingJoinLink) { link in
                JoinFamilySheet(model: model, link: link)
            }
    }
}

/// "Join the Garcia family?" One name field and one button: no account, no password.
struct JoinFamilySheet: View {
    let model: AppModel
    let link: FamilyInviteLink
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isJoining = false
    @State private var errorText: String?
    @State private var joined = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if joined {
                        success
                    } else {
                        invitation
                    }
                }
                .padding(DesignTokens.gutter)
                .readableContentWidth()
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(DesignTokens.bgCanvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(joined ? "Done" : "Cancel") { dismiss() }
                        .disabled(isJoining)
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isJoining)
        .onAppear {
            if name.isEmpty { name = model.signedInName }
            nameFocused = name.isEmpty
        }
    }

    @ViewBuilder
    private var invitation: some View {
        VStack(spacing: 8) {
            Image(systemName: "house.and.flag.fill")
                .font(.system(size: 48))
                .foregroundStyle(DesignTokens.feed)
                .accessibilityHidden(true)
            Text("Join \(link.familyName)")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("\(link.inviterName) invited you as a \(link.role == .caregiver ? "caregiver" : "parent").")
                .foregroundStyle(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)

        VStack(alignment: .leading, spacing: 8) {
            Text("Your name")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignTokens.textSecondary)
            TextField("e.g. Jordan", text: $name)
                .textContentType(.givenName)
                .submitLabel(.join)
                .focused($nameFocused)
                .onSubmit(join)
                .padding(.horizontal, 16)
                .frame(minHeight: DesignTokens.thumbMin)
                .background(DesignTokens.bgCard, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
            Text("Shown next to what you log. No email or password: this iPhone gets its own private key.")
                .font(.footnote)
                .foregroundStyle(DesignTokens.textSecondary)
        }

        if model.hasFamily {
            Label(
                "This iPhone is already part of \(model.familyName). Sign out under Account first to join another family.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.footnote)
            .foregroundStyle(DesignTokens.fault)
        } else if link.isExpired {
            Label("This invite has expired. Ask \(link.inviterName) for a new one.", systemImage: "clock.badge.exclamationmark")
                .font(.footnote)
                .foregroundStyle(DesignTokens.fault)
        }

        if let errorText {
            Label(errorText, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(DesignTokens.fault)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        Button(action: join) {
            Group {
                if isJoining {
                    ProgressView().tint(DesignTokens.onAccent)
                } else {
                    Text("Join \(link.familyName)")
                }
            }
            .font(.headline.weight(.bold))
            .frame(maxWidth: .infinity, minHeight: DesignTokens.thumbMin)
            .foregroundStyle(DesignTokens.onAccent)
            .background(DesignTokens.feed, in: Capsule(style: .continuous))
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
        .disabled(!canJoin)
        .opacity(canJoin ? 1 : 0.5)

        if link.role == .caregiver {
            Text("Caregiver access can end automatically; the family can also remove you any time.")
                .font(.footnote)
                .foregroundStyle(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var success: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(DesignTokens.active)
                .accessibilityHidden(true)
            Text("You're in")
                .font(.largeTitle.bold())
            Text("You can now see and log everything for \(model.childName) in \(link.familyName).")
                .foregroundStyle(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
            if let until = model.accessExpiresAt {
                Text("Access until \(until.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            Button("Start logging") { dismiss() }
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: DesignTokens.thumbMin)
                .foregroundStyle(DesignTokens.onAccent)
                .background(DesignTokens.active, in: Capsule(style: .continuous))
                .buttonStyle(BenitoBorderlessButtonStyle())
                .padding(.top, 12)
        }
        .padding(.top, 48)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canJoin: Bool {
        !trimmedName.isEmpty && !isJoining && !model.hasFamily && !link.isExpired
    }

    private func join() {
        guard canJoin else { return }
        isJoining = true
        errorText = nil
        Task {
            defer { isJoining = false }
            do {
                try await model.join(with: link, name: trimmedName)
                withAnimation { joined = true }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
