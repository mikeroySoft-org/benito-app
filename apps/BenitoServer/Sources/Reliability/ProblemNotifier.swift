import Foundation
import UserNotifications

/// Posts local notifications, and lets them show while the app's window is in front.
final class ProblemNotifier: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// The condition is the identifier, so a second post about it replaces the first.
    func post(_ condition: HealthCondition, detail: String?) async {
        let content = UNMutableNotificationContent()
        content.title = condition.title
        content.body = condition.body(detail: detail)
        content.sound = .default
        let request = UNNotificationRequest(identifier: condition.rawValue, content: content, trigger: nil)
        // Fails only when notifications are not allowed, which the Reliability pane already shows.
        try? await UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
