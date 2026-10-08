-- 06_retention.sql

BEGIN;
SELECT plan(25);

-- A year of months, with as_of fixed so the answers do not change tomorrow.
\o /dev/null
SELECT fixture.new_parent('rt');
SELECT ppm.register_set('rt', 'at', 'month', premake := 1,
                        retention := interval '3 months');
SELECT ppm.create_ahead('rt', '2026-01-15 00:00+00');
SELECT ppm.create_ahead('rt', '2026-03-15 00:00+00');
SELECT ppm.create_ahead('rt', '2026-05-15 00:00+00');
\o

SELECT is((SELECT count(*)::integer FROM ppm.partitions('rt')), 6,
          'six monthly partitions to work with');

-- Retention is measured from as_of backwards, and only whole partitions go.
SELECT results_eq(
    $$SELECT child::text FROM ppm.retention_victims('rt', '2026-06-20 00:00+00')
       ORDER BY lower_bound$$,
    $$VALUES ('rt_202601'), ('rt_202602')$$,
    'with a three month window in June, January and February are out of it');

-- Bounds are half open, so a partition whose upper bound is exactly the
-- cutoff holds no row inside the window and goes with the rest. On 1 June the
-- cutoff is 1 March, which is February's upper bound.
SELECT is((SELECT count(*)::integer FROM ppm.retention_victims('rt', '2026-06-01 00:00+00')), 2,
          'a partition ending exactly at the cutoff is outside the window');

-- March straddles the cutoff on 20 June minus three months, so it stays.
SELECT ok((SELECT count(*) FROM ppm.retention_victims('rt', '2026-06-20 00:00+00')
            WHERE child = 'rt_202603'::regclass) = 0,
          'a partition holding the cutoff is kept, not trimmed');

-- dry_run
SELECT is((SELECT count(*)::integer
             FROM ppm.apply_retention('rt', '2026-06-20 00:00+00', dry_run := true)), 2,
          'a dry run returns one DETACH per partition');
SELECT is((SELECT count(*)::integer FROM ppm.partitions('rt')), 6,
          'and detaches nothing');

-- Default action is detach, and the table survives as a standalone table.
SELECT is((SELECT count(*)::integer
             FROM ppm.apply_retention('rt', '2026-06-20 00:00+00')), 2,
          'the real run detaches two');
SELECT is((SELECT count(*)::integer FROM ppm.partitions('rt')), 4,
          'the set is down to four partitions');
SELECT has_table('public', 'rt_202601', 'the detached partition is still a table');
SELECT is((SELECT count(*)::integer FROM pg_inherits
            WHERE inhrelid = 'rt_202601'::regclass), 0,
          'and is no longer attached to anything');
SELECT is((SELECT action FROM ppm.run_log
            WHERE target_name = 'public.rt_202601' AND NOT dry_run ORDER BY id DESC LIMIT 1),
          'detach', 'the log says what happened to it');

-- Nothing to do is a notice, not an error.
SELECT is((SELECT count(*)::integer
             FROM ppm.apply_retention('rt', '2026-06-20 00:00+00')), 0,
          'running it again does nothing');

-- A window that would empty the set.
SELECT throws_ok(
    $$SELECT * FROM ppm.apply_retention('rt', '2027-06-20 00:00+00')$$,
    '22023',
    NULL,
    'a window that would remove every partition is refused');
SELECT is((SELECT count(*)::integer FROM ppm.partitions('rt')), 4,
          'and the set is untouched by the refusal');
SELECT is((SELECT count(*)::integer
             FROM ppm.apply_retention('rt', '2027-06-20 00:00+00', allow_empty := true)), 4,
          'allow_empty says it really was the intention');
SELECT is((SELECT count(*)::integer FROM ppm.partitions('rt')), 0,
          'and then the set has no partitions left');

-- retention_action = drop
\o /dev/null
SELECT fixture.new_parent('rd');
SELECT ppm.register_set('rd', 'at', 'month', premake := 1,
                        retention := interval '2 months', retention_action := 'drop');
SELECT ppm.create_ahead('rd', '2026-01-15 00:00+00');
SELECT ppm.create_ahead('rd', '2026-04-15 00:00+00');
\o
SELECT is((SELECT count(*)::integer
             FROM ppm.apply_retention('rd', '2026-05-20 00:00+00')), 4,
          'drop mode returns a DETACH and a DROP for each partition');
SELECT hasnt_table('public', 'rd_202601', 'and the table is gone');

-- archiving
CREATE SCHEMA attic;
\o /dev/null
SELECT fixture.new_parent('ra');
SELECT ppm.register_set('ra', 'at', 'month', premake := 1,
                        retention := interval '2 months', archive_schema := 'attic');
SELECT ppm.create_ahead('ra', '2026-01-15 00:00+00');
SELECT ppm.create_ahead('ra', '2026-04-15 00:00+00');
SELECT ppm.apply_retention('ra', '2026-05-20 00:00+00');
\o
SELECT has_table('attic', 'ra_202601', 'an archived partition moves to the archive schema');
SELECT hasnt_table('public', 'ra_202601', 'and leaves the schema it was in');

-- Rebuilding the partitions that were just archived leaves the archive
-- schema holding those names already, which is the collision a long enough
-- backfill will hit for real.
\o /dev/null
SELECT ppm.create_ahead('ra', '2026-01-15 00:00+00');
\o
SELECT throws_ok(
    $$SELECT * FROM ppm.apply_retention('ra', '2026-05-20 00:00+00')$$,
    '42P07',
    NULL,
    'archiving onto a name the archive schema already holds is refused');

-- The server fact the whole design rests on. The partition has to still be
-- attached for this to be about the transaction block and nothing else.
\o /dev/null
SELECT fixture.new_parent('cc');
SELECT ppm.register_set('cc', 'at', 'day', premake := 1,
                        retention := interval '2 days');
SELECT ppm.create_ahead('cc', '2026-03-17 00:00+00');
\o
SELECT throws_ok(
    $q$DO $do$ BEGIN
        EXECUTE 'ALTER TABLE cc DETACH PARTITION cc_20260317 CONCURRENTLY';
      END $do$$q$,
    '25001',
    NULL,
    'DETACH CONCURRENTLY cannot run inside a function, which is why there is a script');

-- cc holds 17 and 18 March, and on 25 March a two day window leaves both
-- outside it.
SELECT is((SELECT count(*)::integer
             FROM ppm.retention_script('cc', '2026-03-25 00:00+00') AS s(line)
            WHERE line LIKE 'ALTER TABLE % DETACH PARTITION % CONCURRENTLY;'), 2,
          'retention_script writes the concurrent form, one per partition');
SELECT is((SELECT count(*)::integer
             FROM ppm.retention_script('cc', '2026-03-25 00:00+00') AS s(line)
            WHERE line LIKE '-- if that was interrupted: ALTER TABLE%FINALIZE;'), 2,
          'and pairs each one with the FINALIZE it may need');
SELECT is((SELECT count(*)::integer
             FROM ppm.partitions('cc')), 2,
          'and ran none of it: the partitions are still attached');

SELECT * FROM finish();
ROLLBACK;
