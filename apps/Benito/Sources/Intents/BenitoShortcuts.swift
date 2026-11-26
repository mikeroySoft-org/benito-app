import AppIntents
import BenitoKit
import Foundation

/// Siri phrases. Every App Shortcut phrase must include the app name
/// (`\(.applicationName)`). App Store builds accept "Benito", "Baby Tracker", and
/// "Benito Baby Tracker". Source builds can also add `BENITO_SIRI_NAME` in
/// Local.xcconfig as an extra alternative app name.
///
/// Key phrases also include the donated child (`\(\.$child)`), so after sign-in
/// you can say "Sam started a nap with Benito". A phrase can only bind one
/// parameter, so left/right/bottle and wet/dirty stay on the app-name forms.
/// The child list is refreshed with `BenitoShortcuts.updateAppShortcutParameters()`
/// on sign-in, a child-name change, and sign-out.
///
/// Phrases lead with the app or child name where they can, and prefer "nap",
/// "feed", and "crying" over generic "sleep" or "timer" wording so they don't
/// collide with system Sleep or Timer commands.
///
/// There are ten App Shortcuts — the system maximum — so new intents must merge
/// into an existing shortcut.
///
/// Nursing / feeding phrases omit `\(\.$choice)` unless the phrase is meant to
/// bind left, right, or bottle. `StartFeedIntent.choice` is required and has a
/// request dialog, so "Benito is nursing" starts a feed and Siri asks
/// "Left, right, or bottle?".
///
/// `StopTimerIntent` takes no side, so "done feeding" doesn't prompt for one.
struct BenitoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartFeedIntent(),
            phrases: [
                "\(.applicationName) started a feed",
                "\(.applicationName) started a \(\.$choice) feed",
                "\(.applicationName) is feeding",
                "\(.applicationName) is nursing",
                "Start a feed for \(.applicationName)",
                "I'm feeding \(.applicationName)",
                "\(\.$child) started a feed with \(.applicationName)",
                "\(\.$child) is feeding with \(.applicationName)",
                "\(\.$child) is nursing with \(.applicationName)",
                "Start a feed for \(\.$child) with \(.applicationName)",
                "I'm feeding \(\.$child) with \(.applicationName)",
            ],
            shortTitle: "Start Feed",
            systemImageName: "drop.fill"
        )
        AppShortcut(
            intent: StartNapIntent(),
            phrases: [
                "\(.applicationName) started a nap",
                "\(.applicationName) is napping",
                "Start a nap for \(.applicationName)",
                "put \(.applicationName) down for a nap",
                "\(\.$child) started a nap with \(.applicationName)",
                "\(\.$child) is napping with \(.applicationName)",
                "Start a nap for \(\.$child) with \(.applicationName)",
                "put \(\.$child) down for a nap with \(.applicationName)",
            ],
            shortTitle: "Start Nap",
            systemImageName: "bed.double.fill"
        )
        AppShortcut(
            intent: StartOutingIntent(),
            phrases: [
                "Start a \(\.$choice) with \(.applicationName)",
                "\(.applicationName) is going on a \(\.$choice)",
                "Start a walk with \(.applicationName)",
                "\(.applicationName) is going for a walk",
                "Start a car ride with \(.applicationName)",
                "\(.applicationName) is going for a car ride",
            ],
            shortTitle: "Start Walk or Ride",
            systemImageName: "figure.walk"
        )
        AppShortcut(
            intent: StartCryingIntent(),
            phrases: [
                "Start crying with \(.applicationName)",
                "\(.applicationName) is crying",
                "\(.applicationName) started crying",
                "\(.applicationName) is fussy",
            ],
            shortTitle: "Start Crying Timer",
            systemImageName: "cloud.rain.fill"
        )
        AppShortcut(
            intent: PauseTimerIntent(),
            phrases: [
                "Pause \(.applicationName)'s feed",
                "Pause \(.applicationName)'s nap",
                "Pause \(.applicationName)'s crying",
            ],
            shortTitle: "Pause Timer",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeTimerIntent(),
            phrases: [
                "Resume \(.applicationName)'s feed",
                "Resume \(.applicationName)'s nap",
                "Resume \(.applicationName)'s crying",
            ],
            shortTitle: "Resume Timer",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: StopTimerIntent(),
            phrases: [
                "\(.applicationName) woke up",
                "\(\.$child) woke up in \(.applicationName)",
                "\(.applicationName) is done feeding",
                "\(\.$child) is done feeding in \(.applicationName)",
                "done feeding \(.applicationName)",
                "done feeding \(\.$child) with \(.applicationName)",
                "we're done feeding \(.applicationName)",
                "we're done feeding \(\.$child) with \(.applicationName)",
                "done nursing \(.applicationName)",
                "done nursing \(\.$child) with \(.applicationName)",
                "Stop \(.applicationName)'s walk",
                "Stop \(.applicationName)'s car ride",
                "Stop \(.applicationName)'s crying",
                "\(.applicationName) stopped crying",
            ],
            shortTitle: "Stop Timer",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: LogDiaperIntent(),
            phrases: [
                "\(.applicationName) had a diaper change",
                "Log a diaper for \(.applicationName)",
                "\(.applicationName) has a \(\.$kind) diaper",
                "change \(.applicationName)'s diaper",
                "\(\.$child) had a diaper change in \(.applicationName)",
                "Log a diaper for \(\.$child) with \(.applicationName)",
                "change \(\.$child)'s diaper with \(.applicationName)",
            ],
            shortTitle: "Log Diaper",
            systemImageName: "circle.grid.cross.fill"
        )
        AppShortcut(
            intent: LogMedicineIntent(),
            phrases: [
                "\(.applicationName) took medicine",
                "Log medicine for \(.applicationName)",
                "give \(.applicationName) medicine",
                "\(.applicationName) took meds",
            ],
            shortTitle: "Log Medicine",
            systemImageName: "pills.fill"
        )
        AppShortcut(
            intent: LogPumpIntent(),
            phrases: [
                "\(.applicationName) pumped",
                "Log a pump for \(.applicationName)",
                "I pumped for \(.applicationName)",
            ],
            shortTitle: "Log Pump",
            systemImageName: "drop.halffull"
        )
    }
}

/// Writes the selected child for `ChildEntityQuery` and tells Siri to pick up the new name.
enum BenitoShortcutRefresh {
    static func publish(id: UUID?, name: String?) {
        if let id {
            let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                ShortcutChildStore.save([ShortcutChild(id: id, name: trimmed)])
                BenitoShortcuts.updateAppShortcutParameters()
                return
            }
        }
        ShortcutChildStore.clear()
        BenitoShortcuts.updateAppShortcutParameters()
    }
}
