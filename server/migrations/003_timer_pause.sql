-- Pause/resume for running timers. `state` gains the value 'paused'.
-- paused_at: start of the pause in progress (NULL unless state = 'paused').
-- paused_seconds: total seconds of COMPLETED pauses (the open pause is now - paused_at).
BEGIN;
ALTER TABLE timers ADD COLUMN paused_at TEXT;
ALTER TABLE timers ADD COLUMN paused_seconds INTEGER NOT NULL DEFAULT 0;
COMMIT;
