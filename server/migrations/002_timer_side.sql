-- Optional side for feed_breast timers (L/R); ignored for sleep/other kinds.
ALTER TABLE timers ADD COLUMN side TEXT;
