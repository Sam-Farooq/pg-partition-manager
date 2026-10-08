-- 00_install.sql
--
-- The objects sql/install.sql is supposed to create, the version string, and
-- the claim that the file can be loaded twice. Runs in autocommit because it
-- loads install.sql again, and install.sql opens its own transaction.

SELECT plan(9);

SELECT has_schema('ppm', 'schema ppm exists');
SELECT has_table('ppm', 'partition_set', 'the registry exists');
SELECT has_table('ppm', 'run_log', 'the run log exists');
SELECT has_view('ppm', 'recent_runs', 'the recent_runs view exists');
SELECT has_index('ppm', 'run_log', 'run_log_ran_at_idx', 'the log is indexed by time');

SELECT is(ppm.version(), :'ppm_version',
          'ppm.version() agrees with the VERSION file');
SELECT cmp_ok(current_setting('server_version_num')::integer, '>=', 160000,
              'server is PostgreSQL 16 or newer');

-- Leave something behind, load the whole thing again, and check it survived.
-- Every object in sql/ is CREATE OR REPLACE or IF NOT EXISTS so that an
-- upgrade is one psql run and not a drop.
SELECT ppm.log('install_test', 'register', p_message := 'written before reinstall');

\o /dev/null
\i sql/install.sql
\o

SELECT is((SELECT count(*)::integer FROM ppm.run_log
            WHERE parent_name = 'install_test'), 1,
          'a second install.sql kept the log row');
SELECT is(ppm.version(), :'ppm_version',
          'a second install.sql left the version alone');

SELECT * FROM finish();
