import SwiftUI
import TipKit
import BenitoKit

/// First-run hints. Each shows once (until reset from Account), in a calm order on Home:
/// feed, then diaper, then Siri.
enum BenitoTips {
    private static let resetKey = "benito.tips.resetOnLaunch"

    /// Call once at launch, before any view reads a tip.
    static func configure() {
        if UserDefaults.standard.bool(forKey: resetKey) {
            UserDefaults.standard.removeObject(forKey: resetKey)
            try? Tips.resetDatastore()
        }
        if ProcessInfo.processInfo.environment["BENITO_SHOW_ALL_TIPS"] == "1" {
            Tips.showAllTipsForTesting()
        }
        do {
            try Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.applicationDefault)])
        } catch {
            BenitoLog.ui.error("tips configure failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// TipKit can only wipe its store before `configure`, so the reset lands on next launch.
    static func requestReset() {
        UserDefaults.standard.set(true, forKey: resetKey)
    }

    static var resetPending: Bool {
        UserDefaults.standard.bool(forKey: resetKey)
    }
}

struct LogFeedTip: Tip {
    var title: Text { Text("Log a feed") }
    var message: Text? {
        Text("Tap here to start a nursing timer or log a bottle. Everyone in your family sees it right away.")
    }
    var image: Image? { Image(systemName: "drop.fill") }
}

struct LogDiaperTip: Tip {
    var title: Text { Text("Diapers in two taps") }
    var message: Text? { Text("Tap Diaper, then Wet, Dirty, or Both. Benito keeps the daily count for you.") }
    var image: Image? { Image(systemName: "circle.grid.cross.fill") }
}

struct SiriLoggingTip: Tip {
    var title: Text { Text("Hands full? Ask Siri") }
    var message: Text? {
        Text("Say “Siri, Benito started a feed” or “Siri, Benito is napping”. No need to unlock your phone.")
    }
    var image: Image? { Image(systemName: "mic.fill") }
}

struct TimelineDayTip: Tip {
    var title: Text { Text("See the whole day") }
    var message: Text? { Text("Switch to Day to see feeds, sleep, and diapers laid out hour by hour.") }
    var image: Image? { Image(systemName: "calendar.day.timeline.left") }
}

struct SharingTip: Tip {
    var title: Text { Text("Share with your family") }
    var message: Text? {
        Text("Invite a partner or babysitter by Messages, AirDrop, or SharePlay. No passwords to set up.")
    }
    var image: Image? { Image(systemName: "person.2.fill") }
}
