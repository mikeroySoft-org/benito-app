import Foundation

enum StorageProbe {
    static let lowSpaceBytes: Int64 = 1_000_000_000

    static func facts(database: URL, backupFolder: URL?) async -> StorageFacts {
        StorageFacts(
            freeBytes: readFreeBytes(at: database),
            backupsShareVolume: backupFolder.flatMap { shareVolume(database, $0) }
        )
    }

    /// Free space on the volume that holds `url`, read off the caller's actor.
    static func freeBytes(at url: URL) async -> Int64? {
        readFreeBytes(at: url)
    }

    /// Free space the system would make available for something important. Asked of the folder
    /// when the file itself does not exist yet.
    private static func readFreeBytes(at url: URL) -> Int64? {
        for candidate in [url, url.deletingLastPathComponent()] {
            guard let values = try? candidate.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
            ) else { continue }
            // Volumes that are not APFS report 0 for the "important usage" figure.
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                return important
            }
            if let plain = values.volumeAvailableCapacity {
                return Int64(plain)
            }
        }
        return nil
    }

    private static func shareVolume(_ first: URL, _ second: URL) -> Bool? {
        guard
            let one = volumeIdentifier(of: first),
            let other = volumeIdentifier(of: second)
        else { return nil }
        return one.isEqual(other)
    }

    private static func volumeIdentifier(of url: URL) -> NSObjectProtocol? {
        for candidate in [url, url.deletingLastPathComponent()] {
            if let identifier = try? candidate.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier {
                return identifier
            }
        }
        return nil
    }
}
