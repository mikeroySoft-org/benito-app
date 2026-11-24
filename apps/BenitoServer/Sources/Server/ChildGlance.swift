import BenitoKit
import Foundation

/// One child in `GET /admin/glance`.
struct ChildGlance: Decodable, Sendable, Hashable, Identifiable {
    var childId: String
    var childName: String
    var familyId: String
    var familyName: String
    var lastFeed: EventDTO?
    var lastDiaper: EventDTO?
    var lastMedicine: EventDTO?
    var activeTimer: TimerDTO?

    var id: String { childId }

    enum CodingKeys: String, CodingKey {
        case childId = "child_id"
        case childName = "child_name"
        case familyId = "family_id"
        case familyName = "family_name"
        case lastFeed = "last_feed"
        case lastDiaper = "last_diaper"
        case lastMedicine = "last_medicine"
        case activeTimer = "active_timer"
    }
}
