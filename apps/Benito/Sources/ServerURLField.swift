import SwiftUI

/// Server URL editor that only commits on Return / Connect, so typing doesn't tear down the
/// session on every keystroke. Invalid input is never written to storage.
struct ServerURLField: View {
    @Binding var serverURLString: String
    let onCommit: (String) -> Void

    @State private var draft: String
    @State private var showInvalid = false

    init(serverURLString: Binding<String>, onCommit: @escaping (String) -> Void) {
        _serverURLString = serverURLString
        self.onCommit = onCommit
        _draft = State(initialValue: serverURLString.wrappedValue)
    }

    /// Trimmed URL with a single trailing `/` removed, or nil unless it is an absolute
    /// `http`/`https` URL with a non-empty host.
    static func normalized(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private var hasPendingChange: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines) != serverURLString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(
                    "Server URL",
                    text: $draft,
                    prompt: Text(verbatim: "https://benito.example.ts.net")
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit(commit)

                if hasPendingChange {
                    Button("Connect", action: commit)
                        .buttonStyle(.borderless)
                }
            }
            if showInvalid {
                Text(verbatim: "Enter a full URL like https://<machine>.<tailnet>.ts.net")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: serverURLString) { _, newValue in
            // External writes (e.g. Simulator preset) replace the draft.
            if draft != newValue {
                draft = newValue
                showInvalid = false
            }
        }
        .onChange(of: draft) { _, _ in
            showInvalid = false
        }
    }

    private func commit() {
        guard let url = Self.normalized(draft) else {
            showInvalid = true
            return
        }
        draft = url
        guard url != serverURLString else { return }
        serverURLString = url
        onCommit(url)
    }
}
