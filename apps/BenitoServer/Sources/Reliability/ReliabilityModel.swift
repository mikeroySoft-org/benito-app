import Foundation
import Observation
import ServiceManagement
import UserNotifications

/// What the reliability checklist found the last time it looked at this Mac.
@MainActor
@Observable
final class ReliabilityModel {
    /// The switch in the checklist. Changing it registers or unregisters the login item.
    var opensAtLogin = false

    private(set) var loginItemStatus = SMAppService.Status.notRegistered
    private(set) var loginItemError: String?
    private(set) var autoLoginUser: String?
    private(set) var sleepMinutes = Probed<Int>.pending
    private(set) var firewall = Probed<FirewallState>.pending
    private(set) var storage: StorageFacts?
    private(set) var notificationStatus: UNAuthorizationStatus?
    private(set) var isRefreshing = false

    func refresh(server: ServerModel) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        readLoginItem()
        autoLoginUser = AutoLoginProbe.user()

        let database = server.databaseLocation
        let backupFolder = server.backupFolder
        async let sleep = SleepProbe.read()
        async let firewall = FirewallProbe.read()
        async let storage = StorageProbe.facts(database: database, backupFolder: backupFolder)
        async let notifications = ProblemNotifier.authorizationStatus()
        sleepMinutes = await sleep
        self.firewall = await firewall
        self.storage = await storage
        notificationStatus = await notifications
    }

    /// Brings the login item in line with the switch. Does nothing when they already agree, which
    /// is what happens when a refresh moved the switch.
    func applyOpensAtLogin() {
        let service = SMAppService.mainApp
        guard opensAtLogin != Self.isRegistered(service.status) else { return }
        do {
            if opensAtLogin {
                try service.register()
            } else {
                try service.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        readLoginItem()
    }

    /// Asks macOS for permission to show notifications; macOS only asks the person once.
    func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        notificationStatus = await ProblemNotifier.authorizationStatus()
    }

    private func readLoginItem() {
        loginItemStatus = SMAppService.mainApp.status
        opensAtLogin = Self.isRegistered(loginItemStatus)
    }

    /// Waiting for approval still counts as registered: the person asked for it, and turning the
    /// switch off must withdraw the request.
    private static func isRegistered(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }
}
