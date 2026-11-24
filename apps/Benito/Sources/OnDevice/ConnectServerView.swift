import SwiftUI

/// Account › Connect to a server: copies this iPhone's history to a family server, then syncs.
/// Safe to leave and come back; a move that stopped partway carries on from where it was.
struct ConnectServerView: View {
    let model: AppModel
    @State private var browser = ServerBrowser()
    @State private var manual = ""
    @State private var errorText: String?
    @State private var isWorking = false

    var body: some View {
        List {
            Section {
                Text("Your log is copied to the server, then this \(BenitoDevice.name) syncs with it like any other family member. Nothing is deleted if the move stops partway; tap Connect again to finish.")
                    .font(.subheadline)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .listRowBackground(Color.clear)

            if let pending = model.pendingServerMove, pending.serverChildId != nil {
                Section("Unfinished move") {
                    Button {
                        if let url = URL(string: pending.serverURL) { connect(url) }
                    } label: {
                        LabeledContent("Finish moving to", value: pending.serverURL)
                    }
                    .disabled(isWorking)
                }
                .listRowBackground(BenitoGlassListRowBackground())
            }

            Section {
                ForEach(browser.found) { server in
                    Button { connect(server.url) } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(server.name).foregroundStyle(DesignTokens.textPrimary)
                                Text(server.url.absoluteString)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(DesignTokens.textSecondary)
                            }
                        } icon: {
                            Image(systemName: "server.rack").foregroundStyle(DesignTokens.sleep)
                        }
                    }
                    .disabled(isWorking)
                }
                if browser.found.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking on this Wi-Fi…").foregroundStyle(DesignTokens.textSecondary)
                    }
                }
            } header: {
                Text("On this network")
            }
            .listRowBackground(BenitoGlassListRowBackground())

            Section {
                TextField("http://192.168.1.20:8787", text: $manual)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(connectManual)
                    .font(.body.monospaced())
                Button("Connect", action: connectManual)
                    .disabled(manual.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            } header: {
                Text("Or enter an address")
            } footer: {
                Text("Your Tailscale address works too.")
            }
            .listRowBackground(BenitoGlassListRowBackground())

            if let move = model.serverMove {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(progressText(move.phase))
                    }
                }
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.fault)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .readableContentWidth()
        .background(DesignTokens.bgCanvas.ignoresSafeArea())
        .navigationTitle("Connect to a server")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func progressText(_ phase: ServerMoveProgress.Phase) -> String {
        switch phase {
        case .connecting:
            String(localized: "Connecting…")
        case .uploading(let done, let total):
            String(localized: "Copying \(done) of \(total) entries…")
        case .finishing:
            String(localized: "Switching to the server…")
        }
    }

    private func connectManual() {
        guard let value = ServerURLField.normalized(manual), let url = URL(string: value) else {
            errorText = String(localized: "That doesn't look like a server address.")
            return
        }
        connect(url)
    }

    private func connect(_ url: URL) {
        guard !isWorking else { return }
        isWorking = true
        errorText = nil
        Task {
            defer { isWorking = false }
            do {
                try await model.connectToServer(url)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
