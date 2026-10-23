import Foundation

extension Notification.Name {
    /// Posted when a Live Activity (or similar) asks Home to present Feed / Diaper / Sleep.
    static let benitoPendingHomeSheet = Notification.Name("benito.pendingHomeSheet")
}

/// Cross-process-safe handoff: Live Activity buttons enqueue a Home sheet, then
/// `openAppWhenRun` brings Benito forward. Home consumes the request on appear / active.
enum BenitoHomeSheetRequest {
    static let defaultsKey = "benito.pendingHomeSheet"

    /// `feed` | `diaper` | `sleep`
    static func enqueue(_ sheet: String) {
        let normalized = sheet.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["feed", "diaper", "sleep"].contains(normalized) else { return }
        UserDefaults.standard.set(normalized, forKey: defaultsKey)
        NotificationCenter.default.post(name: .benitoPendingHomeSheet, object: normalized)
    }

    /// Returns and clears the pending sheet, if any.
    static func take() -> String? {
        let value = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let value, !value.isEmpty else { return nil }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return value
    }

    /// Peek without clearing (e.g. switch to Home tab before presenting).
    static func peek() -> String? {
        let value = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
