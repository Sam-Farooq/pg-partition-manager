-- install.sql
--
-- Load every file in order, in one transaction, into the database psql is
-- connected to. Re-runnable: every object is created with IF NOT EXISTS or
-- CREATE OR REPLACE, and test/00_install.sql loads this file a second time to
-- keep that true.
--
--     psql -v ON_ERROR_STOP=1 -f sql/install.sql
--
-- The notices from IF NOT EXISTS on a second run are noise, so they are
-- turned down here rather than in the files themselves.

\set ON_ERROR_STOP on

BEGIN;

SET LOCAL client_min_messages = warning;

\ir 001_schema.sql
\ir 002_bounds.sql
\ir 003_inspect.sql
\ir 004_register.sql
\ir 005_create_ahead.sql

COMMIT;
