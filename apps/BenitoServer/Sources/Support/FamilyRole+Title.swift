import BenitoKit

extension FamilyRole {
    var title: String {
        switch self {
        case .parent: "Parent"
        case .caregiver: "Caregiver"
        }
    }
}
