-- 009_index_script.sql
--
-- Adding an index to a partitioned table without locking it out of use.
--
-- CREATE INDEX on a partitioned parent builds the index on every partition in
-- one statement, holding a lock that blocks writes on all of them for the
-- whole build, and there is no CONCURRENTLY form of it. The online route is
-- three steps:
--
--   CREATE INDEX ... ON ONLY parent           -- catalogue only, marked invalid
--   CREATE INDEX CONCURRENTLY ... ON child    -- once per partition
--   ALTER INDEX parent_idx ATTACH PARTITION child_idx
--
-- and the parent index becomes valid when the last partition is attached.
--
-- This function writes that script and runs none of it, because CREATE INDEX
-- CONCURRENTLY raises 25001 inside a transaction block exactly like DETACH
-- CONCURRENTLY, and a function body is a transaction block. Run it with psql
-- and \gexec, which is what test/08_index_script.sql does.

CREATE OR REPLACE FUNCTION ppm.index_script(
    parent      regclass,
    index_name  name,
    columns     text,
    is_unique   boolean DEFAULT false
)
RETURNS SETOF text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    parent_name  text := ppm.qualified_name(parent);
    nsp          name;
    base         name;
    tail         text;
    keyattnum    smallint;
    keyname      name;
    uniq         text := CASE WHEN is_unique THEN 'UNIQUE ' ELSE '' END;
    child        record;
    child_index  text;
    children     integer := 0;
    attaches     text[] := '{}';
BEGIN
    SELECT n.nspname, c.relname INTO nsp, base
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = parent;

    SELECT p.partattrs[0] INTO keyattnum
      FROM pg_partitioned_table p
     WHERE p.partrelid = parent AND p.partstrat = 'r' AND p.partnatts = 1;

    IF keyattnum IS NULL THEN
        RAISE EXCEPTION '% is not partitioned by range on a single column', parent_name
            USING ERRCODE = 'wrong_object_type';
    END IF;

    SELECT a.attname INTO keyname
      FROM pg_attribute a WHERE a.attrelid = parent AND a.attnum = keyattnum;

    -- A unique index on a partitioned table has to contain every partitioning
    -- column, because uniqueness is enforced per partition and nothing checks
    -- across them. The server refuses it; refusing here says why.
    IF is_unique AND position(keyname::text IN columns) = 0 THEN
        RAISE EXCEPTION 'a unique index on % must include the partition key %',
                        parent_name, keyname
            USING ERRCODE = 'feature_not_supported',
                  HINT = 'uniqueness is enforced inside each partition, not across them';
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_class c
         WHERE c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = nsp)
           AND c.relname = index_name
    ) THEN
        RAISE EXCEPTION '%.% already exists', nsp, index_name
            USING ERRCODE = 'duplicate_table';
    END IF;

    -- ev_at_idx on ev gives ev_20260317_at_idx on the partition, rather than
    -- repeating the parent's name inside the child's.
    tail := index_name::text;
    IF left(tail, octet_length(base) + 1) = base || '_' THEN
        tail := substring(tail FROM octet_length(base) + 2);
    END IF;

    RETURN NEXT '-- Run these with autocommit on, one statement at a time.';
    RETURN NEXT '-- CREATE INDEX CONCURRENTLY raises 25001 inside a transaction block.';
    RETURN NEXT '-- A CONCURRENTLY build that fails leaves an invalid index behind:';
    RETURN NEXT '-- drop it and run that statement again.';

    RETURN NEXT format('CREATE %sINDEX %I ON ONLY %s (%s);',
                       uniq, index_name, parent_name, columns);

    FOR child IN
        SELECT c.oid::regclass AS rel, c.relname
          FROM pg_inherits i
          JOIN pg_class c ON c.oid = i.inhrelid
         WHERE i.inhparent = parent
         ORDER BY c.relname
    LOOP
        child_index := child.relname || '_' || tail;

        IF octet_length(child_index) > 63 THEN
            RAISE EXCEPTION 'index name % is % bytes, over the 63 byte identifier limit',
                            child_index, octet_length(child_index)
                USING ERRCODE = 'name_too_long';
        END IF;

        RETURN NEXT format('CREATE %sINDEX CONCURRENTLY %I ON %s (%s);',
                           uniq, child_index, ppm.qualified_name(child.rel), columns);

        attaches := attaches || format('ALTER INDEX %I.%I ATTACH PARTITION %I.%I;',
                                       nsp, index_name, nsp, child_index);
        children := children + 1;
    END LOOP;

    -- Every build first, then every attach. The parent index is invalid until
    -- the last attach, and an attach of a half-built index is not possible,
    -- so the order is not a preference.
    RETURN QUERY SELECT unnest(attaches);

    RETURN NEXT format(
        '-- then: SELECT indisvalid FROM pg_index WHERE indexrelid = %L::regclass;',
        format('%I.%I', nsp, index_name));

    PERFORM ppm.log(
        p_parent_name := parent_name, p_action := 'index_script',
        p_target_name := nsp || '.' || index_name, p_dry_run := true,
        p_message := format('%s partition(s), columns (%s)', children, columns));

    RAISE NOTICE 'wrote a script for % over % partition(s); nothing has run',
                 index_name, children;
END $$;

COMMENT ON FUNCTION ppm.index_script(regclass, name, text, boolean) IS
    'Write the CREATE INDEX ON ONLY / CREATE INDEX CONCURRENTLY / ALTER INDEX '
    'ATTACH PARTITION sequence for a partitioned table. Returns text and runs '
    'nothing: the concurrent build cannot happen inside a function.';
