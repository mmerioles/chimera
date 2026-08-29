-- Correctness tests for health.rebuild_screentime().
--
-- Runs inside a transaction that is always rolled back, so it is safe against
-- a database with real data in it.
--
--   docker compose exec -T db psql -U health -d health -v ON_ERROR_STOP=1 \
--     -f /dev/stdin < tools/test_rollups.sql

BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.expect(
  p_name text, p_actual double precision, p_expected double precision
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_actual IS DISTINCT FROM p_expected THEN
    RAISE EXCEPTION 'FAIL % : expected %, got %', p_name, p_expected, p_actual;
  END IF;
  RAISE NOTICE 'pass  %', p_name;
END $$;

-- Isolate: drop existing screen-time raw data for the test window.
DELETE FROM health.sessions s USING health.sources src
  WHERE src.id = s.source_id AND src.key = 'phone_screentime';
DELETE FROM health.raw_events e USING health.sources src
  WHERE src.id = e.source_id AND src.key = 'phone_screentime';

DO $$
DECLARE
  v_src smallint;
  v_app integer;
BEGIN
  SELECT id INTO v_src FROM health.sources WHERE key = 'phone_screentime';
  v_app := health.upsert_entity('app', 'com.test.app', 'Test App');

  INSERT INTO health.sessions
    (source_id, session_type, entity_id, started_at, ended_at, external_id)
  VALUES
    -- 1. wholly inside one hour: 600s
    (v_src, 'app_use', v_app, '2026-03-10T10:10:00Z', '2026-03-10T10:20:00Z', 't1'),
    -- 2. straddles one boundary: 1800s in 11:00, 1800s in 12:00
    (v_src, 'app_use', v_app, '2026-03-10T11:30:00Z', '2026-03-10T12:30:00Z', 't2'),
    -- 3. spans three hours: 600s, 3600s, 600s
    (v_src, 'app_use', v_app, '2026-03-10T14:50:00Z', '2026-03-10T16:10:00Z', 't3'),
    -- 4. crosses midnight UTC: 300s on the 10th, 300s on the 11th
    (v_src, 'app_use', v_app, '2026-03-10T23:55:00Z', '2026-03-11T00:05:00Z', 't4'),
    -- 5. zero-length: contributes no time but is still an "open"
    (v_src, 'app_use', v_app, '2026-03-10T09:00:00Z', '2026-03-10T09:00:00Z', 't5');

  INSERT INTO health.raw_events (source_id, event_type, entity_id, ts, external_id)
  VALUES (v_src, 'unlock', 0, '2026-03-10T10:09:00Z', 'u1'),
         (v_src, 'unlock', 0, '2026-03-10T10:40:00Z', 'u2'),
         (v_src, 'unlock', 0, '2026-03-10T11:00:00Z', 'u3');

  PERFORM health.rebuild_screentime('2026-03-09T00:00:00Z', '2026-03-12T00:00:00Z');
END $$;

-- Scoped to the test window: rebuild only rewrites the window it is given,
-- so any real data outside it is still present and must not be summed here.
CREATE TEMP VIEW st AS
  SELECT o.ts, o.value
  FROM health.observations o
  JOIN health.metrics m ON m.id = o.metric_id
  WHERE m.key = 'screen_time_seconds'
    AND o.ts >= '2026-03-09T00:00:00Z' AND o.ts < '2026-03-12T00:00:00Z';

SELECT pg_temp.expect('session inside one hour',
  (SELECT value FROM st WHERE ts = '2026-03-10T10:00:00Z'), 600);

SELECT pg_temp.expect('boundary split, first hour',
  (SELECT value FROM st WHERE ts = '2026-03-10T11:00:00Z'), 1800);
SELECT pg_temp.expect('boundary split, second hour',
  (SELECT value FROM st WHERE ts = '2026-03-10T12:00:00Z'), 1800);

SELECT pg_temp.expect('three-hour span, head',
  (SELECT value FROM st WHERE ts = '2026-03-10T14:00:00Z'), 600);
SELECT pg_temp.expect('three-hour span, whole middle hour',
  (SELECT value FROM st WHERE ts = '2026-03-10T15:00:00Z'), 3600);
SELECT pg_temp.expect('three-hour span, tail',
  (SELECT value FROM st WHERE ts = '2026-03-10T16:00:00Z'), 600);

SELECT pg_temp.expect('midnight crossing, before',
  (SELECT value FROM st WHERE ts = '2026-03-10T23:00:00Z'), 300);
SELECT pg_temp.expect('midnight crossing, after',
  (SELECT value FROM st WHERE ts = '2026-03-11T00:00:00Z'), 300);

SELECT pg_temp.expect('zero-length session contributes no time',
  (SELECT COALESCE(SUM(value), 0) FROM st WHERE ts = '2026-03-10T09:00:00Z'), 0);

SELECT pg_temp.expect('total equals sum of raw durations',
  (SELECT SUM(value) FROM st), 600 + 3600 + 4800 + 600);

SELECT pg_temp.expect('unlocks bucketed by hour (10:00)',
  (SELECT o.value FROM health.observations o JOIN health.metrics m ON m.id = o.metric_id
    WHERE m.key = 'unlock_count' AND o.ts = '2026-03-10T10:00:00Z'), 2);
SELECT pg_temp.expect('unlocks bucketed by hour (11:00)',
  (SELECT o.value FROM health.observations o JOIN health.metrics m ON m.id = o.metric_id
    WHERE m.key = 'unlock_count' AND o.ts = '2026-03-10T11:00:00Z'), 1);

SELECT pg_temp.expect('app_session_count counts the zero-length open too',
  (SELECT o.value FROM health.observations o JOIN health.metrics m ON m.id = o.metric_id
    WHERE m.key = 'app_session_count' AND o.ts = '2026-03-10T09:00:00Z'), 1);

-- Re-running must converge, not double-count.
DO $$ BEGIN
  PERFORM health.rebuild_screentime('2026-03-09T00:00:00Z', '2026-03-12T00:00:00Z');
END $$;
SELECT pg_temp.expect('rebuild is idempotent',
  (SELECT SUM(value) FROM st), 600 + 3600 + 4800 + 600);

-- A retracted session must disappear from the derived layer on rebuild.
DELETE FROM health.sessions WHERE external_id = 't2';
DO $$ BEGIN
  PERFORM health.rebuild_screentime('2026-03-09T00:00:00Z', '2026-03-12T00:00:00Z');
END $$;
SELECT pg_temp.expect('retracted session is removed from rollups',
  (SELECT SUM(value) FROM st), 600 + 4800 + 600);

\echo ''
\echo 'ALL ROLLUP TESTS PASSED'

ROLLBACK;
