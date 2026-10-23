import Foundation
import OSLog

/// Unified OSLog loggers for Benito. Subsystem matches the iOS app bundle id
/// (`com.mikeroysoft.benito`) so `scripts/stream-device-logs.sh` can predicate on it.
public enum BenitoLog {
    public static let subsystem = "com.mikeroysoft.benito"

    public static let api = Logger(subsystem: subsystem, category: "api")
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
