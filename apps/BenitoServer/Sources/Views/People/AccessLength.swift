import Foundation

/// How long a caregiver's access lasts once they join.
enum AccessLength: String, CaseIterable, Identifiable {
    case eightHours
    case oneDay
    case threeDays
    case oneWeek
    case noEnd

    var id: Self { self }

    var title: String {
        switch self {
        case .eightHours: "8 hours"
        case .oneDay: "1 day"
        case .threeDays: "3 days"
        case .oneWeek: "1 week"
        case .noEnd: "No end"
        }
    }

    var hours: Int? {
        switch self {
        case .eightHours: 8
        case .oneDay: 24
        case .threeDays: 72
        case .oneWeek: 168
        case .noEnd: nil
        }
    }
}
