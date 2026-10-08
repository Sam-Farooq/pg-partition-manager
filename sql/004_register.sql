-- 004_register.sql
--
-- Putting a table under management. Everything that can be checked once is
-- checked here, so that create_ahead() and apply_retention() can be short and
-- can assume their inputs.

CREATE OR REPLACE FUNCTION ppm.register_set(
    parent            regclass,
    partition_key     name,
    granularity       text,
    premake           integer  DEFAULT 4,
    retention         interval DEFAULT NULL,
    retention_action  text     DEFAULT 'detach',
    archive_schema    name     DEFAULT NULL,
    bound_tz          text     DEFAULT 'UTC'
)
RETURNS ppm.partition_set
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    relkind   "char";
    strategy  "char";
    natts     smallint;
    keyattnum smallint;
    keyname   name;
    keytype   text;
    step      interval := ppm.granularity_step(granularity);
    saved     ppm.partition_set;
BEGIN
    IF step IS NULL THEN
        RAISE EXCEPTION 'unsupported granularity %', granularity
            USING ERRCODE = 'invalid_parameter_value',
                  HINT = 'granularity is one of day, week, month';
    END IF;

    -- An unknown time zone raises 22023 here rather than on the first run.
    PERFORM now() AT TIME ZONE bound_tz;

    SELECT c.relkind, p.partstrat, p.partnatts, p.partattrs[0]
      INTO relkind, strategy, natts, keyattnum
      FROM pg_class c
      LEFT JOIN pg_partitioned_table p ON p.partrelid = c.oid
     WHERE c.oid = parent;

    IF relkind <> 'p' THEN
        RAISE EXCEPTION '% is not a partitioned table', ppm.qualified_name(parent)
            USING ERRCODE = 'wrong_object_type';
    END IF;

    IF strategy <> 'r' THEN
        RAISE EXCEPTION '% is partitioned by %, not by range',
                        ppm.qualified_name(parent),
                        CASE strategy WHEN 'l' THEN 'list' WHEN 'h' THEN 'hash' END
            USING ERRCODE = 'feature_not_supported';
    END IF;

    IF natts <> 1 THEN
        RAISE EXCEPTION '% has a % column partition key',
                        ppm.qualified_name(parent), natts
            USING ERRCODE = 'feature_not_supported';
    END IF;

    IF keyattnum = 0 THEN
        RAISE EXCEPTION '% is partitioned by an expression', ppm.qualified_name(parent)
            USING ERRCODE = 'feature_not_supported',
                  HINT = 'the partition key must be a plain timestamptz column';
    END IF;

    SELECT a.attname, format_type(a.atttypid, a.atttypmod)
      INTO keyname, keytype
      FROM pg_attribute a
     WHERE a.attrelid = parent AND a.attnum = keyattnum;

    IF keyname <> partition_key THEN
        RAISE EXCEPTION '% is partitioned by %, not by %',
                        ppm.qualified_name(parent), keyname, partition_key
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- A date or a plain timestamp key would need a different bound literal and
    -- a different trip through AT TIME ZONE, and a half-supported date key is
    -- worse than a refused one: the boundaries would be right until somebody
    -- set a session TimeZone. See the README.
    IF keytype <> 'timestamp with time zone' THEN
        RAISE EXCEPTION 'partition key %.% is %, not timestamptz',
                        ppm.qualified_name(parent), keyname, keytype
            USING ERRCODE = 'feature_not_supported',
                  HINT = 'this manager handles a timestamptz key only';
    END IF;

    -- Retention removes whole partitions. A window narrower than two
    -- partitions can only point at the one being written to, which is a typo
    -- rather than an intention: 1 day instead of 1 year, or days instead of
    -- months.
    IF retention IS NOT NULL AND retention < step * 2 THEN
        RAISE EXCEPTION 'retention % is shorter than two % partitions (%)',
                        retention, granularity, step * 2
            USING ERRCODE = 'invalid_parameter_value',
                  HINT = 'retention is measured from the newest boundary backwards';
    END IF;

    IF archive_schema IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_namespace n WHERE n.nspname = archive_schema) THEN
        RAISE EXCEPTION 'archive schema % does not exist', archive_schema
            USING ERRCODE = 'invalid_schema_name',
                  HINT = 'CREATE SCHEMA before registering the set';
    END IF;

    INSERT INTO ppm.partition_set AS s (
        parent_table, partition_key, granularity, premake,
        retention, retention_action, archive_schema, bound_tz
    )
    VALUES (
        parent, partition_key, granularity, premake,
        retention, retention_action, archive_schema, bound_tz
    )
    ON CONFLICT (parent_table) DO UPDATE
       SET partition_key    = excluded.partition_key,
           granularity      = excluded.granularity,
           premake          = excluded.premake,
           retention        = excluded.retention,
           retention_action = excluded.retention_action,
           archive_schema   = excluded.archive_schema,
           bound_tz         = excluded.bound_tz
    RETURNING s.* INTO saved;

    PERFORM ppm.log(
        p_parent_name := ppm.qualified_name(parent),
        p_action      := 'register',
        p_message     := format('%s partitions, premake %s, retention %s, bounds in %s',
                                saved.granularity, saved.premake,
                                coalesce(saved.retention::text, 'none'), saved.bound_tz));

    RAISE NOTICE '% registered: % partitions, % ahead, retention %',
                 ppm.qualified_name(parent), saved.granularity, saved.premake,
                 coalesce(saved.retention::text, 'none');

    RETURN saved;
END $$;

COMMENT ON FUNCTION ppm.register_set(regclass, name, text, integer, interval, text, name, text) IS
    'Put a range-partitioned table under management, or update its settings. '
    'Validates everything the other functions then assume.';

CREATE OR REPLACE FUNCTION ppm.unregister_set(parent regclass)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    removed integer;
BEGIN
    DELETE FROM ppm.partition_set WHERE parent_table = parent;
    GET DIAGNOSTICS removed = ROW_COUNT;

    IF removed = 0 THEN
        RAISE NOTICE '% was not registered', ppm.qualified_name(parent);
        RETURN false;
    END IF;

    PERFORM ppm.log(
        p_parent_name := ppm.qualified_name(parent),
        p_action      := 'unregister',
        p_message     := 'settings removed, partitions left alone');

    RETURN true;
END $$;

COMMENT ON FUNCTION ppm.unregister_set(regclass) IS
    'Forget a partition set. The table and its partitions are untouched: this '
    'stops the manager acting on them, it does not undo what it did.';

-- The registry with its set resolved, for a monitoring query that wants to
-- know what is managed without joining to the catalogue itself.
CREATE OR REPLACE VIEW ppm.managed AS
SELECT s.parent_table,
       ppm.qualified_name(s.parent_table) AS parent_name,
       s.granularity,
       s.premake,
       s.retention,
       s.retention_action,
       s.archive_schema,
       s.bound_tz,
       (SELECT count(*) FROM ppm.partitions(s.parent_table)) AS partition_count,
       ppm.default_partition(s.parent_table) IS NOT NULL AS has_default,
       s.registered_at
  FROM ppm.partition_set s
 WHERE EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = s.parent_table);
