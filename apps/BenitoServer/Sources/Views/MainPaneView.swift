import SwiftUI

/// The detail column: the selected pane under an error banner.
struct MainPaneView: View {
    @Environment(ServerModel.self) private var model

    let pane: MainPane

    var body: some View {
        Group {
            switch pane {
            case .overview: OverviewPane()
            case .people: PeoplePane()
            case .connections: ConnectionsPane()
            case .backups: BackupsPane()
            case .export: ExportPane()
            case .reliability: ReliabilityPane()
            case .logs: LogsPane()
            }
        }
        .navigationTitle(pane.title)
        .safeAreaInset(edge: .top, spacing: 0) {
            // The invite sheet shows the error itself while it is up.
            if model.lastError != nil, !model.isInviteSheetPresented {
                ErrorBanner()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
        }
    }
}
