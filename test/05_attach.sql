-- 05_attach.sql
--
-- This file runs in autocommit, and that is deliberate. Table statistics are
-- accumulated per backend and flushed when a transaction ends,
-- so a seq_scan count read inside the same transaction as the work is the
-- count from before the work. The claim being tested is about which
-- statements read a table, so the statements have to commit.
--
-- It therefore cleans up after itself at the end instead of rolling back.

DROP TABLE IF EXISTS att CASCADE;
DROP TABLE IF EXISTS att_naive CASCADE;
DROP TABLE IF EXISTS att_prepared CASCADE;
DROP TABLE IF EXISTS att_notvalid CASCADE;
DROP TABLE IF EXISTS att_wrongrange CASCADE;
DROP TABLE IF EXISTS att_split CASCADE;

SELECT plan(17);

\o /dev/null
SELECT fixture.new_parent('att', with_default := true);
SELECT fixture.new_orphan('att_naive', rows := 2000, at := '2026-04-10 12:00+00');
SELECT fixture.new_orphan('att_prepared', rows := 2000, at := '2026-05-10 12:00+00');
SELECT fixture.new_orphan('att_notvalid', rows := 10, at := '2026-06-10 12:00+00');
SELECT fixture.new_orphan('att_wrongrange', rows := 10, at := '2026-07-10 12:00+00');
SELECT fixture.new_orphan('att_split', rows := 2000, at := '2026-09-10 12:00+00');
\o

-- An unprepared table is refused rather than attached expensively.
SELECT throws_ok(
    $$SELECT ppm.attach_prepared('att', 'att_naive',
          '2026-04-01 00:00+00', '2026-05-01 00:00+00')$$,
    '55000',
    NULL,
    'attach_prepared refuses a table with no bounds constraint');

-- What it refuses to do, done by hand, so the cost of it is on the record.
\o /dev/null
SELECT pg_stat_force_next_flush();
\o
SELECT fixture.seq_scans('att_naive') AS naive_before \gset
SELECT fixture.seq_scans('att_default') AS default_before_naive \gset

ALTER TABLE att ATTACH PARTITION att_naive
    FOR VALUES FROM ('2026-04-01 00:00+00') TO ('2026-05-01 00:00+00');

\o /dev/null
SELECT pg_stat_force_next_flush();
\o
SELECT is(fixture.seq_scans('att_naive') - :naive_before, 1::bigint,
          'ATTACH with no matching CHECK reads the whole table');
SELECT is(fixture.seq_scans('att_default') - :default_before_naive, 1::bigint,
          'and reads the default partition as well');

-- The prepared route. Two statements, and the scan is in the second one.
SELECT is((SELECT count(*)::integer FROM ppm.prepare_for_attach(
              'att_prepared', 'at', '2026-05-01 00:00+00', '2026-06-01 00:00+00',
              dry_run := true)), 2,
          'prepare_for_attach is two statements: ADD CONSTRAINT then VALIDATE');
SELECT is((SELECT count(*)::integer FROM pg_constraint
            WHERE conrelid = 'att_prepared'::regclass), 0,
          'and a dry run adds neither');

SELECT fixture.seq_scans('att_prepared') AS prep_before \gset

\o /dev/null
SELECT ppm.prepare_for_attach('att_prepared', 'at',
    '2026-05-01 00:00+00', '2026-06-01 00:00+00');
SELECT pg_stat_force_next_flush();
\o

SELECT is(fixture.seq_scans('att_prepared') - :prep_before, 1::bigint,
          'VALIDATE CONSTRAINT scans the table once, under SHARE UPDATE EXCLUSIVE');
SELECT ok((SELECT convalidated FROM pg_constraint
            WHERE conrelid = 'att_prepared'::regclass
              AND conname = 'att_prepared_ppm_bounds'),
          'the constraint it leaves behind is validated');

-- The two halves of prepare_for_attach(), measured one at a time, so that
-- the claim about which statement reads the table is about one statement. The
-- statements are taken from the function's own dry run and run with \gexec,
-- so this cannot drift from what the function would really do.
\o /dev/null
SELECT pg_stat_force_next_flush();
\o
SELECT fixture.seq_scans('att_split') AS split_before \gset

SELECT line FROM (
    SELECT row_number() OVER () AS n, p AS line
      FROM ppm.prepare_for_attach('att_split', 'at',
               '2026-09-01 00:00+00', '2026-10-01 00:00+00', dry_run := true) p
) t WHERE n = 1 \gexec

\o /dev/null
SELECT pg_stat_force_next_flush();
\o
SELECT is(fixture.seq_scans('att_split') - :split_before, 0::bigint,
          'ADD CONSTRAINT ... NOT VALID does not read the table');

-- Asked again, with the constraint there but not validated, it returns the one
-- statement that is still missing. That is also the recovery path for a
-- VALIDATE that was interrupted.
SELECT is((SELECT count(*)::integer FROM ppm.prepare_for_attach(
              'att_split', 'at', '2026-09-01 00:00+00', '2026-10-01 00:00+00',
              dry_run := true)), 1,
          'a constraint left NOT VALID leaves one statement to run');

SELECT line FROM (
    SELECT row_number() OVER () AS n, p AS line
      FROM ppm.prepare_for_attach('att_split', 'at',
               '2026-09-01 00:00+00', '2026-10-01 00:00+00', dry_run := true) p
) t WHERE n = 1 \gexec

\o /dev/null
SELECT pg_stat_force_next_flush();
\o
SELECT is(fixture.seq_scans('att_split') - :split_before, 1::bigint,
          'and VALIDATE CONSTRAINT is the statement that reads it');

-- Calling it again is a notice and no statements.
SELECT is((SELECT count(*)::integer FROM ppm.prepare_for_attach(
              'att_prepared', 'at', '2026-05-01 00:00+00', '2026-06-01 00:00+00')), 0,
          'preparing an already prepared table runs nothing');

SELECT fixture.seq_scans('att_prepared') AS attach_before \gset
SELECT fixture.seq_scans('att_default') AS default_before_prepared \gset

\o /dev/null
SELECT ppm.attach_prepared('att', 'att_prepared',
    '2026-05-01 00:00+00', '2026-06-01 00:00+00');
SELECT pg_stat_force_next_flush();
\o

-- The point of the whole file.
SELECT is(fixture.seq_scans('att_prepared') - :attach_before, 0::bigint,
          'ATTACH with a validated CHECK does not read the table at all');
SELECT is(fixture.seq_scans('att_default') - :default_before_prepared, 1::bigint,
          'the default partition is still read: that scan cannot be prepared away');

SELECT is((ppm.partition_bounds('att_prepared')).upper_bound,
          '2026-06-01 00:00+00'::timestamptz,
          'and the partition is attached with the bounds asked for');

-- A constraint that is NOT VALID is worse than none: it looks prepared and
-- the attach still scans.
ALTER TABLE att_notvalid ADD CONSTRAINT att_notvalid_ppm_bounds
    CHECK (at IS NOT NULL AND at >= '2026-06-01 00:00+00' AND at < '2026-07-01 00:00+00')
    NOT VALID;
SELECT throws_like(
    $$SELECT ppm.attach_prepared('att', 'att_notvalid',
          '2026-06-01 00:00+00', '2026-07-01 00:00+00')$$,
    '%is NOT VALID, so ATTACH would scan the table anyway%',
    'a NOT VALID constraint is refused and the reason given');

-- Prepared for one range, attached to another.
\o /dev/null
SELECT ppm.prepare_for_attach('att_wrongrange', 'at',
    '2026-07-01 00:00+00', '2026-08-01 00:00+00');
\o
SELECT throws_ok(
    $$SELECT ppm.attach_prepared('att', 'att_wrongrange',
          '2026-08-01 00:00+00', '2026-09-01 00:00+00')$$,
    '55000',
    NULL,
    'a constraint for a different range does not count as prepared');

SELECT throws_ok(
    $$SELECT ppm.prepare_for_attach('att_prepared', 'at',
          '2026-05-01 00:00+00', '2026-06-01 00:00+00')$$,
    '42809',
    NULL,
    'a table that is already a partition cannot be prepared again');

SELECT * FROM finish();

DROP TABLE att CASCADE;
DROP TABLE att_notvalid;
DROP TABLE att_wrongrange;
DROP TABLE att_split;
