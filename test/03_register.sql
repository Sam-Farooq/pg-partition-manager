-- 03_register.sql
--
-- register_set() is the only place that validates, so this is the longest
-- list of refusals in the suite.

BEGIN;
SELECT plan(21);

\o /dev/null
SELECT fixture.new_parent('ev');
\o

SELECT lives_ok(
    $$SELECT ppm.register_set('ev', 'at', 'day', premake := 7,
                              retention := interval '30 days')$$,
    'a range partitioned table with a timestamptz key registers');

SELECT is((SELECT granularity FROM ppm.partition_set WHERE parent_table = 'ev'::regclass),
          'day', 'the granularity is stored');
SELECT is((SELECT bound_tz FROM ppm.partition_set WHERE parent_table = 'ev'::regclass),
          'UTC', 'boundaries default to UTC rather than to the session zone');
SELECT is((SELECT premake FROM ppm.partition_set WHERE parent_table = 'ev'::regclass),
          7, 'premake is stored');

-- Registering again is an update, not a second row: the registry is keyed by
-- the table.
SELECT lives_ok(
    $$SELECT ppm.register_set('ev', 'at', 'month', premake := 2,
                              retention := interval '1 year')$$,
    'registering a second time is allowed');
SELECT is((SELECT count(*)::integer FROM ppm.partition_set
            WHERE parent_table = 'ev'::regclass), 1,
          'and leaves one row, not two');
SELECT is((SELECT granularity FROM ppm.partition_set WHERE parent_table = 'ev'::regclass),
          'month', 'with the new settings');

-- Refusals

\o /dev/null
SELECT fixture.new_orphan('plain_table');
\o
SELECT throws_ok(
    $$SELECT ppm.register_set('plain_table', 'at', 'day')$$,
    '42809',
    NULL,
    'a table that is not partitioned is refused');

CREATE TABLE by_list (id bigint, region text) PARTITION BY LIST (region);
SELECT throws_ok(
    $$SELECT ppm.register_set('by_list', 'region', 'day')$$,
    '0A000',
    NULL,
    'list partitioning is refused');

-- The partition key has to be an immutable expression, which rules out
-- date_trunc(), so this one keys on arithmetic instead. What is under test is
-- partattrs[0] = 0, which is how the catalogue says "expression".
CREATE TABLE by_expr (id bigint, at timestamptz NOT NULL)
    PARTITION BY RANGE ((id + 1));
SELECT throws_ok(
    $$SELECT ppm.register_set('by_expr', 'at', 'day')$$,
    '0A000',
    NULL,
    'an expression partition key is refused');

CREATE TABLE by_date (id bigint, on_day date NOT NULL) PARTITION BY RANGE (on_day);
SELECT throws_ok(
    $$SELECT ppm.register_set('by_date', 'on_day', 'day')$$,
    '0A000',
    'partition key public.by_date.on_day is date, not timestamptz',
    'a date key is refused by name, with the type in the message');

SELECT throws_ok(
    $$SELECT ppm.register_set('ev', 'created_at', 'day')$$,
    '22023',
    'public.ev is partitioned by at, not by created_at',
    'the wrong key column is refused and the right one named');

SELECT throws_ok(
    $$SELECT ppm.register_set('ev', 'at', 'fortnight')$$,
    '22023',
    NULL,
    'an unsupported granularity is refused');

SELECT throws_ok(
    $$SELECT ppm.register_set('ev', 'at', 'day', bound_tz := 'Mars/Olympus')$$,
    '22023',
    NULL,
    'an unknown time zone is refused at registration, not on the first run');

-- Retention narrower than two partitions can only ever point at the partition
-- currently being written to.
SELECT throws_ok(
    $$SELECT ppm.register_set('ev', 'at', 'month', retention := interval '20 days')$$,
    '22023',
    NULL,
    'retention shorter than two partitions is refused');

SELECT throws_ok(
    $$SELECT ppm.register_set('ev', 'at', 'day', archive_schema := 'no_such_schema')$$,
    '3F000',
    NULL,
    'an archive schema that does not exist is refused');

SELECT throws_ok(
    $$SELECT ppm.register_set('ev', 'at', 'day', premake := 0)$$,
    '23514',
    NULL,
    'premake below one is refused by the table constraint');

SELECT throws_ok(
    $$SELECT ppm.register_set('ev', 'at', 'day', retention_action := 'drop',
                              archive_schema := 'public')$$,
    '23514',
    NULL,
    'archiving and dropping at the same time is refused');

-- unregister

SELECT is(ppm.unregister_set('ev'), true, 'unregister removes the settings');
SELECT is((SELECT count(*)::integer FROM pg_inherits WHERE inhparent = 'ev'::regclass), 0,
          'and leaves the table alone');
SELECT is(ppm.unregister_set('ev'), false,
          'unregistering something unmanaged says so rather than failing');

SELECT * FROM finish();
ROLLBACK;
