-- 01_bounds.sql
--
-- bounds_for() and partition_name(). These two decide every partition name and
-- every boundary in the repository, so the failure paths are tested as hard as
-- the happy ones.

BEGIN;
SELECT plan(23);

-- granularity_step

SELECT is(ppm.granularity_step('day'), interval '1 day', 'a day is a day');
SELECT is(ppm.granularity_step('week'), interval '7 days', 'a week is seven days');
SELECT is(ppm.granularity_step('month'), interval '1 month',
          'a month is one month, not 30 days');
SELECT is(ppm.granularity_step('hour'), NULL,
          'an unsupported granularity has no step');

-- bounds_for, day

SELECT is((ppm.bounds_for('day', '2026-03-17 11:45+00')).lower_bound,
          '2026-03-17 00:00+00'::timestamptz, 'a day starts at midnight');
SELECT is((ppm.bounds_for('day', '2026-03-17 11:45+00')).upper_bound,
          '2026-03-18 00:00+00'::timestamptz, 'and ends 24 hours later');
SELECT is((ppm.bounds_for('day', '2026-03-17 11:45+00', 3)).lower_bound,
          '2026-03-20 00:00+00'::timestamptz, 'three days ahead is three days ahead');

-- bounds_for, week. date_trunc cuts weeks on Monday, which is the ISO week
-- and the only definition the server offers.

SELECT is((ppm.bounds_for('week', '2026-03-17 11:45+00')).lower_bound,
          '2026-03-16 00:00+00'::timestamptz, 'a week starts on Monday');
SELECT is((ppm.bounds_for('week', '2026-03-17 11:45+00')).upper_bound,
          '2026-03-23 00:00+00'::timestamptz, 'and runs seven days');

-- bounds_for, month. The step is one month rather than 30 days, so the
-- boundaries land on the first of the month in February as well as July.

SELECT is((ppm.bounds_for('month', '2026-02-11 09:00+00')).upper_bound,
          '2026-03-01 00:00+00'::timestamptz, 'February ends on 1 March');
SELECT is((ppm.bounds_for('month', '2026-12-11 09:00+00', 1)).lower_bound,
          '2027-01-01 00:00+00'::timestamptz, 'one month past December is January');
SELECT is((ppm.bounds_for('month', '2026-01-31 23:59+00', 1)).lower_bound,
          '2026-02-01 00:00+00'::timestamptz,
          'the last day of January plus one month is still 1 February');

SELECT throws_ok(
    $$SELECT ppm.bounds_for('fortnight', now())$$,
    '22023',
    'unsupported granularity fortnight',
    'bounds_for refuses a granularity it cannot tile with');

-- The session time zone must not move a boundary. Partition bounds are stored
-- in the catalogue as instants, so if they are cut in whatever zone the client
-- happens to be in, two clients disagree about which partition a row belongs
-- to and a backfill run from a laptop writes different boundaries than the
-- cron job did.

SET LOCAL TimeZone = 'Asia/Karachi';
SELECT is((ppm.bounds_for('day', '2026-03-17 20:00+00', 0, 'UTC')).lower_bound,
          '2026-03-17 00:00+00'::timestamptz,
          'a UTC day boundary holds in a +05 session');
SELECT is((ppm.bounds_for('month', '2026-03-31 20:00+00', 0, 'UTC')).upper_bound,
          '2026-04-01 00:00+00'::timestamptz,
          'a UTC month boundary holds in a +05 session');

-- Asked for boundaries in a named zone, it cuts them there: local midnight in
-- that zone, which is what a daily report in that zone means by a day.
SELECT is((ppm.bounds_for('day', '2026-03-17 20:00+00', 0, 'Asia/Karachi')).lower_bound,
          '2026-03-17 19:00+00'::timestamptz,
          'a Karachi day starts at 19:00 UTC the day before');

SET LOCAL TimeZone = 'UTC';

SELECT throws_ok(
    $$SELECT ppm.bounds_for('day', now(), 0, 'Mars/Olympus')$$,
    '22023',
    NULL,
    'bounds_for refuses a time zone the server does not know');

-- partition_name

SELECT lives_ok(
    $$SELECT fixture.new_parent('events')$$,
    'the fixture parent is created');

SELECT is(ppm.partition_name('events'::regclass, 'day', '2026-03-17 00:00+00'),
          'events_20260317'::name, 'daily partitions are named by date');
SELECT is(ppm.partition_name('events'::regclass, 'week', '2026-03-16 00:00+00'),
          'events_w20260316'::name, 'weekly partitions carry the Monday');
SELECT is(ppm.partition_name('events'::regclass, 'month', '2026-03-01 00:00+00'),
          'events_202603'::name, 'monthly partitions are named by month');

-- 63 bytes is the identifier limit. Past it the server truncates silently,
-- two partitions of the same table end up with the same name, and the second
-- CREATE fails with a duplicate_table that explains nothing.
--
-- The table is created in a statement of its own. partition_name() is STABLE,
-- so it runs on the snapshot the calling query started with: called in the
-- same query as the volatile function that creates the table, it reads a
-- pg_class that does not have the new row in it yet and reports the parent as
-- missing.
SELECT lives_ok(
    $$SELECT fixture.new_parent(repeat('e', 56))$$,
    'a parent with a 56 byte name is created');

SELECT throws_ok(
    $$SELECT ppm.partition_name(
          (repeat('e', 56))::regclass, 'day', '2026-03-17 00:00+00')$$,
    '42622',
    NULL,
    'partition_name refuses to build a name the server would truncate');

SELECT * FROM finish();
ROLLBACK;
