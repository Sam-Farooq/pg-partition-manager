-- 07_drain_default.sql

BEGIN;
SELECT plan(21);

\o /dev/null
SELECT fixture.new_parent('dn', with_default := true);
SELECT ppm.register_set('dn', 'at', 'day', premake := 1);
-- Three days of rows, all of them landing in the default because no daily
-- partition exists yet.
SELECT fixture.seed('dn', '2026-03-17 06:00+00', 5);
SELECT fixture.seed('dn', '2026-03-17 20:00+00', 3);
SELECT fixture.seed('dn', '2026-03-18 09:00+00', 4);
SELECT fixture.seed('dn', '2026-03-19 09:00+00', 2);
\o

SELECT is(fixture.row_count('dn_default'), 14::bigint,
          'fourteen rows are sitting in the default partition');

-- Until they move, the partition they belong in cannot be created at all.
SELECT throws_ok(
    $$SELECT * FROM ppm.create_ahead('dn', '2026-03-17 11:00+00')$$,
    '55000',
    NULL,
    'create_ahead cannot make a partition for a range the default holds');

-- dry run
SELECT is((SELECT count(*)::integer FROM ppm.drain_default('dn', dry_run := true)), 4,
          'a dry run returns the create, the move, and the two calls that follow');
SELECT is(fixture.row_count('dn_default'), 14::bigint, 'and moves nothing');
SELECT is((SELECT count(*)::integer FROM ppm.partitions('dn')), 1,
          'and creates nothing: only the default is attached');
SELECT matches(
    (SELECT statement FROM ppm.run_log WHERE action = 'drain' AND dry_run ORDER BY id LIMIT 1),
    'WITH moved AS \(DELETE FROM public\.dn_default',
    'the logged statement is the move itself');

-- one range per call by default
-- Five statements, where the dry run printed four lines: the dry run names
-- prepare_for_attach() as one call, and it runs as two statements.
SELECT is((SELECT count(*)::integer FROM ppm.drain_default('dn')), 5,
          'a real call runs five statements for one range');
SELECT is(fixture.row_count('dn_default'), 6::bigint,
          'the eight rows from 17 March have left the default');
SELECT is(fixture.row_count('dn_20260317'), 8::bigint,
          'and are in the partition for that day');
SELECT ok((SELECT count(*) FROM ppm.partitions('dn')
            WHERE child = 'dn_20260317'::regclass AND NOT is_default) = 1,
          'which is attached to the set');
SELECT is((ppm.partition_bounds('dn_20260317')).lower_bound,
          '2026-03-17 00:00+00'::timestamptz,
          'with the bounds the set would have given it');
SELECT is((SELECT rows_moved FROM ppm.run_log
            WHERE action = 'drain' AND NOT dry_run ORDER BY id DESC LIMIT 1), 8::bigint,
          'and the log records how many rows moved');

-- The constraint the attach needed is still there afterwards, which is
-- harmless and is what makes the partition cheap to detach and reattach.
SELECT ok((SELECT convalidated FROM pg_constraint
            WHERE conrelid = 'dn_20260317'::regclass
              AND conname = 'dn_20260317_ppm_bounds'),
          'the validated bounds constraint stays on the partition');

-- The rest of the rows, two ranges in one call.
SELECT is((SELECT count(*)::integer FROM ppm.drain_default('dn', max_ranges := 2)), 10,
          'two ranges in one call is ten statements');
SELECT is(fixture.row_count('dn_default'), 0::bigint, 'the default is empty');
SELECT is(fixture.row_count('dn'), 14::bigint,
          'and every row is still readable through the parent');

-- With the default drained, the thing that failed at the top now works.
SELECT is((SELECT count(*)::integer FROM ppm.create_ahead('dn', '2026-03-19 11:00+00')), 1,
          'create_ahead works once the default no longer holds that range');

-- An empty default is a notice, not an error.
SELECT is((SELECT count(*)::integer FROM ppm.drain_default('dn')), 0,
          'draining an empty default does nothing');

-- Refusals
\o /dev/null
SELECT fixture.new_parent('nd');
SELECT ppm.register_set('nd', 'at', 'day');
\o
SELECT is((SELECT count(*)::integer FROM ppm.drain_default('nd')), 0,
          'a set with no default partition has nothing to drain');

\o /dev/null
SELECT fixture.new_parent('un', with_default := true);
\o
SELECT throws_ok(
    $$SELECT * FROM ppm.drain_default('un')$$,
    'P0002',
    NULL,
    'an unregistered table is refused');

SELECT throws_ok(
    $$SELECT * FROM ppm.drain_default('dn', max_ranges := 0)$$,
    '22023',
    NULL,
    'max_ranges below one is refused');

SELECT * FROM finish();
ROLLBACK;
