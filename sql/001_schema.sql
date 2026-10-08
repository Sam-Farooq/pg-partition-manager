-- 001_schema.sql
--
-- The schema, the registry of managed partition sets, and the log of what the
-- manager did. Every file in sql/ is re-runnable: install.sql is loaded again
-- on every upgrade, and the suite loads it twice to prove it.

CREATE SCHEMA IF NOT EXISTS ppm;

COMMENT ON SCHEMA ppm IS
    'Declarative partition lifecycle management. Functions only, no background '
    'worker and no scheduler: something outside the database calls these.';

-- The version string is duplicated from the VERSION file because SQL cannot
-- read a file. test/lint.sh fails if the two drift, and test/02_registry.sql
-- compares this against the file contents passed in by the runner.
CREATE OR REPLACE FUNCTION ppm.version()
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT '0.13.2'::text;
$$;

COMMENT ON FUNCTION ppm.version() IS 'Version of pg-partition-manager installed in this database.';

-- One row per partitioned table under management.
--
-- parent_table is a regclass, so it survives the table being renamed and
-- stores a single OID rather than a schema and a name that can disagree. The
-- cost is that dropping a managed table leaves a row pointing at an OID that
-- no longer resolves. ppm.prune_registry() clears those.
CREATE TABLE IF NOT EXISTS ppm.partition_set (
    parent_table        regclass    PRIMARY KEY,
    partition_key       name        NOT NULL,
    granularity         text        NOT NULL,
    premake             integer     NOT NULL DEFAULT 4,
    retention           interval,
    retention_action    text        NOT NULL DEFAULT 'detach',
    archive_schema      name,
    bound_tz            text        NOT NULL DEFAULT 'UTC',
    registered_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT partition_set_granularity_ck
        CHECK (granularity IN ('day', 'week', 'month')),
    CONSTRAINT partition_set_premake_ck
        CHECK (premake BETWEEN 1 AND 366),
    CONSTRAINT partition_set_retention_ck
        CHECK (retention IS NULL OR retention > interval '0'),
    CONSTRAINT partition_set_retention_action_ck
        CHECK (retention_action IN ('detach', 'drop')),
    -- An archive schema is where a detached table is moved to. Dropping a
    -- table and archiving it are different intentions and asking for both is
    -- a mistake worth rejecting rather than resolving.
    CONSTRAINT partition_set_archive_ck
        CHECK (archive_schema IS NULL OR retention_action = 'detach')
);

COMMENT ON COLUMN ppm.partition_set.bound_tz IS
    'Time zone the partition boundaries are cut in. Boundaries are local '
    'midnight in this zone, so they do not move when a client sets TimeZone.';

COMMENT ON COLUMN ppm.partition_set.premake IS
    'How many partitions ahead of the anchor ppm.create_ahead() keeps.';

-- What the manager did, one row per statement it ran or would have run.
--
-- parent_name and target_name are text rather than regclass on purpose: the
-- whole point of a retention run is that the thing it names stops existing.
CREATE TABLE IF NOT EXISTS ppm.run_log (
    id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ran_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    parent_name     text        NOT NULL,
    action          text        NOT NULL,
    target_name     text,
    dry_run         boolean     NOT NULL,
    statement       text,
    rows_moved      bigint,
    message         text,
    CONSTRAINT run_log_action_ck CHECK (action IN (
        'register', 'unregister', 'create', 'attach', 'prepare',
        'detach', 'archive', 'drop', 'drain', 'index_script'
    ))
);

CREATE INDEX IF NOT EXISTS run_log_ran_at_idx ON ppm.run_log (ran_at DESC);
CREATE INDEX IF NOT EXISTS run_log_parent_idx ON ppm.run_log (parent_name, ran_at DESC);

COMMENT ON TABLE ppm.run_log IS
    'History of manager actions. Written inside the caller transaction, so a '
    'run that rolls back leaves nothing: the log records what happened, not '
    'what was attempted.';

COMMENT ON COLUMN ppm.run_log.ran_at IS
    'clock_timestamp(), not now(), so statements inside one call are ordered '
    'by when they ran rather than sharing the transaction timestamp.';

CREATE OR REPLACE FUNCTION ppm.log(
    p_parent_name text,
    p_action      text,
    p_target_name text    DEFAULT NULL,
    p_dry_run     boolean DEFAULT false,
    p_statement   text    DEFAULT NULL,
    p_rows_moved  bigint  DEFAULT NULL,
    p_message     text    DEFAULT NULL
)
RETURNS bigint
LANGUAGE sql
SET search_path = pg_catalog, pg_temp
AS $$
    INSERT INTO ppm.run_log (
        parent_name, action, target_name, dry_run, statement, rows_moved, message
    )
    VALUES (
        p_parent_name, p_action, p_target_name,
        p_dry_run, p_statement, p_rows_moved, p_message
    )
    RETURNING id;
$$;

COMMENT ON FUNCTION ppm.log(text, text, text, boolean, text, bigint, text) IS
    'Append one row to ppm.run_log. Called by every function that acts.';

-- The last day of activity, newest first. A view rather than a function so
-- that it composes with a WHERE clause from a monitoring query.
CREATE OR REPLACE VIEW ppm.recent_runs AS
SELECT id, ran_at, parent_name, action, target_name, dry_run, rows_moved, message
  FROM ppm.run_log
 WHERE ran_at > now() - interval '1 day'
 ORDER BY ran_at DESC;
