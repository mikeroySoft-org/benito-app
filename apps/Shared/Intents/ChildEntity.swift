import AppIntents
import BenitoKit
import Foundation

/// The family's selected child, donated to Siri so phrases can use the baby's name
/// (`\(\.$child)`) instead of only the app name. One child is enough today.
struct ChildEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Child"
    static var defaultQuery = ChildEntityQuery()

    var id: UUID
    var name: String

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    init(_ child: ShortcutChild) {
        self.id = child.id
        self.name = child.name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ChildEntityQuery: EntityQuery {
    init() {}

    func entities(for identifiers: [ChildEntity.ID]) async throws -> [ChildEntity] {
        let children = ShortcutChildStore.load()
        return ShortcutChildQuery(children: children)
            .entities(for: identifiers)
            .map(ChildEntity.init)
    }

    func suggestedEntities() async throws -> [ChildEntity] {
        ShortcutChildStore.load().map(ChildEntity.init)
    }
}
