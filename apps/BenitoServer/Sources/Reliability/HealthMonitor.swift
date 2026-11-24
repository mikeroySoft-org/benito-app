import Foundation
import UserNotifications

/// Watches the server while the app runs and posts one notification when something goes wrong.
@MainActor
final class HealthMonitor {
    static let shared = HealthMonitor()
    /// The `UserDefaults` key behind the Notifications switch in the Reliability pane.
    static let notifyKey = "notifyProblems"

    private static let interval: Duration = .seconds(30)
    private static let downGrace: TimeInterval = 60

    private let notifier = ProblemNotifier()
    private var tracker = HealthTracker()
    private var downSince: Date?
    private var task: Task<Void, Never>?

    private init() {}

    /// Safe to call more than once; only the first call starts the loop.
    func start(watching model: ServerModel) {
        guard task == nil else { return }
        UNUserNotificationCenter.current().delegate = notifier
        task = Task {
            while !Task.isCancelled {
                await check(model)
                do {
                    try await Task.sleep(for: Self.interval)
                } catch {
                    return
                }
            }
        }
    }

    private func check(_ model: ServerModel) async {
        guard UserDefaults.standard.bool(forKey: Self.notifyKey) else {
            // Forget everything, so a problem that is still there when the switch goes back on
            // is announced then.
            tracker = HealthTracker()
            downSince = nil
            return
        }

        var observed: [HealthCondition: Bool] = [:]
        var details: [HealthCondition: String] = [:]

        if let isDown = serverIsDown(model) {
            observed[.serverDown] = isDown
        }
        if model.isRunning, let status = model.status {
            observed[.backupFailed] = status.backup.lastError != nil
            details[.backupFailed] = status.backup.lastError
            observed[.backupOverdue] = status.backup.isOverdue(serverStartedAt: status.startedAt)
        }
        if let free = await StorageProbe.freeBytes(at: model.databaseLocation) {
            observed[.lowDisk] = free < StorageProbe.lowSpaceBytes
            details[.lowDisk] = Format.bytes(free)
        }

        for condition in tracker.update(observed) {
            await notifier.post(condition, detail: details[condition])
        }
    }

    /// `nil` while it is too early to say (the first check has not finished).
    private func serverIsDown(_ model: ServerModel, now: Date = .now) -> Bool? {
        switch model.connection {
        case .checking:
            return nil
        case .running, .legacy:
            downSince = nil
            return false
        case .stopped, .notInstalled:
            guard model.isServiceManaged else {
                downSince = nil
                return false
            }
            let since = downSince ?? now
            downSince = since
            return now.timeIntervalSince(since) > Self.downGrace
        }
    }
}
