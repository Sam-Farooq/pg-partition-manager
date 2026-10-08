-- 08_index_script.sql
--
-- Like 05_attach.sql this file runs without a transaction, because the script
-- it checks contains CREATE INDEX CONCURRENTLY, which cannot run inside one.
-- It executes the script with \gexec, which is how the script is meant to be
-- used, and drops what it made at the end.

DROP TABLE IF EXISTS ix CASCADE;

SELECT plan(14);

\o /dev/null
SELECT fixture.new_parent('ix');
SELECT ppm.register_set('ix', 'at', 'day', premake := 2);
SELECT ppm.create_ahead('ix', '2026-03-17 11:00+00');
\o

SELECT is((SELECT count(*)::integer FROM ppm.partitions('ix')), 3,
          'three partitions to index');

-- The shape of the script: a parent index on ONLY, a concurrent build per
-- partition, an attach per partition.
SELECT is((SELECT count(*)::integer FROM ppm.index_script('ix', 'ix_at_idx', 'at') AS s(line)
            WHERE line LIKE 'CREATE INDEX % ON ONLY %'), 1,
          'one parent index, created ON ONLY so no partition is touched');
SELECT is((SELECT count(*)::integer FROM ppm.index_script('ix', 'ix_at_idx', 'at') AS s(line)
            WHERE line LIKE 'CREATE INDEX CONCURRENTLY %'), 3,
          'one concurrent build per partition');
SELECT is((SELECT count(*)::integer FROM ppm.index_script('ix', 'ix_at_idx', 'at') AS s(line)
            WHERE line LIKE 'ALTER INDEX % ATTACH PARTITION %'), 3,
          'one attach per partition');
SELECT ok((SELECT min(n) FROM (SELECT row_number() OVER () AS n, line
                                 FROM ppm.index_script('ix', 'ix_at_idx', 'at') AS s(line)) t
            WHERE line LIKE 'ALTER INDEX%')
          > (SELECT max(n) FROM (SELECT row_number() OVER () AS n, line
                                   FROM ppm.index_script('ix', 'ix_at_idx', 'at') AS s(line)) t
              WHERE line LIKE 'CREATE INDEX CONCURRENTLY%'),
          'every build comes before every attach');
SELECT matches(
    (SELECT line FROM ppm.index_script('ix', 'ix_at_idx', 'at') AS s(line)
      WHERE line LIKE 'CREATE INDEX CONCURRENTLY%' LIMIT 1),
    'ix_20260317_at_idx',
    'the partition index is named for the partition, not for the parent twice');

SELECT hasnt_index('public', 'ix', 'ix_at_idx',
                   'and after all that reading, nothing has been created');

-- Now run it, which is the only way to know the statements are right.
SELECT line FROM ppm.index_script('ix', 'ix_at_idx', 'at') AS s(line)
 WHERE line NOT LIKE '--%' \gexec

SELECT has_index('public', 'ix', 'ix_at_idx', 'the parent index exists');
SELECT ok((SELECT indisvalid FROM pg_index WHERE indexrelid = 'ix_at_idx'::regclass),
          'and is valid, which only happens once every partition is attached');
SELECT is((SELECT count(*)::integer FROM pg_inherits
            WHERE inhparent = 'ix_at_idx'::regclass), 3,
          'with all three partition indexes attached to it');
SELECT has_index('public', 'ix_20260317', 'ix_20260317_at_idx',
                 'the partition carries its own index');

-- A new partition made after the index exists gets one without any of this:
-- the server builds it as part of the CREATE.
\o /dev/null
SELECT ppm.create_ahead('ix', '2026-03-21 11:00+00');
\o
SELECT has_index('public', 'ix_20260321', 'ix_20260321_at_idx',
                 'a partition created later gets the index from the parent');

-- Refusals
SELECT throws_ok(
    $$SELECT * FROM ppm.index_script('ix', 'ix_body_uq', 'body', is_unique := true)$$,
    '0A000',
    NULL,
    'a unique index that leaves out the partition key is refused');
SELECT throws_ok(
    $$SELECT * FROM ppm.index_script('ix', 'ix_at_idx', 'at')$$,
    '42P07',
    NULL,
    'an index name that is already taken is refused');

SELECT * FROM finish();

DROP TABLE ix CASCADE;
