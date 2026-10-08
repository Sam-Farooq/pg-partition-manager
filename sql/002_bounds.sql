-- 002_bounds.sql
--
-- Where a partition starts and stops, and what it is called. Everything else
-- in this repository is built on these functions, so they are the ones with
-- the most tests.

DO $$
BEGIN
    CREATE TYPE ppm.bounds AS (
        lower_bound timestamptz,
        upper_bound timestamptz
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

COMMENT ON TYPE ppm.bounds IS
    'Half-open range [lower_bound, upper_bound), which is what FOR VALUES '
    'FROM ... TO ... means. Both NULL for a default partition.';

-- Both functions below gained a bound_tz argument after release. CREATE OR
-- REPLACE cannot change a signature: a new argument with a default produces a
-- second overload, and then a two-argument call matches both and the server
-- refuses it as ambiguous. An upgrade has to drop the old one by its exact
-- argument list, so these two lines stay here permanently.
DROP FUNCTION IF EXISTS ppm.bounds_for(text, timestamptz, integer);
DROP FUNCTION IF EXISTS ppm.partition_name(regclass, text, timestamptz);

CREATE OR REPLACE FUNCTION ppm.granularity_step(granularity text)
RETURNS interval
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT CASE granularity
               WHEN 'day'   THEN interval '1 day'
               WHEN 'week'  THEN interval '7 days'
               WHEN 'month' THEN interval '1 month'
           END;
$$;

COMMENT ON FUNCTION ppm.granularity_step(text) IS
    'The width of one partition. NULL for anything but day, week or month.';

-- Three granularities and no others. A partition scheme has to tile the key
-- space with no gap and no overlap, and an arbitrary interval does not: two
-- months does not divide a year, and 36 hours does not divide anything. Each
-- of these three has a date_trunc unit that produces the same boundaries no
-- matter which instant inside the period is used as the anchor.
--
-- The truncation happens on a timestamp without time zone, taken from the
-- anchor in bound_tz, and the result is converted back. date_trunc() on a
-- timestamptz truncates in the session's TimeZone instead, which means two
-- clients in different zones compute different boundaries for the same
-- instant, and a backfill from a laptop writes partitions that do not line up
-- with the ones the scheduled run wrote. bound_tz is stored per partition set
-- so the answer is a property of the table and not of the connection.
CREATE OR REPLACE FUNCTION ppm.bounds_for(
    granularity    text,
    anchor         timestamptz,
    periods_ahead  integer DEFAULT 0,
    bound_tz       text    DEFAULT 'UTC'
)
RETURNS ppm.bounds
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    step        interval := ppm.granularity_step(granularity);
    start_local timestamp;
    result      ppm.bounds;
BEGIN
    IF step IS NULL THEN
        RAISE EXCEPTION 'unsupported granularity %', granularity
            USING ERRCODE = 'invalid_parameter_value',
                  HINT = 'granularity is one of day, week, month';
    END IF;

    -- An unknown zone raises 22023 from AT TIME ZONE itself, with a better
    -- message than anything this function could write.
    start_local := date_trunc(granularity, anchor AT TIME ZONE bound_tz)
                   + (step * periods_ahead);

    result.lower_bound := start_local AT TIME ZONE bound_tz;
    result.upper_bound := (start_local + step) AT TIME ZONE bound_tz;
    RETURN result;
END $$;

COMMENT ON FUNCTION ppm.bounds_for(text, timestamptz, integer, text) IS
    'Bounds of the period containing anchor, or periods_ahead periods later, '
    'cut at local midnight in bound_tz. In a zone that observes daylight '
    'saving a daily partition is 23 or 25 hours wide, which is what a day in '
    'that zone means.';

CREATE OR REPLACE FUNCTION ppm.partition_name(
    parent       regclass,
    granularity  text,
    lower_bound  timestamptz,
    bound_tz     text DEFAULT 'UTC'
)
RETURNS name
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    base    text;
    suffix  text;
    cand    text;
    local   timestamp := lower_bound AT TIME ZONE bound_tz;
BEGIN
    SELECT relname INTO base FROM pg_class WHERE oid = parent;

    IF base IS NULL THEN
        RAISE EXCEPTION 'relation % does not exist', parent
            USING ERRCODE = 'undefined_table';
    END IF;

    suffix := CASE granularity
                  WHEN 'day'   THEN to_char(local, 'YYYYMMDD')
                  WHEN 'week'  THEN to_char(local, '"w"YYYYMMDD')
                  WHEN 'month' THEN to_char(local, 'YYYYMM')
              END;

    IF suffix IS NULL THEN
        RAISE EXCEPTION 'unsupported granularity %', granularity
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    cand := base || '_' || suffix;

    -- An identifier longer than 63 bytes is truncated silently by the server,
    -- and two partitions of a long-named table would then collide on the same
    -- name: the second CREATE fails with a duplicate_table that says nothing
    -- about why. Refusing here names the real problem.
    IF octet_length(cand) > 63 THEN
        RAISE EXCEPTION 'partition name % is % bytes, over the 63 byte identifier limit',
                        cand, octet_length(cand)
            USING ERRCODE = 'name_too_long',
                  HINT = 'rename the parent table to something shorter';
    END IF;

    RETURN cand;
END $$;

COMMENT ON FUNCTION ppm.partition_name(regclass, text, timestamptz, text) IS
    'Partition name for a lower bound: parent_20260108, parent_w20260105, '
    'parent_202601. Weekly names carry the Monday the week starts on. The '
    'date in the name is read in bound_tz, so it matches the boundary.';
