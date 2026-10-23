# Benito UI prototype (design pass)

**Date:** 2026-09-28 PT  
**Goal:** Match OpenBBQ Cook HUD quality — minimal native SwiftUI, thumb-first, continuous-corner cards.

**Status:** This prototype is the app UI. `ContentView` renders `DesignPrototypeRoot` unconditionally; the legacy Form debugger and the `benito.designPrototypeUI` toggle are gone.

## Design rationale

OpenBBQ’s dark outdoor HUD (`bgCanvas 0x0B0D10`) is the right *grammar* for Benito, but baby care is night care: the critical moments are 2am feeds and diaper changes in a dark room. A **warm-dark** palette keeps the same high-contrast glance hierarchy and ≥52pt thumb targets while softening accents (coral feed, amber diaper, teal sleep) so the UI feels calm rather than grill-hot. A pure light “nursery pastel” theme would fight night-time use and dilute the OpenBBQ quality bar we already trust; warm-dark inherits that bar and stays kind to sleep-deprived eyes.

## Information architecture

| Tab | Role |
|---|---|
| **Home** | **Summary glance** (not a Log launcher): since last feed + side; diaper; asleep/awake + duration; today’s feeds/diapers/sleep. Thumb bar opens each interaction in place. |
| **Log** | Big action cards → same Feed/Diaper sheets as Home; sleep starts shared timer |
| **Timer** | Full-screen calm breast/sleep timer (cover) with L/R pills and thumb-reachable Stop |
| **Timeline** | Card list of recent events |
| **Account** | Secondary grouped List: server URL, account, family, export, Dynamic Island |

### Home thumbs (iteration 2026-09-28)

- **Feed** → presents Feeding sheet (Nursing | Bottle segmented panel) — stays on Home
- **Diaper** → presents Diaper sheet (wet/dirty/both) — stays on Home
- **Sleep** → starts sleep timer + opens Active timer cover — stays on Home
- Thumbs are **equal visual weight**. No permanent selected/highlight. Soft accent only while a related timer is *running* (breast → Feed, sleep → Sleep).
- Shared sheets: `Components/LogSheets.swift` (`FeedLogSheet` with Nursing|Bottle toggle, `DiaperLogSheet`) used by Home and Log. Active breast timer opens the Nursing segment automatically; L/R controls start/pause/resume/stop via existing timer APIs.

## Tokens

| Token | Value | Notes |
|---|---|---|
| `bgCanvas` | `#0B0D10` | Same as OpenBBQ |
| `bgCard` | `#161A20` | Same as OpenBBQ |
| `bgCardElevated` | `#1C222B` | Timer banner / secondary surfaces |
| `textPrimary` | `#F5F7FA` | |
| `textSecondary` | `#9AA3B2` | |
| `feed` | `#FF8B7B` | Warm coral |
| `diaper` | `#E8B86D` | Soft amber |
| `sleep` | `#6BB3C8` | Calm teal |
| `active` | `#3DDC97` | Running timer / sync ok |
| `bottle` | `#B8A4FF` | Bottle chip |
| `thumbMin` | `52` | |
| `gutter` | `16` | |
| `cardRadius` | `14` continuous | |

Source: `apps/Benito/Sources/DesignPrototype/DesignTokens.swift`

## How to run

Build & run the **Benito** scheme (iOS Simulator or device); the app opens on the Home tab.

```bash
cd apps/Benito && xcodegen generate
xcodebuild -scheme Benito -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## Paths

- `apps/Benito/Sources/DesignPrototype/DesignTokens.swift`
- `apps/Benito/Sources/DesignPrototype/PrototypeModels.swift`
- `apps/Benito/Sources/DesignPrototype/DesignPrototypeRoot.swift`
- `apps/Benito/Sources/DesignPrototype/Components/ContinuousCornerCard.swift`
- `apps/Benito/Sources/DesignPrototype/Components/ThumbActionBar.swift`
- `apps/Benito/Sources/DesignPrototype/Components/LogSheets.swift`
- `apps/Benito/Sources/DesignPrototype/Screens/HomeGlanceView.swift`
- `apps/Benito/Sources/DesignPrototype/Screens/LogActionsView.swift`
- `apps/Benito/Sources/DesignPrototype/Screens/ActiveTimerView.swift`
- `apps/Benito/Sources/DesignPrototype/Screens/TimelinePrototypeView.swift`
- `apps/Benito/Sources/DesignPrototype/Screens/SettingsPrototypeView.swift`
- Root: `apps/Benito/Sources/ContentView.swift` (`AppModel` + `ContentView` → `DesignPrototypeRoot`)
- Screenshots: `docs/design/screenshots/`

## Data wiring

| Surface | Live `AppModel` | Demo fallback |
|---|---|---|
| Home glance | `babyState` + timeline-derived sleep; Today strip prefers `dailySummary` (local-day API), else timeline counts | SPEC-shaped demo when `babyState == nil` |
| Home / Log sheets | `logDiaper(subtype:at:)`, `logBottle(ounces:milk:at:)`, `logPump(side:ounces:durationMinutes:at:)`, `logManualSleep(start:end:)`, `startBreastTimer` / `pauseActiveTimer` / `resumeActiveTimer` / `stopActiveTimer` (Nursing segment), `startSleepTimer` (bottle prefill: `lastBottleOunces` / `lastBottleMilk`) | — |
| Fixing mistakes | `updateEvent(_:changes:)`, `deleteEvent(_:)` (queued in the outbox when offline), `adjustActiveTimerStart(to:)` (online only) | — |
| Active timer | `babyState.activeTimer` + `stopActiveTimer` | Static demo clock only when no state |
| Timeline | `model.timeline` | Demo events when empty/unsigned |
| Account/Server | URL, auth, family, export, Rotate invite, outbox count, status | — |

## Out of scope

- App Store pixel polish, SaaS onboarding, recipes/social chrome

## Screenshots (Simulator)

Launch on a booted simulator, optionally deep-linking a tab or sheet:

```bash
# tab: 0 home · 1 log · 2 timeline · 3 account · timer
SIMCTL_CHILD_BENITO_PROTOTYPE_TAB=0 xcrun simctl launch booted com.mikeroysoft.benito
# optional Home sheet: feed | diaper
SIMCTL_CHILD_BENITO_PROTOTYPE_TAB=0 SIMCTL_CHILD_BENITO_PROTOTYPE_SHEET=feed \
  xcrun simctl launch booted com.mikeroysoft.benito
```

| File | Content |
|---|---|
| `01-home-glance.png` | Home summary + equal-weight thumbs |
| `02-log-actions.png` | Log |
| `03-active-timer.png` | Active timer cover |
| `04-timeline.png` | Timeline |
| `05-home-feed-sheet.png` | Feed sheet from Home |
| `06-home-diaper-sheet.png` | Diaper sheet from Home |
