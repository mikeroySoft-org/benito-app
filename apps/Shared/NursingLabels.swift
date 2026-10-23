import Foundation

/// User-facing nursing labels. Internal API / enum cases stay `L` / `R` / `feed_breast`.
enum NursingLabels {
    /// Visible title: "Nursing: Left", "Nursing: Right", or "Nursing".
    static func title(side: String?) -> String {
        switch side?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "L", "LEFT": return "Nursing: Left"
        case "R", "RIGHT": return "Nursing: Right"
        default: return "Nursing"
        }
    }

    /// VoiceOver / spoken title.
    static func spoken(side: String?) -> String {
        switch side?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "L", "LEFT": return "Nursing left"
        case "R", "RIGHT": return "Nursing right"
        default: return "Nursing"
        }
    }

    /// Compact Smart Stack / chip-sized label while a nursing timer runs.
    static func short(side: String?) -> String {
        switch side?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "L", "LEFT": return "Left"
        case "R", "RIGHT": return "Right"
        default: return "Nursing"
        }
    }
}
