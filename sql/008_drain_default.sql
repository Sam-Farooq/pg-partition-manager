-- 008_drain_default.sql
--
-- Moving rows out of the default partition and into the partition they
-- belong in.
--
-- The order matters and there is only one order that works. A new partition
-- cannot be created while the default holds rows that belong in its range:
-- CREATE TABLE ... PARTITION OF and ATTACH PARTITION both prove the default
-- holds nothing in the new range, and both fail with 23514 if it does. So the
-- rows have to leave the default before the partition exists, which means the
-- partition cannot be a partition yet while they are moving:
--
--   1. create a standalone table shaped like the parent
--   2. move the rows out of the default into it
--   3. add the bounds CHECK and validate it
--   4. attach it
--
-- All four happen in this function, which means in one transaction, which is
-- what makes it safe to interrupt. It is also why max_ranges defaults to 1:
-- the ACCESS EXCLUSIVE lock the attach takes is held until the transaction
-- commits, so a call that handles ten ranges holds it ten times as long.

CREATE OR REPLACE FUNCTION ppm.drain_default(
    parent      regclass,
    max_ranges  integer DEFAULT 1,
    dry_run     boolean DEFAULT false
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
    dflt_name    text;
    cols         text;
    lb           timestamptz;
    b            ppm.bounds;
    child_name   name;
    target       text;
    clash        regclass;
    stmt         text;
    moved        bigint;
    ranges       integer := 0;
BEGIN
    IF max_ranges < 1 THEN
        RAISE EXCEPTION 'max_ranges must be at least 1, not %', max_ranges
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT * INTO cfg FROM ppm.partition_set WHERE parent_table = parent;
    IF NOT FOUND THEN
        RAISE EXCEPTION '% is not registered', parent_name
            USING ERRCODE = 'no_data_found',
                  HINT = 'call ppm.register_set() first';
    END IF;

    dflt := ppm.default_partition(parent);
    IF dflt IS NULL THEN
        RAISE NOTICE '% has no default partition, so there is nothing to drain', parent_name;
        RETURN;
    END IF;

    dflt_name := ppm.qualified_name(dflt);

    SELECT n.nspname INTO nsp
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = parent;

    -- An explicit column list rather than SELECT *, so that a column dropped
    -- from the parent cannot line the values up against the wrong columns.
    SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a
     WHERE a.attrelid = parent AND a.attnum > 0 AND NOT a.attisdropped;

    -- Which periods are in there. This reads the whole default partition, and
    -- there is no index that would help: the question is about every row.
    -- bounds_for() is reused rather than re-deriving the truncation here, so
    -- there is one definition of where a period starts.
    FOR lb IN
        EXECUTE format(
            'SELECT DISTINCT (ppm.bounds_for(%L, %I, 0, %L)).lower_bound AS lb
               FROM %s ORDER BY lb LIMIT %s',
            cfg.granularity, cfg.partition_key, cfg.bound_tz, dflt_name, max_ranges)
    LOOP
        b := ppm.bounds_for(cfg.granularity, lb, 0, cfg.bound_tz);
        child_name := ppm.partition_name(parent, cfg.granularity, b.lower_bound, cfg.bound_tz);
        target := format('%I.%I', nsp, child_name);

        SELECT c.oid::regclass INTO clash
          FROM pg_class c
         WHERE c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = nsp)
           AND c.relname = child_name;

        IF clash IS NOT NULL THEN
            RAISE EXCEPTION '% already exists, so the rows in % cannot be moved into it',
                            ppm.qualified_name(clash), dflt_name
                USING ERRCODE = 'duplicate_table',
                      HINT = 'that table should not exist: the default cannot hold rows for a range that is already a partition';
        END IF;

        -- INCLUDING INDEXES is left out. An index on the parent is created on
        -- the child by the ATTACH itself, and doing it here would build the
        -- same index twice. Building it before the attach, with CREATE INDEX
        -- CONCURRENTLY, is what ppm.index_script() is for.
        stmt := format('CREATE TABLE %s (LIKE %s INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING STORAGE INCLUDING COMMENTS)',
                       target, parent_name);
        IF NOT dry_run THEN
            EXECUTE stmt;
        END IF;
        RETURN NEXT stmt;

        stmt := format(
            'WITH moved AS (DELETE FROM %s WHERE %I >= %L AND %I < %L RETURNING %s)
             INSERT INTO %s (%s) SELECT %s FROM moved',
            dflt_name, cfg.partition_key, b.lower_bound,
            cfg.partition_key, b.upper_bound, cols, target, cols, cols);

        moved := NULL;
        IF NOT dry_run THEN
            EXECUTE stmt;
            GET DIAGNOSTICS moved = ROW_COUNT;
            RAISE NOTICE 'moved % row(s) out of % into %', moved, dflt_name, target;
        END IF;
        RETURN NEXT stmt;

        PERFORM ppm.log(
            p_parent_name := parent_name, p_action := 'drain', p_target_name := target,
            p_dry_run := dry_run, p_statement := stmt, p_rows_moved := moved,
            p_message := format('[%s, %s)', b.lower_bound, b.upper_bound));

        IF dry_run THEN
            -- A dry run cannot ask the next two functions what they would do:
            -- the table they work on does not exist yet. Naming the calls is
            -- honest; printing DDL built a second time here would be two
            -- copies of the same statement waiting to disagree.
            RETURN NEXT format(
                '-- then: SELECT ppm.prepare_for_attach(%L, %L, %L, %L);',
                target, cfg.partition_key, b.lower_bound, b.upper_bound);
            RETURN NEXT format(
                '-- then: SELECT ppm.attach_prepared(%L, %L, %L, %L);',
                parent_name, target, b.lower_bound, b.upper_bound);
        ELSE
            RETURN QUERY SELECT * FROM ppm.prepare_for_attach(
                target::regclass, cfg.partition_key, b.lower_bound, b.upper_bound);

            BEGIN
                RETURN NEXT ppm.attach_prepared(
                    parent, target::regclass, b.lower_bound, b.upper_bound);
            EXCEPTION
                -- Rows for this range arrived in the default while the move
                -- was running. The transaction will roll back; running it
                -- again picks them up.
                WHEN object_not_in_prerequisite_state THEN
                    RAISE EXCEPTION 'rows for [%, %) arrived in % while this call was working',
                                    b.lower_bound, b.upper_bound, dflt_name
                        USING ERRCODE = 'serialization_failure',
                              HINT = 'run ppm.drain_default() again';
            END;
        END IF;

        ranges := ranges + 1;
    END LOOP;

    IF ranges = 0 THEN
        RAISE NOTICE '% is empty', dflt_name;
    ELSIF dry_run THEN
        RAISE NOTICE '% range(s) would be moved out of %', ranges, dflt_name;
    ELSE
        RAISE NOTICE '% range(s) moved out of %', ranges, dflt_name;
    END IF;
END $$;

COMMENT ON FUNCTION ppm.drain_default(regclass, integer, boolean) IS
    'Move one period of rows at a time out of the default partition into a '
    'partition of its own, in a single transaction. max_ranges is how many '
    'periods per call; the attach lock is held until the call commits.';
