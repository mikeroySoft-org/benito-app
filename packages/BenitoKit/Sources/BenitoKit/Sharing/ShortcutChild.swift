import Foundation

/// The family's selected child, cached so Siri App Shortcuts can donate the child's name.
/// The first (and currently only) child is enough.
public struct ShortcutChild: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// `EntityQuery` behavior for donated Siri child names, over an in-memory list.
public struct ShortcutChildQuery: Sendable {
    public var children: [ShortcutChild]

    public init(children: [ShortcutChild]) {
        self.children = children
    }

    public func entities(for identifiers: [UUID]) -> [ShortcutChild] {
        ShortcutChildStore.entities(for: identifiers, in: children)
    }

    public func suggestedEntities() -> [ShortcutChild] {
        children
    }
}

/// Persists the selected child in UserDefaults for App Intents and the shortcut query.
/// Keys match the ones the intent backend already used.
public enum ShortcutChildStore: Sendable {
    public static let idKey = "benito.intent.childId"
    public static let nameKey = "benito.intent.childName"

    public static func load(from defaults: UserDefaults = .standard) -> [ShortcutChild] {
        guard let raw = defaults.string(forKey: idKey), let id = UUID(uuidString: raw) else { return [] }
        let trimmed = defaults.string(forKey: nameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return [] }
        return [ShortcutChild(id: id, name: trimmed)]
    }

    /// Keeps the first child only (one baby per family today). An empty list clears the cache.
    public static func save(_ children: [ShortcutChild], to defaults: UserDefaults = .standard) {
        guard let first = children.first else {
            clear(from: defaults)
            return
        }
        let name = first.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            clear(from: defaults)
            return
        }
        defaults.set(first.id.uuidString, forKey: idKey)
        defaults.set(name, forKey: nameKey)
    }

    public static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: idKey)
        defaults.removeObject(forKey: nameKey)
    }

    /// Preserves the identifier order and drops ids that aren't in `children`.
    public static func entities(for identifiers: [UUID], in children: [ShortcutChild]) -> [ShortcutChild] {
        let map = Dictionary(uniqueKeysWithValues: children.map { ($0.id, $0) })
        return identifiers.compactMap { map[$0] }
    }
}
