import AppIntents

/// Siri phrases. Every phrase must contain `.applicationName`; the `INAlternativeAppNames`
/// entry (`BENITO_SIRI_NAME` in `Config/Local.xcconfig`) makes the child's name ("Sam") count as the app
/// name, so "Siri, Sam started a nap" works. Phrases without the app or child name are not
/// valid App Shortcuts and usually fall through to web search.
///
/// Outing phrases: "Start a walk with Sam", "Sam is going for a car ride", "Stop Sam's walk".
/// Bare "start a walk" can't work: App Shortcut phrases must name the app or child.
///
/// Crying phrases: "Start crying timer with Benito", "Sam is crying", "Stop crying timer with
/// Benito". This is the 10th App Shortcut — the system maximum — so new intents must merge
/// into an existing shortcut.
///
/// Stop phrases cover "done feeding" / "we're done feeding" / "done nursing" with the
/// app or child name. `StopTimerIntent` takes no side, so Siri speaks the stop dialog
/// instead of asking left, right, or bottle.
///
/// Nursing / feeding phrases omit `\(\.$choice)` on purpose. `StartFeedIntent.choice` is
/// required and has a request dialog, so "Sam's nursing" starts a feed and Siri asks
/// "Left, right, or bottle?". Phrases that include `\(\.$choice)` bind left/right/bottle
/// when that word is spoken.
struct BenitoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartFeedIntent(),
            phrases: [
                "\(.applicationName) started a feed",
                "\(.applicationName) is feeding",
                "\(.applicationName) is eating",
                "Start a feed for \(.applicationName)",
                "\(.applicationName) started a \(\.$choice) feed",
                "\(.applicationName)'s nursing",
                "\(.applicationName) is nursing",
                "\(.applicationName) started nursing",
                "started nursing \(.applicationName)",
                "Start nursing \(.applicationName)",
                "nursing \(.applicationName)",
                "\(.applicationName) is being nursed",
                "I'm feeding \(.applicationName)",
                "I'm feeding \(.applicationName) right now",
                "feeding \(.applicationName)",
                "\(.applicationName) is feeding right now",
                "started feeding \(.applicationName)",
                "\(.applicationName) started feeding",
                "\(.applicationName) is nursing \(\.$choice)",
                "\(.applicationName) had a \(\.$choice)",
                "Log a \(\.$choice) for \(.applicationName)",
            ],
            shortTitle: "Start Feed",
            systemImageName: "drop.fill"
        )
        AppShortcut(
            intent: StartNapIntent(),
            phrases: [
                "\(.applicationName) started a nap",
                "\(.applicationName) is napping",
                "\(.applicationName) went to sleep",
                "\(.applicationName) is sleeping",
                "\(.applicationName) is started a nap",
                "put \(.applicationName) to sleep",
                "just put \(.applicationName) to sleep",
                "we just put \(.applicationName) to sleep",
                "we put \(.applicationName) to sleep",
                "\(.applicationName) just went to sleep",
                "\(.applicationName) is going to sleep",
                "\(.applicationName) started sleeping",
                "start a nap for \(.applicationName)",
                "started a nap for \(.applicationName)",
                "\(.applicationName) is taking a nap",
                "put \(.applicationName) down for a nap",
                "\(.applicationName) went down for a nap",
            ],
            shortTitle: "Start Nap",
            systemImageName: "bed.double.fill"
        )
        AppShortcut(
            intent: StartOutingIntent(),
            phrases: [
                "Start a \(\.$choice) with \(.applicationName)",
                "Start a \(\.$choice) for \(.applicationName)",
                "\(.applicationName) is going on a \(\.$choice)",
                "\(.applicationName) started a \(\.$choice)",
                "Start a walk with \(.applicationName)",
                "\(.applicationName) is going for a walk",
                "take \(.applicationName) for a walk",
                "Start a car ride with \(.applicationName)",
                "\(.applicationName) is going for a car ride",
                "take \(.applicationName) for a drive",
                "Start an outing for \(.applicationName)",
            ],
            shortTitle: "Start Walk or Ride",
            systemImageName: "figure.walk"
        )
        AppShortcut(
            intent: StartCryingIntent(),
            phrases: [
                "Start crying timer with \(.applicationName)",
                "Start a crying timer with \(.applicationName)",
                "Start a crying timer for \(.applicationName)",
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
                "Pause \(.applicationName)",
                "Pause \(.applicationName)'s timer",
            ],
            shortTitle: "Pause Timer",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeTimerIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Resume \(.applicationName)'s timer",
            ],
            shortTitle: "Resume Timer",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: StopTimerIntent(),
            phrases: [
                "\(.applicationName) is done",
                "\(.applicationName) woke up",
                "Stop \(.applicationName)'s timer",
                "done feeding \(.applicationName)",
                "we're done feeding \(.applicationName)",
                "we are done feeding \(.applicationName)",
                "\(.applicationName) is done feeding",
                "finished feeding \(.applicationName)",
                "I'm done feeding \(.applicationName)",
                "done nursing \(.applicationName)",
                "we're done nursing \(.applicationName)",
                "\(.applicationName) is done nursing",
                "stopped feeding \(.applicationName)",
                "\(.applicationName) finished eating",
                "Stop the walk for \(.applicationName)",
                "Stop \(.applicationName)'s walk",
                "\(.applicationName) is back from the walk",
                "Stop the car ride for \(.applicationName)",
                "Stop \(.applicationName)'s car ride",
                "\(.applicationName) is out of the car",
                "Stop crying timer with \(.applicationName)",
                "Stop the crying timer for \(.applicationName)",
                "\(.applicationName) stopped crying",
            ],
            shortTitle: "Stop Timer",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: LogDiaperIntent(),
            phrases: [
                "\(.applicationName) had a diaper change",
                "\(.applicationName) has a \(\.$kind) diaper",
                "Log a diaper for \(.applicationName)",
                "change \(.applicationName)'s diaper",
                "changed \(.applicationName)'s diaper",
                "\(.applicationName) needs a diaper change",
                "\(.applicationName) had a diaper",
                "diaper change for \(.applicationName)",
                "\(.applicationName) got a diaper change",
                "log \(.applicationName)'s diaper",
                "\(.applicationName) had a \(\.$kind) diaper",
            ],
            shortTitle: "Log Diaper",
            systemImageName: "circle.grid.cross.fill"
        )
        AppShortcut(
            intent: LogMedicineIntent(),
            phrases: [
                "\(.applicationName) took medicine",
                "Log medicine for \(.applicationName)",
                "\(.applicationName) had medicine",
                "\(.applicationName) took meds",
                "\(.applicationName) had meds",
                "give \(.applicationName) medicine",
                "gave \(.applicationName) medicine",
                "\(.applicationName) got medicine",
                "medicine for \(.applicationName)",
                "log meds for \(.applicationName)",
            ],
            shortTitle: "Log Medicine",
            systemImageName: "pills.fill"
        )
        AppShortcut(
            intent: LogPumpIntent(),
            phrases: [
                "\(.applicationName) pumped",
                "Log a pump for \(.applicationName)",
                "\(.applicationName) finished pumping",
                "pumped for \(.applicationName)",
                "I pumped for \(.applicationName)",
                "log pumping for \(.applicationName)",
                "\(.applicationName) had a pump",
                "finished pumping for \(.applicationName)",
                "\(.applicationName) was pumped",
            ],
            shortTitle: "Log Pump",
            systemImageName: "drop.halffull"
        )
    }
}
