-- 09_log.sql
--
-- The log and the two views over it. The log is the only record of what the
-- manager did, so what it refuses to store matters as much as what it stores.

BEGIN;
SELECT plan(12);

-- clock_timestamp(), not now(): several statements inside one call would all
-- share a transaction timestamp and the order of a run would be lost.
SELECT is(
    (SELECT pg_get_expr(d.adbin, d.adrelid)
       FROM pg_attrdef d
       JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
      WHERE d.adrelid = 'ppm.run_log'::regclass AND a.attname = 'ran_at'),
    'clock_timestamp()',
    'ran_at defaults to clock_timestamp(), not to the transaction timestamp');

SELECT throws_ok(
    $$INSERT INTO ppm.run_log (parent_name, action, dry_run)
      VALUES ('public.x', 'reticulate', false)$$,
    '23514',
    NULL,
    'an action the log does not know about is refused');

SELECT throws_ok(
    $$INSERT INTO ppm.run_log (parent_name, action, dry_run)
      VALUES (NULL, 'create', false)$$,
    '23502',
    NULL,
    'a log row with no table name is refused');

\o /dev/null
SELECT ppm.log('public.ev', 'create', p_target_name := 'public.ev_20260317',
               p_statement := 'CREATE TABLE ...', p_message := 'first');
\o
SELECT ok((SELECT ran_at >= now() FROM ppm.run_log ORDER BY id DESC LIMIT 1),
          'a row written now is not stamped before the transaction started');

-- recent_runs is the last day only, so a monitoring query does not read the
-- whole history to find out whether last night ran.
UPDATE ppm.run_log SET ran_at = now() - interval '2 days'
 WHERE parent_name = 'public.ev';
SELECT is((SELECT count(*)::integer FROM ppm.recent_runs WHERE parent_name = 'public.ev'), 0,
          'a two day old row is out of recent_runs');
\o /dev/null
SELECT ppm.log('public.ev', 'create', p_message := 'second');
\o
SELECT is((SELECT count(*)::integer FROM ppm.recent_runs WHERE parent_name = 'public.ev'), 1,
          'and a new one is in it');
SELECT is((SELECT count(*)::integer FROM ppm.run_log WHERE parent_name = 'public.ev'), 2,
          'while the log itself keeps both');

-- ppm.managed
\o /dev/null
SELECT fixture.new_parent('mg', with_default := true);
SELECT ppm.register_set('mg', 'at', 'week', premake := 3,
                        retention := interval '8 weeks');
SELECT ppm.create_ahead('mg', '2026-03-17 11:00+00');
\o
SELECT is((SELECT partition_count::integer FROM ppm.managed WHERE parent_name = 'public.mg'), 5,
          'managed counts the partitions, the default included');
SELECT ok((SELECT has_default FROM ppm.managed WHERE parent_name = 'public.mg'),
          'and says the set has a default partition');
SELECT is((SELECT granularity FROM ppm.managed WHERE parent_name = 'public.mg'), 'week',
          'with the settings it was registered with');

-- A dropped table leaves a registry row whose OID resolves to nothing. The
-- view hides it; prune_registry() removes it.
\o /dev/null
SELECT fixture.new_parent('gone');
SELECT ppm.register_set('gone', 'at', 'day');
\o
SELECT count(*)::integer AS dangling_before FROM ppm.partition_set
 WHERE NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = parent_table) \gset

DROP TABLE gone;
SELECT is((SELECT count(*)::integer FROM ppm.managed WHERE granularity = 'day'), 0,
          'managed does not show a set whose table has been dropped');
SELECT is((SELECT count(*)::integer FROM ppm.partition_set
            WHERE NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = parent_table))
          - :dangling_before, 1,
          'though the row is still there until prune_registry runs');

SELECT * FROM finish();
ROLLBACK;
