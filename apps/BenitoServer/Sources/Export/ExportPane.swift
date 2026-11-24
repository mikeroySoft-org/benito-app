import SwiftUI

/// Saves a family's records to a file: events as CSV, or everything as JSON.
struct ExportPane: View {
    @Environment(ServerModel.self) private var model

    @State private var familyID: String?
    /// `nil` is every child in the family.
    @State private var childID: String?
    @State private var range = ExportRange.allTime
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now
    @State private var customEnd = Date.now
    @State private var isExporting = false
    @State private var savedFile: URL?

    private var family: AdminFamily? {
        model.families.first { $0.id == familyID } ?? model.families.first
    }

    var body: some View {
        Group {
            if !model.isRunning {
                ServerUnavailableView()
            } else if let family {
                Form {
                    choices(for: family)
                    actions(for: family)
                    if let savedFile {
                        ExportSavedSection(file: savedFile)
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "Nothing to Export Yet",
                    systemImage: "square.and.arrow.up",
                    description: Text("A family appears here after someone sets up Benito on a phone with this server.")
                )
            }
        }
        .task(id: model.isRunning) {
            await model.refreshPeople()
            if familyID == nil {
                familyID = model.families.first?.id
            }
        }
        .onChange(of: familyID) {
            childID = nil
        }
    }

    private func choices(for family: AdminFamily) -> some View {
        Section("What to Export") {
            if model.families.count > 1 {
                Picker("Family", selection: $familyID) {
                    ForEach(model.families) { family in
                        Text(family.name).tag(Optional(family.id))
                    }
                }
            }
            Picker("Child", selection: $childID) {
                Text("All Children").tag(String?.none)
                ForEach(family.children) { child in
                    Text(child.name).tag(Optional(child.id))
                }
            }
            Picker("Dates", selection: $range) {
                ForEach(ExportRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            if range == .custom {
                DatePicker("From", selection: $customStart, displayedComponents: .date)
                DatePicker("Through", selection: $customEnd, displayedComponents: .date)
            }
        }
    }

    private func actions(for family: AdminFamily) -> some View {
        Section {
            HStack(spacing: 12) {
                Button("Export CSV…") {
                    Task { await export(family, as: .csv) }
                }
                Button("Export Everything as JSON…") {
                    Task { await export(family, as: .json) }
                }
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Exporting")
                }
            }
            .disabled(isExporting)
        } footer: {
            Text("CSV holds the events for the child and dates chosen above. JSON holds everything for the whole family, whatever is chosen above. The file is your baby's health record: it stays on this Mac unless you send it to someone.")
        }
    }

    private func export(_ family: AdminFamily, as format: ExportFormat) async {
        isExporting = true
        defer { isExporting = false }

        let child = family.children.first { $0.id == childID }
        let bounds = range.bounds(customStart: customStart, customEnd: customEnd)
        let request = ExportRequest(familyID: family.id, childID: child?.id, from: bounds.from, to: bounds.to)
        guard let data = await model.exportData(request, as: format) else { return }

        let subject = format == .csv ? child?.name ?? family.name : family.name
        do {
            let saved = try await ExportSaver.save(
                data,
                suggestedName: ExportFileName.suggested(subject: subject, format: format),
                format: format
            )
            if let saved {
                savedFile = saved
            }
        } catch {
            model.lastError = "The export could not be saved: \(error.localizedDescription)"
        }
    }
}
