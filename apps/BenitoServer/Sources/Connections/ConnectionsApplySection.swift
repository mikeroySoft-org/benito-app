import SwiftUI

/// What Apply would change, and the one button that writes it and restarts the server.
struct ConnectionsApplySection: View {
    @Environment(ServerModel.self) private var model

    let connections: ConnectionsModel

    var body: some View {
        let plan = connections.plan
        Section {
            if let problem = plan.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if plan.changes.isEmpty {
                Text("Nothing to apply: the server's settings already match the choices above.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(plan.summary, id: \.self) { line in
                    Label(line, systemImage: "arrow.right.circle")
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if model.isServiceManaged {
                    Text("Applying restarts the server. Phones cannot sync for a few seconds; anything logged meanwhile is kept on the phone and sent afterwards.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(
                        "This app cannot apply changes yet, because the server on this Mac is not installed as a service this app controls. Install or adopt the server in this app first.",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button("Apply") {
                    Task { await connections.apply(to: model) }
                }
                .disabled(plan.changes.isEmpty || !model.isServiceManaged || connections.isApplying)
                if connections.isApplying {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving and restarting the server…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Changes to Apply")
        }
    }
}
