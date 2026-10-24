-- Ready-made read-only queries for a Benito database. Tested against tests/fixture.sql.
-- Run with the parent's time zone so 'localtime' means their day, and always -readonly:
--   TZ=America/Los_Angeles sqlite3 -readonly "$DB" < skills/benito/references/queries.sql
-- Replace 'Benito' with the child's name. Sleep and crying here bucket by START day and do not
-- clip at midnight; use scripts/benito-query for numbers that match the app.
.headers on
.mode column

-- Children
SELECT id, name, birthdate FROM children ORDER BY created_at;

-- Last feed, and hours since it started
SELECT type, side, amount_value, amount_unit,
       datetime(started_at, 'localtime') AS started_local,
       ROUND((julianday('now') - julianday(started_at)) * 24, 1) AS hours_since_start
FROM events
WHERE deleted_at IS NULL AND type LIKE 'feed_%'
  AND child_id = (SELECT id FROM children WHERE name = 'Benito')
ORDER BY started_at DESC LIMIT 1;

-- Running or paused timers, with active seconds so far
SELECT kind, state, side, datetime(started_at, 'localtime') AS started_local,
       CAST((julianday(COALESCE(paused_at, 'now')) - julianday(started_at)) * 86400
            - paused_seconds AS INT) AS active_seconds
FROM timers
WHERE state IN ('running', 'paused')
  AND child_id = (SELECT id FROM children WHERE name = 'Benito');

-- Diapers by local day, last 7 days including today
SELECT date(started_at, 'localtime') AS day,
       SUM(subtype = 'wet') AS wet,
       SUM(subtype IN ('dirty', 'poop', 'bm')) AS dirty,
       SUM(subtype IN ('both', 'mixed')) AS both_,
       COUNT(*) AS total
FROM events
WHERE deleted_at IS NULL AND type = 'diaper'
  AND child_id = (SELECT id FROM children WHERE name = 'Benito')
  AND julianday(started_at) >= julianday('now', 'localtime', 'start of day', '-6 days', 'utc')
GROUP BY day ORDER BY day;

-- Feeds by local day (weekly trend)
SELECT date(started_at, 'localtime') AS day,
       SUM(type = 'feed_breast') AS nursing,
       SUM(type = 'feed_bottle') AS bottles,
       ROUND(SUM(CASE WHEN type = 'feed_bottle' THEN
             CASE WHEN amount_unit = 'ml' THEN amount_value / 29.5735 ELSE amount_value END END), 2) AS bottle_oz,
       SUM(type = 'feed_solid') AS solids
FROM events
WHERE deleted_at IS NULL AND type LIKE 'feed_%'
  AND child_id = (SELECT id FROM children WHERE name = 'Benito')
  AND julianday(started_at) >= julianday('now', 'localtime', 'start of day', '-6 days', 'utc')
GROUP BY day ORDER BY day;

-- Crying minutes by start day (paused time excluded)
SELECT date(started_at, 'localtime') AS day,
       ROUND(SUM((julianday(ended_at) - julianday(started_at)) * 86400
                 - COALESCE(json_extract(payload_json, '$.paused_seconds'), 0)) / 60.0) AS minutes
FROM events
WHERE deleted_at IS NULL AND type = 'activity' AND subtype = 'crying' AND ended_at IS NOT NULL
  AND child_id = (SELECT id FROM children WHERE name = 'Benito')
GROUP BY day ORDER BY day;

-- Sleep hours by start day (paused time excluded; overnight sleeps land on the start day)
SELECT date(started_at, 'localtime') AS day, COUNT(*) AS sleeps,
       ROUND(SUM((julianday(ended_at) - julianday(started_at)) * 86400
                 - COALESCE(json_extract(payload_json, '$.paused_seconds'), 0)) / 3600.0, 2) AS hours
FROM events
WHERE deleted_at IS NULL AND type = 'sleep' AND ended_at IS NOT NULL
  AND child_id = (SELECT id FROM children WHERE name = 'Benito')
GROUP BY day ORDER BY day;

-- Open-ended timed events (forgotten or still running; they count 0 toward durations)
SELECT type, subtype, datetime(started_at, 'localtime') AS started_local
FROM events
WHERE deleted_at IS NULL AND ended_at IS NULL AND type IN ('sleep', 'feed_breast', 'activity')
  AND child_id = (SELECT id FROM children WHERE name = 'Benito')
ORDER BY started_at DESC LIMIT 10;

-- CSV for the pediatrician (run separately):
--   sqlite3 -readonly -header -csv "$DB" "SELECT type, subtype, datetime(started_at,'localtime') AS started,
--     datetime(ended_at,'localtime') AS ended, amount_value, amount_unit, side, notes FROM events
--     WHERE deleted_at IS NULL ORDER BY started_at" > ~/Desktop/benito.csv
