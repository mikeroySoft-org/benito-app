import Foundation

/// Picks GRDB on disk when available; otherwise in-memory.
public enum LocalStoreFactory {
    public static let defaultDatabaseFileName = "benito.sqlite"

    /// Application Support/Benito/benito.sqlite on Apple platforms; falls back to InMemoryStore.
    public static func makeDefault(stateRefetcher: (any StateRefetching)? = nil) -> any BenitoStore {
        #if canImport(GRDB)
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let folder = dir.appendingPathComponent("Benito", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = folder.appendingPathComponent(defaultDatabaseFileName).path
                return try GRDBStore(path: path, stateRefetcher: stateRefetcher)
            } catch {
                // Fall through to in-memory.
            }
        }
        #endif
        return InMemoryStore(stateRefetcher: stateRefetcher)
    }

    /// Explicit path (tests / custom containers).
    public static func makeGRDB(path: String, stateRefetcher: (any StateRefetching)? = nil) throws -> any BenitoStore {
        #if canImport(GRDB)
        return try GRDBStore(path: path, stateRefetcher: stateRefetcher)
        #else
        _ = path
        _ = stateRefetcher
        throw StoreFactoryError.grdbUnavailable
        #endif
    }
}

public enum StoreFactoryError: Error, Sendable {
    case grdbUnavailable
}
