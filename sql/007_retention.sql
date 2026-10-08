-- 007_retention.sql
--
-- Taking partitions off the end.
--
-- A plain DETACH takes ACCESS EXCLUSIVE on the parent, which blocks every
-- reader of every partition for as long as it waits for its lock. The online
-- form, DETACH PARTITION ... CONCURRENTLY, cannot be used here at all:
--
--     ERROR:  25001: ALTER TABLE ... DETACH CONCURRENTLY cannot run inside a
--             transaction block
--
-- and a function body is always inside one. There is no flag or setting that
-- changes that. So apply_retention() does the plain detach and says what it
-- costs, and retention_script() writes out the concurrent version for a
-- caller that can run statements outside a transaction. 08_retention.sql
-- asserts the 25001 rather than taking it on trust.

CREATE OR REPLACE FUNCTION ppm.retention_victims(
    parent  regclass,
    as_of   timestamptz DEFAULT now()
)
RETURNS TABLE (
    child        regclass,
    lower_bound  timestamptz,
    upper_bound  timestamptz
)
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    cfg ppm.partition_set;
BEGIN
    SELECT * INTO cfg FROM ppm.partition_set WHERE parent_table = parent;
    IF NOT FOUND THEN
        RAISE EXCEPTION '% is not registered', ppm.qualified_name(parent)
            USING ERRCODE = 'no_data_found';
    END IF;

    IF cfg.retention IS NULL THEN
        RETURN;
    END IF;

    -- Whole partitions only. A partition that straddles the cutoff holds rows
    -- that are inside the window, so it stays, and the oldest data is kept up
    -- to one partition longer than the window says. Trimming rows instead
    -- would make retention a DELETE, which is the thing partitioning is for
    -- avoiding.
    RETURN QUERY
    SELECT p.child, p.lower_bound, p.upper_bound
      FROM ppm.partitions(parent) p
     WHERE NOT p.is_default
       AND p.upper_bound <= as_of - cfg.retention
     ORDER BY p.lower_bound;
END $$;

COMMENT ON FUNCTION ppm.retention_victims(regclass, timestamptz) IS
    'Partitions entirely older than the retention window. A partition holding '
    'the cutoff itself is kept.';

CREATE OR REPLACE FUNCTION ppm.apply_retention(
    parent       regclass,
    as_of        timestamptz DEFAULT now(),
    dry_run      boolean     DEFAULT false,
    allow_empty  boolean     DEFAULT false
)
RETURNS SETOF text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    cfg          ppm.partition_set;
    parent_name  text := ppm.qualified_name(parent);
    victim       record;
    victim_count integer;
    keeper_count integer;
    child_name   text;
    stmt         text;
    acted        integer := 0;
BEGIN
    SELECT * INTO cfg FROM ppm.partition_set WHERE parent_table = parent;
    IF NOT FOUND THEN
        RAISE EXCEPTION '% is not registered', parent_name
            USING ERRCODE = 'no_data_found',
                  HINT = 'call ppm.register_set() first';
    END IF;

    IF cfg.retention IS NULL THEN
        RAISE NOTICE '% has no retention window, nothing to do', parent_name;
        RETURN;
    END IF;

    SELECT count(*)::integer INTO victim_count
      FROM ppm.retention_victims(parent, as_of);

    IF victim_count = 0 THEN
        RAISE NOTICE '% has nothing older than %', parent_name, as_of - cfg.retention;
        RETURN;
    END IF;

    SELECT count(*)::integer INTO keeper_count
      FROM ppm.partitions(parent) p
     WHERE NOT p.is_default
       AND p.upper_bound > as_of - cfg.retention;

    -- A window that removes everything is what a mistyped interval looks
    -- like: days where months were meant, or a retention set before a
    -- backfill loaded older data. The set is left alone and the caller is
    -- told what it asked for.
    IF keeper_count = 0 AND NOT allow_empty THEN
        RAISE EXCEPTION 'retention % would remove all % partitions of %',
                        cfg.retention, victim_count, parent_name
            USING ERRCODE = 'invalid_parameter_value',
                  HINT = 'pass allow_empty := true if that is really the intention';
    END IF;

    IF NOT dry_run THEN
        RAISE NOTICE 'detaching % partition(s) from %: each DETACH takes ACCESS EXCLUSIVE on the parent',
                     victim_count, parent_name;
    END IF;

    FOR victim IN SELECT * FROM ppm.retention_victims(parent, as_of) LOOP
        child_name := ppm.qualified_name(victim.child);
        stmt := format('ALTER TABLE %s DETACH PARTITION %s', parent_name, child_name);

        IF NOT dry_run THEN
            BEGIN
                EXECUTE stmt;
            EXCEPTION
                -- Someone else got there first. The partition is gone, which
                -- is what was wanted.
                WHEN undefined_table THEN
                    RAISE NOTICE '% disappeared while this run was working', child_name;
                    CONTINUE;
                -- Only reachable with lock_timeout or statement_timeout set.
                -- Worth catching because the default behaviour is to wait,
                -- and a caller that set a timeout wants to know which lock it
                -- failed to get rather than a bare 55P03.
                WHEN lock_not_available THEN
                    RAISE EXCEPTION 'could not get ACCESS EXCLUSIVE on % to detach %',
                                    parent_name, child_name
                        USING ERRCODE = 'lock_not_available',
                              HINT = 'retry, or use the script from ppm.retention_script()';
            END;
        END IF;

        PERFORM ppm.log(
            p_parent_name := parent_name, p_action := 'detach',
            p_target_name := child_name, p_dry_run := dry_run, p_statement := stmt,
            p_message := format('[%s, %s)', victim.lower_bound, victim.upper_bound));
        RETURN NEXT stmt;
        acted := acted + 1;

        IF cfg.retention_action = 'drop' THEN
            stmt := format('DROP TABLE %s', child_name);
            IF NOT dry_run THEN
                EXECUTE stmt;
            END IF;
            PERFORM ppm.log(
                p_parent_name := parent_name, p_action := 'drop',
                p_target_name := child_name, p_dry_run := dry_run, p_statement := stmt);
            RETURN NEXT stmt;

        ELSIF cfg.archive_schema IS NOT NULL THEN
            IF EXISTS (
                SELECT 1 FROM pg_class c
                  JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = cfg.archive_schema
                   AND c.relname = (SELECT relname FROM pg_class WHERE oid = victim.child)
            ) THEN
                RAISE EXCEPTION 'archive schema % already holds a table called %',
                                cfg.archive_schema,
                                (SELECT relname FROM pg_class WHERE oid = victim.child)
                    USING ERRCODE = 'duplicate_table';
            END IF;

            stmt := format('ALTER TABLE %s SET SCHEMA %I', child_name, cfg.archive_schema);
            IF NOT dry_run THEN
                EXECUTE stmt;
            END IF;
            PERFORM ppm.log(
                p_parent_name := parent_name, p_action := 'archive',
                p_target_name := child_name, p_dry_run := dry_run, p_statement := stmt,
                p_message := 'moved to ' || cfg.archive_schema);
            RETURN NEXT stmt;
        END IF;
    END LOOP;

    IF dry_run THEN
        RAISE NOTICE '% would detach % partition(s)', parent_name, acted;
    ELSE
        RAISE NOTICE '% detached % partition(s)', parent_name, acted;
    END IF;
END $$;

COMMENT ON FUNCTION ppm.apply_retention(regclass, timestamptz, boolean, boolean) IS
    'Detach every partition entirely older than the retention window, then '
    'drop or archive it according to the set. Refuses to empty a set unless '
    'allow_empty is passed.';

-- The concurrent version, as text, because no function can run it.
CREATE OR REPLACE FUNCTION ppm.retention_script(
    parent  regclass,
    as_of   timestamptz DEFAULT now()
)
RETURNS SETOF text
LANGUAGE plpgsql
-- Not STABLE, although it changes nothing in the partition set: it writes a
-- row to ppm.run_log, and a non-volatile function cannot INSERT.
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    cfg          ppm.partition_set;
    parent_name  text := ppm.qualified_name(parent);
    victim       record;
    child_name   text;
BEGIN
    SELECT * INTO cfg FROM ppm.partition_set WHERE parent_table = parent;
    IF NOT FOUND THEN
        RAISE EXCEPTION '% is not registered', parent_name
            USING ERRCODE = 'no_data_found';
    END IF;

    RETURN NEXT '-- Run these one statement at a time, with autocommit on.';
    RETURN NEXT '-- DETACH CONCURRENTLY fails with 25001 inside any transaction block,';
    RETURN NEXT '-- which includes every function body and every BEGIN in psql.';
    RETURN NEXT '-- If one is interrupted the partition is left detach-pending and the';
    RETURN NEXT '-- next statement for it has to be the FINALIZE below.';

    FOR victim IN SELECT * FROM ppm.retention_victims(parent, as_of) LOOP
        child_name := ppm.qualified_name(victim.child);
        RETURN NEXT format('ALTER TABLE %s DETACH PARTITION %s CONCURRENTLY;',
                           parent_name, child_name);
        RETURN NEXT format('-- if that was interrupted: ALTER TABLE %s DETACH PARTITION %s FINALIZE;',
                           parent_name, child_name);

        IF cfg.retention_action = 'drop' THEN
            RETURN NEXT format('DROP TABLE %s;', child_name);
        ELSIF cfg.archive_schema IS NOT NULL THEN
            RETURN NEXT format('ALTER TABLE %s SET SCHEMA %I;', child_name, cfg.archive_schema);
        END IF;
    END LOOP;

    PERFORM ppm.log(
        p_parent_name := parent_name, p_action := 'detach', p_dry_run := true,
        p_message := 'wrote a CONCURRENTLY script');
END $$;

COMMENT ON FUNCTION ppm.retention_script(regclass, timestamptz) IS
    'The same work as apply_retention(), written out as a script that uses '
    'DETACH PARTITION ... CONCURRENTLY. Returns text and runs nothing, '
    'because that statement cannot run inside a transaction block.';
