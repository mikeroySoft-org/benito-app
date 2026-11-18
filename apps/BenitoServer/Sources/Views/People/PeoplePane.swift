import SwiftUI

struct PeoplePane: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if !model.isRunning {
                ServerUnavailableView()
            } else if model.families.isEmpty {
                ContentUnavailableView(
                    "No Families Yet",
                    systemImage: "person.2",
                    description: Text("A family appears here after someone sets up Benito on a phone with this server.")
                )
            } else {
                Form {
                    ForEach(model.families) { family in
                        FamilySection(family: family)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Invite…", systemImage: "person.badge.plus") {
                    model.showInvite()
                }
                .disabled(!model.isRunning)
                .help("Invite a phone to a family")
            }
        }
        .sheet(isPresented: $model.isInviteSheetPresented) {
            InviteSheet()
                .environment(model)
        }
        .task(id: model.isRunning) {
            await model.refreshPeople()
        }
    }
}
