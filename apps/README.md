# Apps

SwiftUI clients for Benito.

## Xcode project (Mac)

The iOS app is generated with **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** from `apps/Benito/project.yml`.

| | |
|---|---|
| Project | `apps/Benito/Benito.xcodeproj` |
| Scheme | `Benito` |
| Bundle ID | `com.mikeroysoft.benito` |
| Deployment | iOS 18.0+ (Live Activity layout for the Apple Watch Smart Stack needs iOS 18) |
| Local package | `packages/BenitoKit` (SPM, pulls GRDB) |
| Widget extension | `BenitoWidgets` (`com.mikeroysoft.benito.widgets`, sources `apps/BenitoWidgets`) — Live Activity for the Dynamic Island, Lock Screen and Apple Watch Smart Stack (watchOS 11+): running feed/sleep timer (pause-aware) plus time since last diaper/feed, with Pause/Resume/Stop buttons while a timer is active and Feed / Diaper / Sleep buttons when idle (Feed and Diaper open the matching Home sheets; Sleep starts the nap timer). Buttons are `LiveActivityIntent`s that run in the iPhone app. `apps/Shared` (activity attributes, content builder, App Intents) is compiled into both targets. Starts with ActivityKit `pushType: .token` so a partner stop can end a suspended phone's island once APNs env is set on the server (Phase 1 sandbox / Xcode); pause/resume push fan-out and push-to-start are later. Toggle under Account → Dynamic Island |
| Siri / App Intents | `apps/Shared/Intents` + `apps/Benito/Sources/Intents/BenitoShortcuts.swift`. Phrases always contain the app name; `BENITO_SIRI_NAME` in `apps/Benito/Config/Local.xcconfig` (default `Baby`) is added as an alternative app name (`INAlternativeAppNames`), so "Siri, Sam started a feed" works — change it to your child's name. Feed asks "Left, right, or bottle?"; bottle then asks ounces and breast milk/formula. Also: start a nap, pause / resume / stop the timer ("Sam is done", "Sam woke up"), log a diaper ("Wet, dirty, or both?"), log medicine ("Which medicine?" then an optional dose; unit defaults to ml), and log a pump (ounces and minutes, each skippable with zero; side defaults to both). Intents talk to the server directly (Keychain session + saved server URL) and work while the phone is locked |
| Sharing | `apps/Benito/Sources/Sharing` + `Sources/Pairing`. Account → Sharing lists everyone in the family (swipe to remove) and pending invites. **Invite to Family** mints a one-time, expiring invite (`POST /families/invites`) and offers Messages, AirDrop/share sheet, a QR code and SharePlay. The link (`benito://join?p=…`) carries the server's LAN and tailnet URLs; the joiner's app probes them, creates a Secure Enclave device key and redeems the invite (`POST /invites/redeem`). No username or password. SharePlay delivery needs two physical iPhones; the Simulator can't run it |
| Default server | empty (`@AppStorage("serverURL")`) — first launch prompts for a URL. On Simulator the preset button fills `http://127.0.0.1:8080`; on device use an HTTPS origin such as `https://<machine>.<tailnet>.ts.net` (see [`docs/deploy-tailscale.md`](../docs/deploy-tailscale.md)) |

TestFlight and App Store builds: [`docs/release-ios.md`](../docs/release-ios.md) (`scripts/release-ios.sh`).

### Regenerate / open

```bash
# From repo root (XcodeGen: brew install xcodegen)
cd apps/Benito && xcodegen generate
open Benito.xcodeproj
```

### Build (CLI)

No **iPhone 16** simulator on this Mac (Xcode 26.3). Use **iPhone 17** (iOS 26.3) or any available iPhone 15:

```bash
xcrun simctl list devices available | grep iPhone

cd apps/Benito
xcodebuild -scheme Benito \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build
```

### Lint: timer chrome (TimelineView)

Long nursing / sleep sessions jetsam when a 1 Hz `TimelineView` (or `Timer.publish`) rebuilds Liquid Glass or large `Button` / `Circle` chrome every tick. Digits may tick; glass stays outside.

```bash
# From repo root (also runs in CI: .github/workflows/timer-chrome.yml)
./scripts/check-timer-chrome.sh
./scripts/check-timer-chrome.sh --self-test
```

Also runs as an Xcode pre-build script on the Benito target (`project.yml` → Check TimelineView chrome):

```bash
"${SRCROOT}/../../scripts/check-timer-chrome.sh"
```

Escape hatch: `// timer-chrome-ok: <reason>` on/above the `TimelineView`, or a `path.swift:line` entry in `scripts/timer-chrome-allowlist.txt`.

### App flow

`apps/Benito/Sources/ContentView.swift` holds `AppModel` (wired to **BenitoKit**) and renders the dark Home / Log / Timeline / Account UI in `apps/Benito/Sources/DesignPrototype/` (design notes: [`docs/design/BENITO_UI_PROTOTYPE.md`](../docs/design/BENITO_UI_PROTOTYPE.md)):

1. Enter server URL (empty on first launch) → Register / Login. The session token is stored in the Keychain per server origin, so cold launches stay signed in; Sign out or a `401` clears it.
2. Account → Family: without a family, **Join partner's family** (bring phones together or type the invite code) or start a new one. With a family, Account shows it plus **Invite partner** (proximity invite, invite code, rotate) and **Leave family…** for switching families / troubleshooting (`POST /families/leave`).
3. Home glance loads `GET /state`.
4. Log feeds (breast timer, bottle with ounces + breast milk/formula), pumping (side, ounces, duration), medicine (name + optional dose), diapers and sleep via HTTP; shared feed/sleep timers start/pause/stop server-side.
5. Fix mistakes: edit or delete any entry, log one at an earlier time ("fed at 2:10am"), or move a running timer's start back. Offline edits/deletes queue in the outbox; timer adjustments need a connection.
6. `SyncClient` connects to `WS /sync` after auth; envelopes are applied to **GRDBStore** (fallback `InMemoryStore`) and refresh state / local timeline. On sign-in, WS reconnect, and returning to the foreground, `CatchUpSync` pulls `GET /events?since=<cursor>` so events logged while the app was backgrounded (including deletions) reach the local store.
7. Offline logs enqueue an **outbox** row and flush when the API is reachable again.
8. Export JSON (`GET /export`) hydrates the local store and shares a temp file; Export CSV (`GET /export.csv`) shares a pediatrician-ready CSV via the system share sheet.

### Watch (stub target present)

`BenitoWatch` target exists in the same project (`com.mikeroysoft.benito.watchkitapp`, sources under `apps/BenitoWatch/Sources`). It is **not** embedded in the `Benito` scheme yet — this Mac has no usable watchOS simulator runtime. Follow-up: embed Watch under the iOS target, install a watchOS runtime, and wire glance / one-tap logging.

## v1a UI goals

- One-touch feed / diaper / sleep logging
- Shared running timers (server-authoritative)
- Home “state of the baby” glance
- Local notifications for reminders (no APNs yet) — **follow-up** (needs interval UX)
- Medicine logging (name + dose) with home-glance “last medicine”
