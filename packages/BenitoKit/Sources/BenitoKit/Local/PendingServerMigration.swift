import Foundation

/// A move from on-device to a family server that has started but not finished. Saved before
/// each step so a crash, kill or lost connection resumes where it stopped instead of
/// creating a second family or duplicate entries.
public struct PendingServerMigration: Codable, Sendable, Equatable {
    public var serverURL: String
    public var localChildId: UUID
    /// Set once the server family exists; the uploads go to this child.
    public var serverChildId: UUID?

    public init(serverURL: String, localChildId: UUID, serverChildId: UUID? = nil) {
        self.serverURL = serverURL
        self.localChildId = localChildId
        self.serverChildId = serverChildId
    }

    public static let defaultsKey = "benito.pendingServerMigration"

    public static func load(_ defaults: UserDefaults = .standard) -> PendingServerMigration? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    public static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
