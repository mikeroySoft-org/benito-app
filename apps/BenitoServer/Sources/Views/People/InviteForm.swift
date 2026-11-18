import BenitoKit
import SwiftUI

struct InviteForm: View {
    @Environment(ServerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let onCreated: (CreatedInvite) -> Void

    @State private var familyID: String?
    @State private var role = FamilyRole.parent
    @State private var accessLength = AccessLength.oneDay
    @State private var label = ""
    @State private var isCreating = false

    private var hasAddress: Bool { !model.advertisedURLs.isEmpty }
    private var needsFamilyChoice: Bool { model.families.count > 1 }

    private var canCreate: Bool {
        hasAddress && !isCreating && (!needsFamilyChoice || familyID != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    if needsFamilyChoice {
                        Picker("Family", selection: $familyID) {
                            ForEach(model.families) { family in
                                Text(family.name).tag(Optional(family.id))
                            }
                        }
                    }
                    Picker("Role", selection: $role) {
                        ForEach(FamilyRole.allCases) { role in
                            Text(role.title).tag(role)
                        }
                    }
                    .pickerStyle(.segmented)
                    if role == .caregiver {
                        Picker("Access lasts", selection: $accessLength) {
                            ForEach(AccessLength.allCases) { length in
                                Text(length.title).tag(length)
                            }
                        }
                    }
                    TextField("Label", text: $label, prompt: Text("Optional, for example Grandma's phone"))
                } header: {
                    Text("Invite a Phone")
                } footer: {
                    Text(role == .parent
                        ? "A parent can log everything and manage who is in the family."
                        : "A caregiver can log everything but cannot manage who is in the family.")
                }
                if !hasAddress {
                    Section {
                        Label(
                            "This Mac has no address to put in the invite yet, so a phone could not find the server. The server needs at least one advertised address before it can invite anyone.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            ErrorBanner()
                .padding(.horizontal, 20)

            HStack {
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Creating invite")
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task { await create() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
            .padding(20)
        }
        .task {
            if model.families.isEmpty {
                await model.refreshPeople()
            }
            if familyID == nil {
                familyID = model.families.first?.id
            }
        }
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = InviteRequest(
            familyId: needsFamilyChoice ? familyID : nil,
            role: role,
            expiresInHours: nil,
            accessHours: role == .caregiver ? accessLength.hours : nil,
            label: trimmedLabel.isEmpty ? nil : trimmedLabel
        )
        guard let invite = await model.createInvite(request) else { return }
        guard let created = CreatedInvite(invite: invite) else {
            model.lastError = "The server created the invite but its answer has no secret or address, so there is no link to share. Revoke it under Pending Invites and try again."
            return
        }
        onCreated(created)
    }
}
