import BenitoKit
import SwiftUI
import TipKit

/// Account › Sharing: who sees this family's log, invites waiting to be used, and the
/// "Invite to Family" button. Parents manage; caregivers only see the list.
struct SharingView: View {
    @Bindable var model: AppModel
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var showInvite = false
    @State private var memberToRemove: FamilyMemberDTO?

    var body: some View {
        List {
            if model.isParent {
                Section {
                    Button {
                        showInvite = true
                    } label: {
                        Label("Invite to Family", systemImage: "person.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: DesignTokens.thumbMin)
                            .foregroundStyle(DesignTokens.onAccent)
                            .background(DesignTokens.feed, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(BenitoBorderlessButtonStyle())
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Send a one-time link by Messages, AirDrop, or SharePlay. No usernames or passwords.")
                }
            }

            Section {
                if model.members.isEmpty, isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(model.members) { member in
                    MemberRow(member: member)
                        .swipeActions {
                            if canRemove(member) {
                                Button("Remove", role: .destructive) { memberToRemove = member }
                            }
                        }
                        .contextMenu {
                            if canRemove(member) {
                                Button("Remove from Family", systemImage: "person.badge.minus", role: .destructive) {
                                    memberToRemove = member
                                }
                            }
                        }
                }
            } header: {
                Text("Shared with")
            } footer: {
                if model.isParent, model.members.count > 1 {
                    Text("Swipe left on someone to stop sharing with them. Their phones stop syncing right away.")
                }
            }
            .listRowBackground(BenitoGlassListRowBackground())

            if !model.pendingInvites.isEmpty {
                Section("Waiting to join") {
                    ForEach(model.pendingInvites) { invite in
                        PendingInviteRow(invite: invite)
                            .swipeActions {
                                Button("Cancel Invite", role: .destructive) {
                                    Task { await model.revokeInvite(invite) }
                                }
                            }
                    }
                }
                .listRowBackground(BenitoGlassListRowBackground())
            }

            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.fault)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .readableContentWidth()
        .background(DesignTokens.bgCanvas.ignoresSafeArea())
        .navigationTitle("Sharing")
        .navigationBarTitleDisplayMode(.inline)
        .benitoNavigationBarGlass()
        .task(id: model.isSignedIn) {
            guard model.isSignedIn else { return }
            await load()
            // `SIMCTL_CHILD_BENITO_PROTOTYPE_SHEET=invite` opens the invite sheet (screenshots only).
            if ProcessInfo.processInfo.environment["BENITO_PROTOTYPE_SHEET"] == "invite", model.isParent {
                showInvite = true
            }
        }
        .refreshable { await load() }
        .onAppear { SharingTip().invalidate(reason: .actionPerformed) }
        .sheet(isPresented: $showInvite, onDismiss: { Task { await load() } }) {
            InviteSheet(model: model)
        }
        .confirmationDialog(
            "Stop sharing with \(memberToRemove?.name ?? "")?",
            isPresented: Binding(
                get: { memberToRemove != nil },
                set: { if !$0 { memberToRemove = nil } }
            ),
            titleVisibility: .visible,
            presenting: memberToRemove
        ) { member in
            Button("Remove \(member.name)", role: .destructive) {
                Task { await model.removeMember(member) }
            }
        } message: { _ in
            Text("They'll be signed out on every device and won't see new activity. You can invite them again later.")
        }
    }

    private func canRemove(_ member: FamilyMemberDTO) -> Bool {
        model.isParent && !member.isYou
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await model.refreshSharing()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct MemberRow: View {
    let member: FamilyMemberDTO

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: member.name, tint: member.role == .caregiver ? DesignTokens.sleep : DesignTokens.feed)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.name).font(.body.weight(.semibold))
                    if member.isYou {
                        Text("You")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DesignTokens.bgCardElevated, in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts: [String] = [member.role == .caregiver ? "Caregiver" : "Parent"]
        if let until = member.accessExpiresAt {
            parts.append("until \(until.formatted(date: .abbreviated, time: .shortened))")
        }
        if !member.isYou {
            if let seen = member.lastSeenAt {
                parts.append("active \(seen.formatted(.relative(presentation: .named)))")
            } else {
                parts.append("not opened yet")
            }
        }
        return parts.joined(separator: " · ")
    }
}

private struct PendingInviteRow: View {
    let invite: FamilyInviteDTO

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hourglass")
                .foregroundStyle(DesignTokens.diaper)
                .frame(width: 36, height: 36)
                .background(DesignTokens.diaper.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.role == .caregiver ? "Caregiver invite" : "Parent invite")
                    .font(.body.weight(.semibold))
                Text("Expires \(invite.expiresAt.formatted(.relative(presentation: .named)))")
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Initial on a warm tinted circle.
struct Avatar: View {
    let name: String
    let tint: Color

    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(.headline)
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.18), in: Circle())
            .accessibilityHidden(true)
    }
}
