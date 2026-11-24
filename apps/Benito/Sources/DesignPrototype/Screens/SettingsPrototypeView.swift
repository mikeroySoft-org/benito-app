import ActivityKit
import SwiftUI
import TipKit
import UIKit

/// Settings stays a grouped List — acceptable for Account/Server URL (secondary).
struct SettingsPrototypeView: View {
    @Binding var serverURLString: String
    @Bindable var model: AppModel
    @AppStorage(LiveActivitySettings.enabledKey) private var liveActivityEnabled = true
    @State private var confirmLeave = false
    @State private var confirmSignOut = false
    @State private var confirmDeleteAccount = false
    /// Whether deleting the account also deletes the family; nil when the member list didn't load.
    @State private var deleteRemovesFamily: Bool?
    @State private var confirmErase = false
    /// A delete or erase is being prepared or is running.
    @State private var removalInFlight = false
    @State private var tipsResetRequested = BenitoTips.resetPending
    /// `SIMCTL_CHILD_BENITO_PROTOTYPE_SHEET` = sharing | invite opens Account › Sharing (screenshots).
    @State private var showSharing = ["sharing", "invite"]
        .contains(ProcessInfo.processInfo.environment["BENITO_PROTOTYPE_SHEET"] ?? "")
    /// `SIMCTL_CHILD_BENITO_PROTOTYPE_SHEET` = connect opens Account › Connect to a server (screenshots).
    @State private var showConnect = ProcessInfo.processInfo.environment["BENITO_PROTOTYPE_SHEET"] == "connect"
    /// False on iPad / devices without Live Activities, or when the user turned them off in Settings.
    @State private var liveActivitiesAvailable = ActivityAuthorizationInfo().areActivitiesEnabled

    var body: some View {
        NavigationStack {
            List {
                if liveActivitiesAvailable {
                    Section {
                        Toggle("Show in Dynamic Island & Lock Screen", isOn: $liveActivityEnabled)
                        Text("Shows the running feed/sleep timer and time since the last diaper. Updates while Benito is open; partner-started timers appear when you open the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Dynamic Island")
                    }
                    .listRowBackground(BenitoGlassListRowBackground())
                }

                if model.isOnDevice {
                    Section {
                        LabeledContent("Saved on", value: String(localized: "This \(BenitoDevice.name) only"))
                        NavigationLink {
                            ConnectServerView(model: model)
                        } label: {
                            Label(
                                model.pendingServerMove?.serverChildId != nil ? "Finish connecting to a server" : "Connect to a server",
                                systemImage: "server.rack"
                            )
                        }
                    } header: {
                        Text("Storage")
                    } footer: {
                        Text("Works with no server or account. Connect one to share with a partner or caregiver; your history comes along.")
                    }
                    .listRowBackground(BenitoGlassListRowBackground())

                    Section {
                        Button("Erase all data…", role: .destructive) { confirmErase = true }
                            .disabled(removalInFlight)
                    }
                    .listRowBackground(BenitoGlassListRowBackground())
                } else {
                Section("Server") {
                    ServerURLField(serverURLString: $serverURLString) { url in
                        Task { await model.applyServerURL(url) }
                    }

                    #if targetEnvironment(simulator)
                    Button("Use simulator loopback") {
                        serverURLString = BenitoServerPresets.loopback
                        Task { await model.applyServerURL(BenitoServerPresets.loopback) }
                    }
                    #endif

                    Button("Probe /health") { Task { await model.probeHealth() } }

                    LabeledContent("Sync", value: model.syncConnected ? "connected" : "offline")
                    Text(model.storeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if model.outboxPending > 0 {
                        LabeledContent("Waiting to sync", value: "\(model.outboxPending)")
                    }
                }
                }

                Section("Account") {
                    if model.isSignedIn {
                        HStack(spacing: 12) {
                            Avatar(name: model.accountDisplayName, tint: model.isParent ? DesignTokens.feed : DesignTokens.sleep)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.accountDisplayName).font(.body.weight(.semibold))
                                Text(accountSubtitle)
                                    .font(.footnote)
                                    .foregroundStyle(DesignTokens.textSecondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        if let until = model.accessExpiresAt {
                            LabeledContent("Access until", value: until.formatted(date: .abbreviated, time: .shortened))
                        }
                        if !model.isOnDevice {
                            Button("Sign out", role: .destructive) {
                                if model.isPasswordless { confirmSignOut = true } else { model.signOut() }
                            }
                        }
                    } else {
                        TextField("Name", text: $model.name)
                        TextField("Email", text: $model.email)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                        SecureField("Password (min 8)", text: $model.password)
                        Button("Register") { Task { await model.register() } }
                        Button("Login") { Task { await model.login() } }
                    }
                }

                if !model.isSignedIn {
                    Section("Family") {
                        Text("Sign in or register to create or join a family.")
                            .foregroundStyle(.secondary)
                    }
                } else if model.isOnDevice {
                    Section("Family") {
                        LabeledContent("Family", value: model.familyName)
                        LabeledContent("Child", value: model.childName)
                    }
                    .listRowBackground(BenitoGlassListRowBackground())
                } else if model.hasFamily {
                    Section("Family") {
                        LabeledContent("Family", value: model.familyName)
                        LabeledContent("Child", value: model.childName)
                        NavigationLink {
                            SharingView(model: model)
                        } label: {
                            Label("Sharing", systemImage: "person.2.fill")
                        }
                        .popoverTip(model.isParent ? SharingTip() : nil, arrowEdge: .top)
                    }
                    .listRowBackground(BenitoGlassListRowBackground())

                    Section {
                        Button("Leave family…", role: .destructive) { confirmLeave = true }
                    } footer: {
                        Text("For switching families or troubleshooting. The family and its history stay on the server for the other members.")
                    }
                } else {
                    Section {
                        NavigationLink {
                            JoinFamilyView(model: model)
                        } label: {
                            Label("Join a family", systemImage: "person.2.fill")
                        }
                    } header: {
                        Text("Family")
                    } footer: {
                        Text("Someone in the family sends you an invite from Account › Sharing.")
                    }

                    Section("Or start a new family") {
                        TextField("Family name", text: $model.familyName)
                        TextField("Child name", text: $model.childName)
                        Button("Create family") { Task { await model.createFamily() } }
                    }
                }

                if model.isSignedIn, !model.isOnDevice {
                    Section {
                        Button("Delete account…", role: .destructive) {
                            Task { await requestDeleteAccount() }
                        }
                        .disabled(removalInFlight)
                    } footer: {
                        Text("Deletes your account from this server and signs this \(BenitoDevice.name) out.")
                    }
                }

                Section {
                    Button(tipsResetRequested ? "Tips will show next launch" : "Show tips again") {
                        BenitoTips.requestReset()
                        tipsResetRequested = true
                    }
                    .disabled(tipsResetRequested)
                } header: {
                    Text("Tips")
                } footer: {
                    Text("Brings back the first-run hints for logging, the timeline, Siri, and sharing the next time you open Benito.")
                }

                Section("Export") {
                    Button("Export JSON") { Task { await model.exportData() } }
                    Button("Export CSV") { Task { await model.exportCSV() } }
                    if !model.lastExportSummary.isEmpty {
                        Text(model.lastExportSummary)
                            .font(.footnote)
                            .foregroundStyle(DesignTokens.textSecondary)
                    }
                    Text(model.isOnDevice
                        ? "Writes this \(BenitoDevice.name)'s log to a temp file, then opens the share sheet (Files, Mail, Messages…)."
                        : "Fetches from the server, writes a temp file, then opens the share sheet (Files, Mail, Messages…).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Status") {
                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text(AppBuildInfo.footerLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .readableContentWidth()
            .background(DesignTokens.bgCanvas.ignoresSafeArea())
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .benitoNavigationBarGlass()
            .confirmationDialog(
                "Leave \(model.familyName)?",
                isPresented: $confirmLeave,
                titleVisibility: .visible
            ) {
                Button("Leave family", role: .destructive) {
                    Task { await model.leaveFamily() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This phone stops syncing with the family. To come back, your partner invites you again.")
            }
            .confirmationDialog(
                "Sign out of Benito?",
                isPresented: $confirmSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) { model.signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This \(BenitoDevice.name) has no password. To come back, someone in the family sends you a new invite.")
            }
            .confirmationDialog(
                "Delete your account?",
                isPresented: $confirmDeleteAccount,
                titleVisibility: .visible
            ) {
                Button("Delete account", role: .destructive) {
                    Task {
                        removalInFlight = true
                        await model.deleteAccount()
                        removalInFlight = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteAccountMessage)
            }
            .confirmationDialog(
                "Erase everything on this \(BenitoDevice.name)?",
                isPresented: $confirmErase,
                titleVisibility: .visible
            ) {
                Button("Erase all data", role: .destructive) {
                    Task {
                        removalInFlight = true
                        await model.eraseOnDeviceData()
                        removalInFlight = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes the family, baby and every entry saved on this \(BenitoDevice.name). Export first if you want a copy. This can't be undone.")
            }
            .task {
                for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates {
                    liveActivitiesAvailable = enabled
                }
            }
            .navigationDestination(isPresented: $showConnect) {
                ConnectServerView(model: model)
            }
            .navigationDestination(isPresented: $showSharing) {
                SharingView(model: model)
            }
            .sheet(item: $model.exportShareItem) { item in
                BenitoActivityShareSheet(items: [item.url])
                    .benitoSheetDetents()
            }
        }
    }
}

extension SettingsPrototypeView {
    fileprivate var accountSubtitle: String {
        var parts: [String] = []
        if model.hasFamily { parts.append(model.isParent ? "Parent" : "Caregiver") }
        if model.isOnDevice {
            parts.append(String(localized: "Saved on this \(BenitoDevice.name)"))
        } else {
            parts.append(model.isPasswordless ? "Signed in with this \(BenitoDevice.name)" : model.signedInEmail)
        }
        return parts.joined(separator: " · ")
    }

    /// The member list is only loaded by Sharing, so fetch it before saying what gets deleted.
    fileprivate func requestDeleteAccount() async {
        removalInFlight = true
        defer { removalInFlight = false }
        if model.hasFamily {
            let loaded = (try? await model.refreshSharing()) != nil
            // A rejected session signs the app out; there is nothing left to confirm.
            guard model.isSignedIn else { return }
            deleteRemovesFamily = loaded ? model.members.count <= 1 : nil
        } else {
            deleteRemovesFamily = false
        }
        confirmDeleteAccount = true
    }

    fileprivate var deleteAccountMessage: String {
        switch deleteRemovesFamily {
        case true?:
            "You are the only person in \(model.familyName). The family and its whole history are deleted from the server. This can't be undone."
        case false?:
            "Your account, sign-in and devices are removed from the server. Entries you logged stay in the family's history for the other members. This can't be undone."
        case nil:
            "Your account, sign-in and devices are removed from the server. If you are the only person in \(model.familyName), the family and its whole history are deleted too; otherwise entries you logged stay for the other members. This can't be undone."
        }
    }
}

/// Identifiable wrapper so Settings can `.sheet(item:)` a freshly written export file.
struct ExportShareItem: Identifiable, Equatable {
    let id: UUID
    let url: URL

    init(url: URL) {
        self.id = UUID()
        self.url = url
    }
}

/// UIKit share sheet for a temp export file.
struct BenitoActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    SettingsPrototypeView(
        serverURLString: .constant(BenitoServerPresets.loopback),
        model: AppModel(serverURLString: BenitoServerPresets.loopback)
    )
}
