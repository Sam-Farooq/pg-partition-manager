-- 005_create_ahead.sql
--
-- Create the partitions a set will need before it needs them.
--
-- Running out of partitions on a table with no default partition means every
-- INSERT fails with "no partition of relation found for row", so the point of
-- this function is to be dull and to be run often. It is safe to run every
-- minute: a partition that is already there is skipped without a DDL
-- statement.

CREATE OR REPLACE FUNCTION ppm.create_ahead(
    parent   regclass,
    as_of    timestamptz DEFAULT now(),
    dry_run  boolean     DEFAULT false
)
RETURNS SETOF text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    cfg          ppm.partition_set;
    parent_name  text := ppm.qualified_name(parent);
    nsp          name;
    dflt         regclass;
    dflt_rows    bigint;
    b            ppm.bounds;
    child_name   name;
    clash        regclass;
    stmt         text;
    created      integer := 0;
    i            integer;
BEGIN
    SELECT * INTO cfg FROM ppm.partition_set WHERE parent_table = parent;
    IF NOT FOUND THEN
        RAISE EXCEPTION '% is not registered', parent_name
            USING ERRCODE = 'no_data_found',
                  HINT = 'call ppm.register_set() first';
    END IF;

    SELECT n.nspname INTO nsp
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = parent;

    -- A default partition changes the cost of every statement below. Attaching
    -- a partition has to prove that the default holds no row belonging to the
    -- new range, and the only way to prove that is to read the default, under
    -- ACCESS EXCLUSIVE, which blocks reads of it as well as writes.
    dflt := ppm.default_partition(parent);
    IF dflt IS NOT NULL THEN
        SELECT approx_rows INTO dflt_rows FROM ppm.partitions(parent)
         WHERE child = dflt;
        RAISE NOTICE 'set % has a default partition (%): every CREATE below '
                     'scans it under ACCESS EXCLUSIVE, estimated % rows',
                     parent_name, ppm.qualified_name(dflt),
                     coalesce(dflt_rows::text, 'unknown, never analysed');
    END IF;

    -- premake is how many periods ahead to keep, and the period containing
    -- as_of is always included, so a daily set with premake 7 ends up holding
    -- today plus seven days: eight partitions.
    FOR i IN 0..cfg.premake LOOP
        b := ppm.bounds_for(cfg.granularity, as_of, i, cfg.bound_tz);
        child_name := ppm.partition_name(parent, cfg.granularity, b.lower_bound, cfg.bound_tz);

        IF EXISTS (
            SELECT 1 FROM ppm.partitions(parent) p
             WHERE p.lower_bound = b.lower_bound
               AND p.upper_bound = b.upper_bound
        ) THEN
            CONTINUE;
        END IF;

        -- An overlapping partition is a configuration change that was not
        -- finished: the granularity was switched, or somebody made a partition
        -- by hand. The server would refuse the CREATE anyway; refusing here
        -- names the partition that is in the way.
        SELECT p.child INTO clash
          FROM ppm.partitions(parent) p
         WHERE NOT p.is_default
           AND p.lower_bound < b.upper_bound
           AND p.upper_bound > b.lower_bound
         LIMIT 1;

        IF clash IS NOT NULL THEN
            RAISE EXCEPTION 'range [%, %) for % overlaps existing partition %',
                            b.lower_bound, b.upper_bound, parent_name,
                            ppm.qualified_name(clash)
                USING ERRCODE = 'invalid_object_definition',
                      HINT = 'detach the overlapping partition or change the granularity';
        END IF;

        -- The name is free of the parent, but something else may hold it.
        SELECT c.oid::regclass INTO clash
          FROM pg_class c
         WHERE c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = nsp)
           AND c.relname = child_name;

        IF clash IS NOT NULL THEN
            RAISE EXCEPTION '% already exists and is not a partition of %',
                            ppm.qualified_name(clash), parent_name
                USING ERRCODE = 'duplicate_table';
        END IF;

        stmt := format('CREATE TABLE %I.%I PARTITION OF %s FOR VALUES FROM (%L) TO (%L)',
                       nsp, child_name, parent_name, b.lower_bound, b.upper_bound);

        IF NOT dry_run THEN
            BEGIN
                EXECUTE stmt;
            EXCEPTION
                -- Two schedulers running this function at the same time is a
                -- normal thing to do. One of them loses the race, and losing
                -- it is not an error: the partition exists either way.
                WHEN duplicate_table THEN
                    RAISE NOTICE 'partition %.% appeared while this run was working',
                                 nsp, child_name;
                    CONTINUE;
                -- 23514 from a CREATE TABLE ... PARTITION OF means the default
                -- partition holds rows that belong in the new range. The
                -- server's message does not say what to do about it.
                WHEN check_violation THEN
                    RAISE EXCEPTION
                        'cannot create %.%: the default partition % holds rows in [%, %)',
                                    nsp, child_name, ppm.qualified_name(dflt),
                                    b.lower_bound, b.upper_bound
                        USING ERRCODE = 'object_not_in_prerequisite_state',
                              HINT = 'move them first with ppm.drain_default()';
            END;
        END IF;

        PERFORM ppm.log(
            p_parent_name := parent_name,
            p_action      := 'create',
            p_target_name := nsp || '.' || child_name,
            p_dry_run     := dry_run,
            p_statement   := stmt,
            p_message     := format('[%s, %s)', b.lower_bound, b.upper_bound));

        created := created + 1;
        RETURN NEXT stmt;
    END LOOP;

    IF dry_run THEN
        RAISE NOTICE '% would create % partition(s)', parent_name, created;
    ELSE
        RAISE NOTICE '% created % partition(s)', parent_name, created;
    END IF;
END $$;

COMMENT ON FUNCTION ppm.create_ahead(regclass, timestamptz, boolean) IS
    'Create the partition containing as_of and the next premake periods. '
    'Returns the DDL it ran, or with dry_run the DDL it would have run. Safe '
    'to call repeatedly: an existing partition costs one catalogue read.';
