-- 02_inspect.sql
--
-- Reading bounds back out of pg_class.relpartbound, including the shapes this
-- manager refuses to read.

BEGIN;
SELECT plan(19);

-- Setup output is sent to /dev/null: a fixture function returns a value, and
-- psql would print it into the middle of the TAP stream.
\o /dev/null
SELECT fixture.new_parent('ev', with_default := true);
\o
CREATE TABLE ev_202603 PARTITION OF ev
    FOR VALUES FROM ('2026-03-01 00:00+00') TO ('2026-04-01 00:00+00');
CREATE TABLE ev_202604 PARTITION OF ev
    FOR VALUES FROM ('2026-04-01 00:00+00') TO ('2026-05-01 00:00+00');
CREATE TABLE ev_old PARTITION OF ev
    FOR VALUES FROM (MINVALUE) TO ('2026-03-01 00:00+00');

SELECT is((ppm.partition_bounds('ev_202603')).lower_bound,
          '2026-03-01 00:00+00'::timestamptz, 'the lower bound comes back');
SELECT is((ppm.partition_bounds('ev_202603')).upper_bound,
          '2026-04-01 00:00+00'::timestamptz, 'and the upper bound');

-- pg_get_expr renders the literal in the session's TimeZone, so the text
-- changes when a client changes zone. Casting it back gives the same instant,
-- which is the whole reason this is safe to parse.
SET LOCAL TimeZone = 'America/Denver';
SELECT is((ppm.partition_bounds('ev_202603')).lower_bound,
          '2026-03-01 00:00+00'::timestamptz,
          'the same instant comes back in a different session zone');
SET LOCAL TimeZone = 'UTC';

SELECT ok((ppm.partition_bounds('ev_default')).lower_bound IS NULL
          AND (ppm.partition_bounds('ev_default')).upper_bound IS NULL,
          'the default partition has no bounds, and that is not an error');

SELECT is((ppm.partition_bounds('ev_old')).lower_bound, '-infinity'::timestamptz,
          'MINVALUE reads as -infinity');

SELECT throws_ok(
    $$SELECT ppm.partition_bounds('ev')$$,
    '42809',
    NULL,
    'a partitioned parent is not itself a partition');

SELECT lives_ok($$CREATE TABLE plain (id bigint)$$, 'a plain table is created');
SELECT throws_ok(
    $$SELECT ppm.partition_bounds('plain')$$,
    '42809',
    NULL,
    'a table that is not a partition is refused');

CREATE TABLE by_list (id bigint, region text) PARTITION BY LIST (region);
CREATE TABLE by_list_eu PARTITION OF by_list FOR VALUES IN ('eu');
SELECT throws_ok(
    $$SELECT ppm.partition_bounds('by_list_eu')$$,
    '0A000',
    NULL,
    'a list partition is refused rather than mis-parsed');

CREATE TABLE two_key (a timestamptz NOT NULL, b int NOT NULL) PARTITION BY RANGE (a, b);
CREATE TABLE two_key_1 PARTITION OF two_key FOR VALUES FROM ('2026-01-01', 0) TO ('2026-02-01', 0);
SELECT throws_ok(
    $$SELECT ppm.partition_bounds('two_key_1')$$,
    '0A000',
    NULL,
    'a two column partition key is refused');

-- default_partition

SELECT is(ppm.default_partition('ev'), 'ev_default'::regclass,
          'the default partition is found');
\o /dev/null
SELECT fixture.new_parent('nodefault');
\o
SELECT is(ppm.default_partition('nodefault'), NULL,
          'a set with no default partition says so');

-- partitions()

SELECT is((SELECT count(*)::integer FROM ppm.partitions('ev')), 4,
          'four partitions are listed');
SELECT is((SELECT child FROM ppm.partitions('ev') WHERE is_default), 'ev_default'::regclass,
          'exactly one of them is the default');
SELECT results_eq(
    $$SELECT child::text FROM ppm.partitions('ev') WHERE NOT is_default
       ORDER BY lower_bound$$,
    $$VALUES ('ev_old'), ('ev_202603'), ('ev_202604')$$,
    'they come back in bound order');

SELECT is((SELECT approx_rows FROM ppm.partitions('ev') WHERE child = 'ev_202603'::regclass),
          NULL,
          'approx_rows is NULL before the first ANALYZE, not zero');

\o /dev/null
SELECT fixture.seed('ev', '2026-03-10 00:00+00', 10);
\o
ANALYZE ev_202603;
SELECT is((SELECT approx_rows FROM ppm.partitions('ev') WHERE child = 'ev_202603'::regclass),
          10::bigint,
          'and an estimate once the partition has been analysed');

-- qualified_name and prune_registry

SELECT is(ppm.qualified_name('ev'), 'public.ev', 'a plain name needs no quoting');

INSERT INTO ppm.partition_set (parent_table, partition_key, granularity)
VALUES ('plain', 'id', 'day');
DROP TABLE plain;
SELECT is(ppm.prune_registry(), 1,
          'a registry row whose table was dropped is pruned');

SELECT * FROM finish();
ROLLBACK;
