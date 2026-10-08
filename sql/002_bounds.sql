-- 002_bounds.sql
--
-- Where a partition starts and stops, and what it is called. Everything else
-- in this repository is built on these three functions, so they are the ones
-- with the most tests.

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
CREATE OR REPLACE FUNCTION ppm.bounds_for(
    granularity    text,
    anchor         timestamptz,
    periods_ahead  integer DEFAULT 0
)
RETURNS ppm.bounds
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    step    interval := ppm.granularity_step(granularity);
    result  ppm.bounds;
BEGIN
    IF step IS NULL THEN
        RAISE EXCEPTION 'unsupported granularity %', granularity
            USING ERRCODE = 'invalid_parameter_value',
                  HINT = 'granularity is one of day, week, month';
    END IF;

    result.lower_bound := date_trunc(granularity, anchor) + (step * periods_ahead);
    result.upper_bound := result.lower_bound + step;
    RETURN result;
END $$;

COMMENT ON FUNCTION ppm.bounds_for(text, timestamptz, integer) IS
    'Bounds of the period containing anchor, or periods_ahead periods later.';

CREATE OR REPLACE FUNCTION ppm.partition_name(
    parent       regclass,
    granularity  text,
    lower_bound  timestamptz
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
BEGIN
    SELECT relname INTO base FROM pg_class WHERE oid = parent;

    suffix := CASE granularity
                  WHEN 'day'   THEN to_char(lower_bound, 'YYYYMMDD')
                  WHEN 'week'  THEN to_char(lower_bound, '"w"YYYYMMDD')
                  WHEN 'month' THEN to_char(lower_bound, 'YYYYMM')
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

COMMENT ON FUNCTION ppm.partition_name(regclass, text, timestamptz) IS
    'Partition name for a lower bound: parent_20260108, parent_w20260105, '
    'parent_202601. Weekly names carry the Monday the week starts on.';
