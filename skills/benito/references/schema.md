# Benito database schema (for reading)

SQLite, WAL mode, foreign keys on. The server creates and migrates it at startup
(`server/migrations/001_init.sql` … `006_*.sql`, plus small column additions in `server/src/db.rs`).
IDs are UUID strings. Times are RFC 3339 text in UTC (`2026-10-22T18:00:00+00:00`, sometimes with
fractional seconds), except `children.birthdate` (`YYYY-MM-DD`).

## Tables you read

### `children`
`id`, `family_id`, `name`, `birthdate`, `sex`, `created_at`. One row per baby. Most queries
filter by `child_id`.

### `events` (the log)

| Column | Meaning |
|---|---|
| `id`, `child_id` | UUIDs |
| `type` | see below |
| `subtype` | diaper kind, activity kind, medicine name, bottle contents |
| `started_at` | when it happened or began (UTC) |
| `ended_at` | when a timed event ended; NULL = point event, or a timed one never stopped |
| `amount_value`, `amount_unit` | bottle volume (`oz` or `ml`), temperature, medicine dose (`ml`, `drops`, `mg`, `IU`) |
| `side` | nursing or pump side: `L`/`R` (also seen: `left`/`right`, any case) |
| `notes` | free text typed by a parent |
| `payload_json` | extra data; from timers: `{"paused_seconds": N}` |
| `created_by` | user id of who logged it |
| `created_at`, `updated_at` | bookkeeping (sync cursor uses `updated_at`) |
| `deleted_at` | set when deleted in the app (tombstone). **Filter `deleted_at IS NULL`.** |

`type` values the server accepts:

| type | Timed? | Notes |
|---|---|---|
| `feed_breast` | yes | `side` L/R; from the nursing timer |
| `feed_bottle` | no | `amount_value` + `amount_unit` (`oz` default, or `ml`); `subtype` e.g. `formula`, `breastmilk` |
| `feed_solid` | no | |
| `diaper` | no | `subtype` `wet`, `dirty` (also `poop`/`bm`), `both` (also `mixed`) |
| `sleep` | yes | from the sleep timer |
| `activity` | yes | `subtype` must be `walk`, `car_ride`, or `crying` |
| `pump` | optional | `side`, amount |
| `medicine` | no | `subtype` = medicine name; optional dose |
| `temperature` | no | `amount_value` with unit (`F`/`C`) |
| `growth`, `milestone`, `note`, `custom` | no | details in `notes` / amount / payload |

Stopping a timer creates the event: `sleep`, `feed_breast` (with side), or `activity` with
subtype `walk`/`car_ride`/`crying`, with `payload_json` `{"paused_seconds": N}` if it was paused.

### `timers` (what is running now)

`id`, `child_id`, `kind` (`sleep`, `feed_breast`, `walk`, `car_ride`, `crying`), `started_at`,
`started_by`, `state` (`running`, `paused`, `stopped`), `stopped_at`, `updated_at`, `side`,
`paused_at` (set while paused), `paused_seconds` (finished pauses so far).

Active seconds = now − `started_at` − `paused_seconds` − (now − `paused_at`, if paused).

### Others that are safe to read
`families` (`id`, `name`, `created_at`; skip `invite_code`), `family_members` (`role` parent or
caregiver, `expires_at` for time-limited caregivers), `reminders`, `server_meta` (`server_id`).

## Tables never to read
`sessions`, `pairing_tokens`, `live_activity_tokens`, `devices` (keys and bearer tokens),
`family_invites` (invite secrets are hashed, but there is no reason to look), and
`users.password_hash`. `users.name`/`email` are fine if needed to say who logged something.

## Daily summary math (what the app shows)

Implemented in `server/src/routes/summary.rs`; mirrored in `scripts/benito-query` (`summarize`).

- Window `[from, to)` = the parent's local midnight to the next local midnight.
- Counts: events with `from <= started_at < to`.
- `feed_seconds`: for feeds starting in the window, `ended_at − started_at − paused` (0 if open).
- `sleep_seconds`, `nursing_seconds`, `crying_seconds`: finished events overlapping the window,
  clipped to it; the pause is scaled by clipped/total length. A sleep that started before `from`
  still adds 1 to `total_events`.
- `bottle_oz_equiv = oz + ml / 29.5735`. All values rounded to 2 decimals; `sleep_hours = seconds/3600`.
