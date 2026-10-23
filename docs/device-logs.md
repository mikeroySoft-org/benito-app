# Device log streaming

Stream `BenitoLog` output from Benito running on a paired iPhone while debugging sync / networking / the offline outbox.

## Canonical IDs

| | |
|---|---|
| iOS bundle id | `com.mikeroysoft.benito` |
| OSLog subsystem | `com.mikeroysoft.benito` (same string) |
| Categories | `api`, `sync`, `store`, `ui` via `BenitoLog` in BenitoKit |

## Run

From the repo root on the Mac the phone is paired with (phone unlocked, app installed):

```bash
./scripts/stream-device-logs.sh
# DEVICE=<name|id> ./scripts/stream-device-logs.sh   # pick a device
# BENITO_LOG_ALL=1 ./scripts/stream-device-logs.sh   # include framework noise
```

The script **relaunches** the app via `xcrun devicectl device process launch --console` with
`OS_ACTIVITY_DT_MODE=YES` (the same mirroring Xcode's console uses). Output tees to
**`.debug/device.log`** (gitignored). Ctrl-C stops the stream **and terminates the app** on the phone
(devicectl forwards the signal).

Works over SSH: it needs no keychain access or root.

## Why not `log stream`?

- `log stream` has no `--device` option; it only reads the Mac's own log.
- `log collect --device` works but requires root.
- Console.app (select the phone, filter `com.mikeroysoft.benito`) shows everything, but only on the Mac's screen.

## Levels

Only `.notice` and above reach the relay from the device, so breadcrumbs use `.notice`; failures use
`.warning` / `.error`. Per-envelope chatter stays at `.debug` and is not relayed.

- **api** — HTTP method + path; errors include status / body / transport error (never tokens)
- **sync** — connect / disconnect / drop / reconnect scheduling / server `hello` / server `error` reason
- **store** — outbox enqueue / flush / stop / poison
- **ui** — session restore (or why it was skipped), register / login / sign out / 401, sync skipped
  (and why), catch-up applied / failed, app active, log event / start timer / probe
