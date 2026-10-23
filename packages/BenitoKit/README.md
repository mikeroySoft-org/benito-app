# BenitoKit

Shared Swift package: Codable DTOs aligned with benito-server JSON, `APIClient`, `SyncClient` (`URLSessionWebSocketTask`), and local-first store (`GRDBStore` + `InMemoryStore` fallback).

## What’s in the package

- **BenitoLog** (`OSLog`): subsystem `com.mikeroysoft.benito`, categories `api` / `sync` / `store` / `ui`. Stream with `./scripts/stream-device-logs.sh` (see `docs/device-logs.md`).
- **Models** match server snake_case (`amount_value`, `invite_code`, sync envelope `type` / `payload` / `at` / `client_id`).
- **APIClient** covers health, auth, me, families, children, events CRUD, timeline, state, timers, export. Sends `X-Client-Id`. Exposes `rawRequest` for outbox replay.
- **SyncClient** authenticates with `{type:auth,payload:{token,client_id}}` and parses envelope types (`event.upsert`, `event.delete`, `timer.upsert`, `timer.stop`, `state`, …).
- **GRDBStore** (preferred on device): SQLite schema for `children`, `events`, `timers`, `prefs`, `outbox`. Applies sync envelopes; on `state` / `refetch_state` calls an optional `StateRefetching` hook (usually `APIStateRefetcher`) and `applyBabyState`. Home glance / timeline read from local rows. Outbox queues offline `method`/`path`/`body` until `OutboxFlusher` succeeds.
- **InMemoryStore**: same `BenitoStore` API for tests / previews / Linux stubbing.
- **KeychainSessionTokenStore** (`SessionTokenStore`): persists the session token as a Keychain generic password, one item per normalized server origin (`SessionTokenStoreKey.account(for:)`), accessible `AfterFirstUnlockThisDeviceOnly` (readable on background launches, never synced). `InMemorySessionTokenStore` for tests / previews / Linux.

## Mac / Xcode build notes

Linux **cannot** compile the iOS app or fully exercise GRDB UI targets. On a Mac:

1. Open / create an Xcode project (iOS 17+, watchOS 10+).
2. **File → Add Package Dependencies… → Add Local…** → select `packages/BenitoKit`.
3. Link the **BenitoKit** product to the Benito (and Watch) app targets.
4. Add sources under `apps/Benito/Sources` (and Watch) to those targets.
5. Build & run on a simulator or device. Default server URL is `http://127.0.0.1:8080` (UserDefaults / `@AppStorage`); GRDB also stores `server_url` in `prefs`.

```bash
# From packages/BenitoKit on a Mac
swift build
swift test
```

`LocalStoreFactory.makeDefault()` opens  
`Application Support/Benito/benito.sqlite` via GRDB, or falls back to `InMemoryStore` if open fails.

### Linux note

`Package.swift` depends on [GRDB.swift](https://github.com/groue/GRDB.swift). Resolving / compiling GRDB on Linux may fail depending on toolchain — **that is OK**. Do not drop the GRDB dependency; Apple clients are the source of truth. Prefer `InMemoryStore` for any Linux-side Swift experiments.

## GRDB schema (v1_local)

| Table | Purpose |
|---|---|
| `children` | id, family_id, name, birthdate, sex, created_at |
| `events` | mirrors server event columns (incl. soft `deleted_at`) |
| `timers` | mirrors server timer columns |
| `prefs` | key/value (e.g. `server_url`) — session tokens live in the Keychain via `KeychainSessionTokenStore`, not here |
| `outbox` | id, method, path, body, created_at |

## Outbox behavior

1. When an HTTP mutation fails with a **transport** error, the app enqueues `POST /events`, `POST /timers`, etc.
2. On next successful auth / state refresh, `OutboxFlusher` replays FIFO via `APIClient.rawRequest`.
3. Transport / 5xx → stop and retry later. Other failures drop the row (poison pill) so the queue progresses.
