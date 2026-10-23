import Foundation

/// Who owns the data in on-device mode. Stands in for the server's user and family rows,
/// kept in the store's preferences so it lives and dies with the local database.
public struct LocalProfile: Sendable, Equatable {
    public var userId: UUID
    public var userName: String
    public var familyId: UUID
    public var familyName: String
    public var createdAt: Date

    public init(userId: UUID, userName: String, familyId: UUID, familyName: String, createdAt: Date) {
        self.userId = userId
        self.userName = userName
        self.familyId = familyId
        self.familyName = familyName
        self.createdAt = createdAt
    }

    enum Key {
        static let userId = "local.user_id"
        static let userName = "local.user_name"
        static let familyId = "local.family_id"
        static let familyName = "local.family_name"
        static let createdAt = "local.created_at"
    }

    /// The saved profile, or nil before on-device setup (or after it moved to a server).
    public static func load(from store: any BenitoStore) async throws -> LocalProfile? {
        guard let user = try await store.preference(Key.userId).flatMap(UUID.init(uuidString:)),
              let family = try await store.preference(Key.familyId).flatMap(UUID.init(uuidString:))
        else { return nil }
        let created = try await store.preference(Key.createdAt)
            .flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)) ?? Date.now
        return LocalProfile(
            userId: user,
            userName: try await store.preference(Key.userName) ?? "",
            familyId: family,
            familyName: try await store.preference(Key.familyName) ?? "",
            createdAt: created
        )
    }

    public func save(to store: any BenitoStore) async throws {
        try await store.setPreference(Key.userId, value: userId.uuidString)
        try await store.setPreference(Key.userName, value: userName)
        try await store.setPreference(Key.familyId, value: familyId.uuidString)
        try await store.setPreference(Key.familyName, value: familyName)
        try await store.setPreference(Key.createdAt, value: String(createdAt.timeIntervalSince1970))
    }

    /// Forgets the profile (the events stay; after a server move they belong to the server child).
    public static func clear(from store: any BenitoStore) async throws {
        for key in [Key.userId, Key.userName, Key.familyId, Key.familyName, Key.createdAt] {
            try await store.setPreference(key, value: "")
        }
    }
}
