import SwiftUI

struct LogsPane: View {
    @Environment(ServerModel.self) private var model

    @State private var lines: [String] = []
    @State private var visibleText = ""
    @State private var visibleLineCount = 0
    @State private var isMissing = false
    @State private var filter = ""

    private var logPath: String { model.home.logFile.path(percentEncoded: false) }

    var body: some View {
        VStack(spacing: 0) {
            LogsToolbar(
                filter: $filter,
                summary: summary,
                canReveal: !isMissing,
                reveal: { Desktop.revealInFinder(model.home.logFile) }
            )
            Divider()
            if isMissing {
                ContentUnavailableView(
                    "No Log File Yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("The server writes its log to \(logPath). It appears here once a server has run.")
                )
            } else {
                LogTextView(text: visibleText)
            }
        }
        .onChange(of: filter) {
            applyFilter()
        }
        .task {
            await follow()
        }
    }

    private var summary: String {
        if isMissing { return "" }
        return filter.isEmpty
            ? "\(lines.count) lines"
            : "\(visibleLineCount) of \(lines.count) lines"
    }

    /// Runs while the pane is visible; SwiftUI cancels it when the pane goes away.
    private func follow() async {
        let reader = LogTailReader(url: model.home.logFile)
        while !Task.isCancelled {
            switch await reader.read() {
            case .unchanged:
                break
            case .missing:
                isMissing = true
                lines = []
                applyFilter()
            case .lines(let newLines):
                isMissing = false
                lines = newLines
                applyFilter()
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func applyFilter() {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let visible = needle.isEmpty
            ? lines
            : lines.filter { $0.localizedCaseInsensitiveContains(needle) }
        visibleLineCount = visible.count
        visibleText = visible.joined(separator: "\n")
    }
}
