-- 04_create_ahead.sql
--
-- as_of is an argument rather than now() in the body so that these tests are
-- about a fixed week in March 2026 and do not change answer tomorrow.

BEGIN;
SELECT plan(19);

\o /dev/null
SELECT fixture.new_parent('ev');
SELECT ppm.register_set('ev', 'at', 'day', premake := 7);
SELECT ppm.create_ahead('ev', '2026-03-17 11:00+00');
\o

-- premake 7 means the period containing as_of plus seven more.
SELECT is((SELECT count(*)::integer FROM ppm.partitions('ev')), 8,
          'a daily set with premake 7 ends up with eight partitions');

SELECT results_eq(
    $$SELECT child::text FROM ppm.partitions('ev') ORDER BY lower_bound$$,
    $$VALUES ('ev_20260317'), ('ev_20260318'), ('ev_20260319'), ('ev_20260320'),
             ('ev_20260321'), ('ev_20260322'), ('ev_20260323'), ('ev_20260324')$$,
    'named for the day each one starts');

SELECT is((SELECT lower_bound FROM ppm.partitions('ev') ORDER BY lower_bound LIMIT 1),
          '2026-03-17 00:00+00'::timestamptz,
          'the first one starts at midnight UTC on the day of as_of');

-- No gaps and no overlaps: every upper bound is the next lower bound. A gap
-- is the failure that only shows up as a failed INSERT at midnight.
SELECT is((SELECT count(*)::integer
             FROM (SELECT upper_bound,
                          lead(lower_bound) OVER (ORDER BY lower_bound) AS next_lower
                     FROM ppm.partitions('ev')) t
            WHERE next_lower IS NOT NULL AND next_lower <> upper_bound), 0,
          'the partitions tile the range with no gap and no overlap');

-- Idempotent

SELECT is((SELECT count(*)::integer
             FROM ppm.create_ahead('ev', '2026-03-17 11:00+00')), 0,
          'a second run with the same anchor runs no DDL');
SELECT is((SELECT count(*)::integer FROM ppm.partitions('ev')), 8,
          'and leaves the eight partitions alone');

-- A day later, one more partition is needed.
SELECT is((SELECT count(*)::integer
             FROM ppm.create_ahead('ev', '2026-03-18 11:00+00')), 1,
          'a day later it adds exactly one');
SELECT ok((SELECT count(*) FROM ppm.partitions('ev') WHERE child::text = 'ev_20260325') = 1,
          'and the new one is the day that came into range');

-- dry_run

\o /dev/null
SELECT fixture.new_parent('dr');
SELECT ppm.register_set('dr', 'at', 'month', premake := 2);
\o
SELECT is((SELECT count(*)::integer
             FROM ppm.create_ahead('dr', '2026-03-17 11:00+00', dry_run := true)), 3,
          'dry_run returns the three statements it would have run');
SELECT is((SELECT count(*)::integer FROM ppm.partitions('dr')), 0,
          'and creates nothing');
SELECT matches(
    (SELECT statement FROM ppm.run_log
      WHERE parent_name = 'public.dr' AND dry_run ORDER BY id LIMIT 1),
    'CREATE TABLE public\.dr_202603 PARTITION OF public\.dr',
    'the logged statement is the DDL, not a description of it');
SELECT is((SELECT count(*)::integer FROM ppm.run_log
            WHERE parent_name = 'public.dr' AND action = 'create' AND NOT dry_run), 0,
          'a dry run logs nothing as done');

-- Monthly bounds land on the first of the month, which is the case that a
-- 30 day interval would get wrong by February.
\o /dev/null
SELECT ppm.create_ahead('dr', '2026-01-15 11:00+00');
\o
SELECT results_eq(
    $$SELECT child::text FROM ppm.partitions('dr') ORDER BY lower_bound$$,
    $$VALUES ('dr_202601'), ('dr_202602'), ('dr_202603')$$,
    'monthly names are the month, and February is one partition');
SELECT is((SELECT upper_bound FROM ppm.partitions('dr')
            WHERE child::text = 'dr_202602'), '2026-03-01 00:00+00'::timestamptz,
          'February stops on 1 March, not on the 30th day');

-- Failure paths

\o /dev/null
SELECT fixture.new_parent('unmanaged');
\o
SELECT throws_ok(
    $$SELECT * FROM ppm.create_ahead('unmanaged', '2026-03-17 11:00+00')$$,
    'P0002',
    NULL,
    'an unregistered table is refused');

-- A partition made by hand at a different granularity overlaps the daily ones.
\o /dev/null
SELECT fixture.new_parent('ov');
SELECT ppm.register_set('ov', 'at', 'day', premake := 3);
\o
CREATE TABLE ov_handmade PARTITION OF ov
    FOR VALUES FROM ('2026-03-18 00:00+00') TO ('2026-03-25 00:00+00');
SELECT throws_like(
    $$SELECT * FROM ppm.create_ahead('ov', '2026-03-17 11:00+00')$$,
    '%overlaps existing partition public.ov_handmade%',
    'an overlapping partition is named rather than left to the server');

-- A plain table already holding the name a partition wants.
\o /dev/null
SELECT fixture.new_parent('nc');
SELECT ppm.register_set('nc', 'at', 'day', premake := 1);
\o
CREATE TABLE nc_20260317 (id bigint);
SELECT throws_ok(
    $$SELECT * FROM ppm.create_ahead('nc', '2026-03-17 11:00+00')$$,
    '42P07',
    NULL,
    'a name already taken by something that is not a partition is refused');

-- The default partition holding rows that belong in a range being created.
-- The server says "updated partition constraint for default partition would
-- be violated by some row", which does not tell anyone what to do next.
\o /dev/null
SELECT fixture.new_parent('dd', with_default := true);
SELECT ppm.register_set('dd', 'at', 'day', premake := 1);
SELECT fixture.seed('dd', '2026-03-17 06:00+00', 5);
\o
SELECT throws_ok(
    $$SELECT * FROM ppm.create_ahead('dd', '2026-03-17 11:00+00')$$,
    '55000',
    NULL,
    'a default partition holding rows for the new range stops the create');
SELECT throws_like(
    $$SELECT * FROM ppm.create_ahead('dd', '2026-03-17 11:00+00')$$,
    '%default partition public.dd_default holds rows%',
    'and the message names the default partition');

SELECT * FROM finish();
ROLLBACK;
