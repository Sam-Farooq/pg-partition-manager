-- 003_inspect.sql
--
-- Reading the partition layout back out of the catalogue.
--
-- PostgreSQL has no function that hands you a partition's bounds as values.
-- The bound lives in pg_class.relpartbound as a pg_node_tree, and the only
-- supported way to see it is pg_get_expr(), which renders the text that was
-- written in the DDL. So these functions parse that text. It is the same
-- source psql's \d+ uses.

CREATE OR REPLACE FUNCTION ppm.qualified_name(rel regclass)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT quote_ident(n.nspname) || '.' || quote_ident(c.relname)
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = rel;
$$;

COMMENT ON FUNCTION ppm.qualified_name(regclass) IS
    'Schema-qualified, quoted name for use in generated DDL. Not regclass::text, '
    'which omits the schema when it happens to be on the search_path.';

-- One bound token: a quoted literal, or MINVALUE or MAXVALUE, which the
-- catalogue renders for an unbounded side.
CREATE OR REPLACE FUNCTION ppm.bound_value(token text)
RETURNS timestamptz
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    inner_text text;
BEGIN
    IF token = 'MINVALUE' THEN
        RETURN '-infinity'::timestamptz;
    ELSIF token = 'MAXVALUE' THEN
        RETURN 'infinity'::timestamptz;
    END IF;

    IF left(token, 1) <> '''' OR right(token, 1) <> '''' THEN
        RAISE EXCEPTION 'partition bound % is not a quoted literal', token
            USING ERRCODE = 'feature_not_supported';
    END IF;

    inner_text := replace(substring(token FROM 2 FOR length(token) - 2), '''''', '''');

    BEGIN
        RETURN inner_text::timestamptz;
    EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
        RAISE EXCEPTION 'partition bound % is not a timestamptz', token
            USING ERRCODE = 'feature_not_supported',
                  HINT = 'this manager handles a single timestamptz partition key';
    END;
END $$;

COMMENT ON FUNCTION ppm.bound_value(text) IS
    'Read one rendered bound token: a quoted literal, or MINVALUE or MAXVALUE, '
    'which the catalogue writes for an unbounded side.';

-- Bounds of one partition. NULL on both sides for a default partition, which
-- is a real answer rather than an error: the default holds whatever is left.
CREATE OR REPLACE FUNCTION ppm.partition_bounds(child regclass)
RETURNS ppm.bounds
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    expr     text;
    strategy "char";
    natts    smallint;
    parts    text[];
    result   ppm.bounds;
BEGIN
    SELECT pg_get_expr(c.relpartbound, c.oid), p.partstrat, p.partnatts
      INTO expr, strategy, natts
      FROM pg_class c
      JOIN pg_inherits i ON i.inhrelid = c.oid
      JOIN pg_partitioned_table p ON p.partrelid = i.inhparent
     WHERE c.oid = child;

    IF expr IS NULL THEN
        RAISE EXCEPTION 'relation % is not a partition', ppm.qualified_name(child)
            USING ERRCODE = 'wrong_object_type';
    END IF;

    IF strategy <> 'r' THEN
        RAISE EXCEPTION 'partition % belongs to a % partitioned table',
                        ppm.qualified_name(child),
                        CASE strategy WHEN 'l' THEN 'list' WHEN 'h' THEN 'hash' END
            USING ERRCODE = 'feature_not_supported',
                  HINT = 'this manager handles RANGE partitioning only';
    END IF;

    IF natts <> 1 THEN
        RAISE EXCEPTION 'partition % has a % column partition key',
                        ppm.qualified_name(child), natts
            USING ERRCODE = 'feature_not_supported',
                  HINT = 'this manager handles a single partition key column';
    END IF;

    IF expr = 'DEFAULT' THEN
        RETURN result;  -- both bounds NULL
    END IF;

    parts := regexp_match(expr, '^FOR VALUES FROM \((.+)\) TO \((.+)\)$');

    IF parts IS NULL THEN
        RAISE EXCEPTION 'cannot read the partition bound of %: %',
                        ppm.qualified_name(child), expr
            USING ERRCODE = 'feature_not_supported';
    END IF;

    result.lower_bound := ppm.bound_value(parts[1]);
    result.upper_bound := ppm.bound_value(parts[2]);
    RETURN result;
END $$;

COMMENT ON FUNCTION ppm.partition_bounds(regclass) IS
    'Bounds of a range partition, read from pg_get_expr(relpartbound). NULL on '
    'both sides for the default partition.';

CREATE OR REPLACE FUNCTION ppm.default_partition(parent regclass)
RETURNS regclass
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT c.oid::regclass
      FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
     WHERE i.inhparent = parent
       AND pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT';
$$;

COMMENT ON FUNCTION ppm.default_partition(regclass) IS
    'The default partition of a partitioned table, or NULL if it has none.';

-- The layout, one row per partition, newest last.
--
-- approx_rows is pg_class.reltuples, which is whatever the last ANALYZE or
-- autovacuum left behind, and NULL when the partition has never been
-- analysed. It is not a count and the retention functions never use it to
-- decide anything.
CREATE OR REPLACE FUNCTION ppm.partitions(parent regclass)
RETURNS TABLE (
    child        regclass,
    lower_bound  timestamptz,
    upper_bound  timestamptz,
    is_default   boolean,
    approx_rows  bigint,
    total_bytes  bigint
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT c.oid::regclass,
           b.lower_bound,
           b.upper_bound,
           pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT',
           CASE WHEN c.reltuples < 0 THEN NULL ELSE c.reltuples::bigint END,
           pg_total_relation_size(c.oid)
      FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
      CROSS JOIN LATERAL ppm.partition_bounds(c.oid::regclass) b
     WHERE i.inhparent = parent
     ORDER BY b.lower_bound NULLS FIRST;
$$;

COMMENT ON FUNCTION ppm.partitions(regclass) IS
    'Partition layout of a table. approx_rows is a planner estimate, NULL '
    'before the first ANALYZE, and never a count.';

-- parent_table is a regclass, so dropping a managed table leaves a row whose
-- OID resolves to nothing. Nothing in the catalogue cascades into a user
-- table, so the registry has to be swept.
CREATE OR REPLACE FUNCTION ppm.prune_registry()
RETURNS integer
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    removed integer;
BEGIN
    WITH gone AS (
        DELETE FROM ppm.partition_set s
         WHERE NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = s.parent_table)
        RETURNING s.parent_table
    )
    SELECT count(*)::integer INTO removed FROM gone;

    IF removed > 0 THEN
        RAISE NOTICE 'pruned % registry row(s) whose table no longer exists', removed;
    END IF;

    RETURN removed;
END $$;

COMMENT ON FUNCTION ppm.prune_registry() IS
    'Delete registry rows whose parent table has been dropped. Returns how '
    'many went.';
