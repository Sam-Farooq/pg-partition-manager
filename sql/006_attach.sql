-- 006_attach.sql
--
-- Attaching a table that already holds rows, without holding ACCESS EXCLUSIVE
-- on the parent for the length of a table scan.
--
-- ALTER TABLE ... ATTACH PARTITION has to prove that every row in the new
-- partition belongs inside its bounds. If it cannot prove it from the
-- catalogue it reads the whole table to check, and it does that while holding
-- ACCESS EXCLUSIVE on the parent, which blocks every reader of every
-- partition. If a validated CHECK constraint already implies the partition
-- bounds, the proof is a catalogue lookup and the scan does not happen.
--
-- The scan does not disappear: it moves to VALIDATE CONSTRAINT, which takes
-- SHARE UPDATE EXCLUSIVE on the child alone and lets reads and writes
-- through. The win is the lock, not the work. test/05_attach.sql measures
-- both halves with pg_stat_all_tables.

CREATE OR REPLACE FUNCTION ppm.bounds_constraint_name(child regclass)
RETURNS name
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    base text;
    cand text;
BEGIN
    SELECT relname INTO base FROM pg_class WHERE oid = child;

    IF base IS NULL THEN
        RAISE EXCEPTION 'relation % does not exist', child
            USING ERRCODE = 'undefined_table';
    END IF;

    cand := base || '_ppm_bounds';

    IF octet_length(cand) > 63 THEN
        RAISE EXCEPTION 'constraint name % is % bytes, over the 63 byte identifier limit',
                        cand, octet_length(cand)
            USING ERRCODE = 'name_too_long';
    END IF;

    RETURN cand;
END $$;

COMMENT ON FUNCTION ppm.bounds_constraint_name(regclass) IS
    'Name of the CHECK constraint this manager writes on a table it is about '
    'to attach.';

CREATE OR REPLACE FUNCTION ppm.prepare_for_attach(
    child          regclass,
    partition_key  name,
    lower_bound    timestamptz,
    upper_bound    timestamptz,
    dry_run        boolean DEFAULT false
)
RETURNS SETOF text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    child_name  text := ppm.qualified_name(child);
    cname       name := ppm.bounds_constraint_name(child);
    keytype     text;
    existing    text;
    validated   boolean;
    expected    text;
    add_stmt    text;
    val_stmt    text;
BEGIN
    IF lower_bound >= upper_bound THEN
        RAISE EXCEPTION 'empty range [%, %)', lower_bound, upper_bound
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid = child) THEN
        RAISE EXCEPTION '% is already a partition', child_name
            USING ERRCODE = 'wrong_object_type';
    END IF;

    SELECT format_type(a.atttypid, a.atttypmod) INTO keytype
      FROM pg_attribute a
     WHERE a.attrelid = child AND a.attname = partition_key AND a.attnum > 0
       AND NOT a.attisdropped;

    IF keytype IS NULL THEN
        RAISE EXCEPTION '% has no column %', child_name, partition_key
            USING ERRCODE = 'undefined_column';
    END IF;

    IF keytype <> 'timestamp with time zone' THEN
        RAISE EXCEPTION 'column %.% is %, not timestamptz', child_name, partition_key, keytype
            USING ERRCODE = 'feature_not_supported';
    END IF;

    -- IS NOT NULL is part of the constraint because a NULL key does not
    -- satisfy a range partition's bound either. Without it the attach fails
    -- its own scan, after VALIDATE has already passed, under the heavier lock.
    expected := format('%I IS NOT NULL AND %I >= %L AND %I < %L',
                       partition_key, partition_key, lower_bound,
                       partition_key, upper_bound);

    SELECT pg_get_constraintdef(c.oid), c.convalidated
      INTO existing, validated
      FROM pg_constraint c
     WHERE c.conrelid = child AND c.conname = cname;

    IF existing IS NOT NULL THEN
        IF validated
           AND position(quote_literal(lower_bound) IN existing) > 0
           AND position(quote_literal(upper_bound) IN existing) > 0 THEN
            RAISE NOTICE '% already carries a validated %', child_name, cname;
            RETURN;
        END IF;

        IF NOT validated THEN
            -- Left over from a VALIDATE that was interrupted. Validating it
            -- again is cheap to ask for and correct either way.
            val_stmt := format('ALTER TABLE %s VALIDATE CONSTRAINT %I', child_name, cname);
            IF NOT dry_run THEN
                EXECUTE val_stmt;
            END IF;
            PERFORM ppm.log(
                p_parent_name := child_name, p_action := 'prepare',
                p_target_name := cname, p_dry_run := dry_run, p_statement := val_stmt,
                p_message := 'validated a constraint that was left NOT VALID');
            RETURN NEXT val_stmt;
            RETURN;
        END IF;

        RAISE EXCEPTION '% already carries % for a different range: %',
                        child_name, cname, existing
            USING ERRCODE = 'duplicate_object',
                  HINT = 'drop the constraint, or attach the table to the range it describes';
    END IF;

    add_stmt := format('ALTER TABLE %s ADD CONSTRAINT %I CHECK (%s) NOT VALID',
                       child_name, cname, expected);
    val_stmt := format('ALTER TABLE %s VALIDATE CONSTRAINT %I', child_name, cname);

    -- NOT VALID first, then VALIDATE. One statement that adds a validated
    -- constraint would do the same scan while holding ACCESS EXCLUSIVE.
    IF NOT dry_run THEN
        EXECUTE add_stmt;
        EXECUTE val_stmt;
        RAISE NOTICE '% is ready to attach as [%, %)', child_name, lower_bound, upper_bound;
    END IF;

    PERFORM ppm.log(
        p_parent_name := child_name, p_action := 'prepare', p_target_name := cname,
        p_dry_run := dry_run, p_statement := add_stmt,
        p_message := format('[%s, %s)', lower_bound, upper_bound));

    RETURN NEXT add_stmt;
    RETURN NEXT val_stmt;
END $$;

COMMENT ON FUNCTION ppm.prepare_for_attach(regclass, name, timestamptz, timestamptz, boolean) IS
    'Add the CHECK constraint that lets ATTACH PARTITION skip its validation '
    'scan, as NOT VALID then VALIDATE so the scan runs under SHARE UPDATE '
    'EXCLUSIVE instead of ACCESS EXCLUSIVE.';

CREATE OR REPLACE FUNCTION ppm.attach_prepared(
    parent       regclass,
    child        regclass,
    lower_bound  timestamptz,
    upper_bound  timestamptz,
    dry_run      boolean DEFAULT false
)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    parent_name text := ppm.qualified_name(parent);
    child_name  text := ppm.qualified_name(child);
    cname       name := ppm.bounds_constraint_name(child);
    keyattnum   smallint;
    keyname     name;
    existing    text;
    validated   boolean;
    dflt        regclass;
    stmt        text;
BEGIN
    SELECT p.partattrs[0] INTO keyattnum
      FROM pg_partitioned_table p
     WHERE p.partrelid = parent AND p.partstrat = 'r' AND p.partnatts = 1;

    IF keyattnum IS NULL THEN
        RAISE EXCEPTION '% is not partitioned by range on a single column', parent_name
            USING ERRCODE = 'wrong_object_type';
    END IF;

    SELECT a.attname INTO keyname
      FROM pg_attribute a WHERE a.attrelid = parent AND a.attnum = keyattnum;

    SELECT pg_get_constraintdef(c.oid), c.convalidated
      INTO existing, validated
      FROM pg_constraint c
     WHERE c.conrelid = child AND c.conname = cname;

    -- This looks for the constraint this manager writes, by name, and checks
    -- that it mentions both bounds. It does not work out whether some other
    -- constraint implies the bounds: that is predicate implication, the
    -- planner's job, and guessing at it here would produce a function that
    -- sometimes says a scan will be skipped when it will not.
    IF existing IS NULL THEN
        RAISE EXCEPTION '% has no % constraint, so ATTACH would scan it', child_name, cname
            USING ERRCODE = 'object_not_in_prerequisite_state',
                  HINT = 'run ppm.prepare_for_attach() first';
    END IF;

    IF NOT validated THEN
        RAISE EXCEPTION '% on % is NOT VALID, so ATTACH would scan the table anyway',
                        cname, child_name
            USING ERRCODE = 'object_not_in_prerequisite_state',
                  HINT = 'ALTER TABLE ... VALIDATE CONSTRAINT, or call '
                         'ppm.prepare_for_attach() again';
    END IF;

    IF position(quote_literal(lower_bound) IN existing) = 0
       OR position(quote_literal(upper_bound) IN existing) = 0 THEN
        RAISE EXCEPTION '% on % does not describe [%, %): %',
                        cname, child_name, lower_bound, upper_bound, existing
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    IF keyname IS DISTINCT FROM NULL
       AND position(quote_ident(keyname) IN existing) = 0
       AND position(keyname::text IN existing) = 0 THEN
        RAISE EXCEPTION '% on % does not constrain the partition key %',
                        cname, child_name, keyname
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    -- Measured: with the constraint in place the child is not scanned, and the
    -- default partition is scanned once regardless, because the server has to
    -- prove the default holds no row belonging in the new range. A CHECK on
    -- the default that excludes this range is the only way out of that one.
    dflt := ppm.default_partition(parent);
    IF dflt IS NOT NULL THEN
        RAISE NOTICE 'attaching to % will scan the default partition % under ACCESS EXCLUSIVE',
                     parent_name, ppm.qualified_name(dflt);
    END IF;

    stmt := format('ALTER TABLE %s ATTACH PARTITION %s FOR VALUES FROM (%L) TO (%L)',
                   parent_name, child_name, lower_bound, upper_bound);

    IF NOT dry_run THEN
        BEGIN
            EXECUTE stmt;
        EXCEPTION
            WHEN check_violation THEN
                RAISE EXCEPTION
                    'cannot attach % to %: the default partition % holds rows in [%, %)',
                                child_name, parent_name, ppm.qualified_name(dflt),
                                lower_bound, upper_bound
                    USING ERRCODE = 'object_not_in_prerequisite_state',
                          HINT = 'move them first with ppm.drain_default()';
        END;
        RAISE NOTICE 'attached % as [%, %)', child_name, lower_bound, upper_bound;
    END IF;

    PERFORM ppm.log(
        p_parent_name := parent_name, p_action := 'attach', p_target_name := child_name,
        p_dry_run := dry_run, p_statement := stmt,
        p_message := format('[%s, %s)', lower_bound, upper_bound));

    RETURN stmt;
END $$;

COMMENT ON FUNCTION ppm.attach_prepared(regclass, regclass, timestamptz, timestamptz, boolean) IS
    'Attach a table prepared by ppm.prepare_for_attach(). Refuses to attach '
    'without the validated CHECK, because that attach is a table scan under '
    'ACCESS EXCLUSIVE on the parent.';
