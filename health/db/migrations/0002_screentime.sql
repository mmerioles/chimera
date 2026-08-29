-- 0002_screentime.sql
-- Phone screen time: registry rows, the raw -> derived rebuild, and the views
-- the dashboard reads.
--
-- Bucketing note. Stored buckets are aligned to UTC hours, deliberately: the
-- storage grain must not move when a timezone rule changes or DST folds an
-- hour. Local-day and hour-of-day grouping is applied in the views instead.
-- This is exact for whole-hour-offset zones (America/New_York included). A
-- half-hour zone such as Asia/Kolkata would need the bucket itself localised.

INSERT INTO health.sources (key, display_name, kind) VALUES
  ('phone_screentime', 'Phone (Digital Wellbeing)', 'device')
ON CONFLICT (key) DO NOTHING;

INSERT INTO health.metrics (key, display_name, unit, entity_kind, agg, description) VALUES
  ('screen_time_seconds', 'Screen time',      's',     'app',  'sum',
   'Foreground seconds per app per hour, derived from app_use sessions.'),
  ('app_session_count',   'App opens',        'count', 'app',  'sum',
   'Count of app_use sessions that began in the hour.'),
  ('screen_on_seconds',   'Screen on',        's',     NULL,   'sum',
   'Seconds the display was interactive, derived from screen_on sessions.'),
  ('unlock_count',        'Unlocks',          'count', NULL,   'sum',
   'Keyguard-dismissed events per hour.')
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------------- rebuild

-- Recompute every derived screen-time observation in [p_from, p_to) from the
-- raw layer. Safe to re-run over any window, at any time: it deletes the
-- window before rewriting it, so a corrected or re-uploaded session converges
-- rather than double-counting.
CREATE FUNCTION health.rebuild_screentime(p_from timestamptz, p_to timestamptz)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  v_source   smallint;
  v_from     timestamptz := date_trunc('hour', p_from AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  v_to       timestamptz := date_trunc('hour', p_to   AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' + interval '1 hour';
  v_metrics  smallint[];
  v_written  integer := 0;
  v_n        integer;
BEGIN
  SELECT id INTO v_source FROM health.sources WHERE key = 'phone_screentime';

  SELECT array_agg(id) INTO v_metrics FROM health.metrics
   WHERE key IN ('screen_time_seconds', 'app_session_count',
                 'screen_on_seconds', 'unlock_count');

  DELETE FROM health.observations
   WHERE source_id = v_source
     AND metric_id = ANY (v_metrics)
     AND ts >= v_from AND ts < v_to;

  -- Foreground seconds, with each session sliced at hour boundaries so a
  -- session spanning midnight is attributed to both hours correctly.
  INSERT INTO health.observations (ts, metric_id, source_id, entity_id, value)
  SELECT sliced.bucket,
         (SELECT id FROM health.metrics WHERE key = 'screen_time_seconds'),
         v_source,
         sliced.entity_id,
         SUM(sliced.secs)
  FROM (
    SELECT s.entity_id,
           g.h AS bucket,
           EXTRACT(epoch FROM (
             LEAST(s.ended_at, g.h + interval '1 hour') - GREATEST(s.started_at, g.h)
           )) AS secs
    FROM health.sessions s
    CROSS JOIN LATERAL generate_series(
      date_trunc('hour', s.started_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC',
      date_trunc('hour', (s.ended_at - interval '1 microsecond') AT TIME ZONE 'UTC') AT TIME ZONE 'UTC',
      interval '1 hour'
    ) AS g(h)
    WHERE s.source_id = v_source
      AND s.session_type = 'app_use'
      AND s.ended_at > v_from
      AND s.started_at < v_to
  ) sliced
  WHERE sliced.bucket >= v_from AND sliced.bucket < v_to
    AND sliced.secs > 0
  GROUP BY sliced.bucket, sliced.entity_id;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_written := v_written + v_n;

  -- App opens, attributed to the hour the session started in.
  INSERT INTO health.observations (ts, metric_id, source_id, entity_id, value)
  SELECT date_trunc('hour', s.started_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC',
         (SELECT id FROM health.metrics WHERE key = 'app_session_count'),
         v_source, s.entity_id, COUNT(*)
  FROM health.sessions s
  WHERE s.source_id = v_source
    AND s.session_type = 'app_use'
    AND s.started_at >= v_from AND s.started_at < v_to
  GROUP BY 1, s.entity_id;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_written := v_written + v_n;

  -- Display-on seconds, sliced the same way.
  INSERT INTO health.observations (ts, metric_id, source_id, entity_id, value)
  SELECT sliced.bucket,
         (SELECT id FROM health.metrics WHERE key = 'screen_on_seconds'),
         v_source, 0, SUM(sliced.secs)
  FROM (
    SELECT g.h AS bucket,
           EXTRACT(epoch FROM (
             LEAST(s.ended_at, g.h + interval '1 hour') - GREATEST(s.started_at, g.h)
           )) AS secs
    FROM health.sessions s
    CROSS JOIN LATERAL generate_series(
      date_trunc('hour', s.started_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC',
      date_trunc('hour', (s.ended_at - interval '1 microsecond') AT TIME ZONE 'UTC') AT TIME ZONE 'UTC',
      interval '1 hour'
    ) AS g(h)
    WHERE s.source_id = v_source
      AND s.session_type = 'screen_on'
      AND s.ended_at > v_from
      AND s.started_at < v_to
  ) sliced
  WHERE sliced.bucket >= v_from AND sliced.bucket < v_to
    AND sliced.secs > 0
  GROUP BY sliced.bucket;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_written := v_written + v_n;

  -- Unlocks.
  INSERT INTO health.observations (ts, metric_id, source_id, entity_id, value)
  SELECT date_trunc('hour', e.ts AT TIME ZONE 'UTC') AT TIME ZONE 'UTC',
         (SELECT id FROM health.metrics WHERE key = 'unlock_count'),
         v_source, 0, COUNT(*)
  FROM health.raw_events e
  WHERE e.source_id = v_source
    AND e.event_type = 'unlock'
    AND e.ts >= v_from AND e.ts < v_to
  GROUP BY 1;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_written := v_written + v_n;

  RETURN v_written;
END $$;

-- --------------------------------------------------------------------- views
-- Dashboards read these, never the base tables. Keeps timezone and unit
-- handling in one place and keeps panel SQL short enough to review.

CREATE VIEW health.v_screentime_hourly AS
SELECT o.ts,
       health.local_hour_of_day(o.ts) AS hour_of_day,
       health.local_day(o.ts)         AS day,
       e.key                          AS app_package,
       e.display_name                 AS app,
       o.value                        AS seconds,
       o.value / 60.0                 AS minutes
FROM health.observations o
JOIN health.entities e ON e.id = o.entity_id
JOIN health.metrics  m ON m.id = o.metric_id
WHERE m.key = 'screen_time_seconds';

CREATE VIEW health.v_screentime_daily_app AS
SELECT health.local_day(o.ts) AS day,
       e.key                  AS app_package,
       e.display_name         AS app,
       SUM(o.value)           AS seconds,
       SUM(o.value) / 60.0    AS minutes
FROM health.observations o
JOIN health.entities e ON e.id = o.entity_id
JOIN health.metrics  m ON m.id = o.metric_id
WHERE m.key = 'screen_time_seconds'
GROUP BY 1, 2, 3;

-- One row per local day with the headline numbers side by side. Built with
-- FILTER rather than joins so a day with unlocks but no app data still shows.
CREATE VIEW health.v_screentime_daily AS
SELECT health.local_day(o.ts) AS day,
       COALESCE(SUM(o.value) FILTER (WHERE m.key = 'screen_time_seconds'), 0)        AS screen_time_seconds,
       COALESCE(SUM(o.value) FILTER (WHERE m.key = 'screen_time_seconds'), 0) / 3600.0 AS screen_time_hours,
       COALESCE(SUM(o.value) FILTER (WHERE m.key = 'screen_on_seconds'), 0)          AS screen_on_seconds,
       COALESCE(SUM(o.value) FILTER (WHERE m.key = 'unlock_count'), 0)               AS unlocks,
       COALESCE(SUM(o.value) FILTER (WHERE m.key = 'app_session_count'), 0)          AS app_opens
FROM health.observations o
JOIN health.metrics m ON m.id = o.metric_id
WHERE m.key IN ('screen_time_seconds', 'screen_on_seconds', 'unlock_count', 'app_session_count')
GROUP BY 1;

-- Per-day first and last phone contact, straight off the raw layer so the
-- timestamps are exact rather than bucket-rounded.
CREATE VIEW health.v_screentime_day_bounds AS
SELECT health.local_day(s.started_at) AS day,
       MIN(s.started_at)              AS first_use,
       MAX(s.ended_at)                AS last_use,
       EXTRACT(epoch FROM (MAX(s.ended_at) - MIN(s.started_at))) / 3600.0 AS waking_span_hours
FROM health.sessions s
JOIN health.sources src ON src.id = s.source_id
WHERE src.key = 'phone_screentime' AND s.session_type = 'app_use'
GROUP BY 1;
