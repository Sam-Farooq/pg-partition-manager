#!/bin/sh
#
# Run the pgTAP suite against any reachable PostgreSQL server.
#
#   test/run_tests.sh              every test/[0-9]*.sql
#   test/run_tests.sh 04 06        only the files whose names start with these
#
# Connection comes from the usual libpq environment: PGHOST, PGPORT, PGUSER,
# PGPASSWORD. There is no fallback and nothing is started for you. If no
# server answers, this says so and stops.
#
# It builds a database, loads pgTAP and sql/install.sql into it, runs each file
# in its own psql session, and drops the database again. Nothing is written to
# the database you happen to be connected to.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

PSQL=${PSQL:-psql}
TEST_DB=${TEST_DB:-pg_partition_manager_test}
MAINT_DB=${MAINT_DB:-postgres}
PGTAP_SQL=${PGTAP_SQL:-.pgtap/pgtap-1.3.3.sql}
out=test/out
mkdir -p "$out"

psql_q() { "$PSQL" -X -q -A -t -v ON_ERROR_STOP=1 "$@"; }

# --- is there a server at all ------------------------------------------------

if ! psql_q -d "$MAINT_DB" -c 'SELECT 1' >/dev/null 2>"$out/connect.err"; then
    echo "no PostgreSQL server answered." >&2
    echo >&2
    echo "  host     ${PGHOST:-local socket}" >&2
    echo "  port     ${PGPORT:-5432}" >&2
    echo "  user     ${PGUSER:-$(id -un)}" >&2
    echo "  database ${MAINT_DB} (set MAINT_DB if that one does not exist)" >&2
    echo >&2
    echo "libpq said:" >&2
    sed 's/^/  /' "$out/connect.err" >&2 || true
    rm -f "$out/connect.err"
    echo >&2
    echo "Start a server, or point PGHOST and PGPORT at one. CI runs a" >&2
    echo "postgres:16 service container and sets PGHOST=localhost." >&2
    exit 2
fi
rm -f "$out/connect.err"

if [ ! -f "$PGTAP_SQL" ]; then
    echo "pgTAP is not fetched yet: $PGTAP_SQL is missing." >&2
    echo "Run: make pgtap" >&2
    exit 2
fi

# --- the test database ------------------------------------------------------

exists=$(psql_q -d "$MAINT_DB" -c \
    "SELECT 1 FROM pg_database WHERE datname = '$TEST_DB'")

if [ "$exists" = "1" ] && [ "${TEST_DB_REUSE:-0}" != "1" ]; then
    echo "database \"$TEST_DB\" already exists." >&2
    echo "This script drops the database it tests in, and will not drop one it" >&2
    echo "did not create. Set TEST_DB=something_else, or TEST_DB_REUSE=1 to" >&2
    echo "say you do not want what is in there." >&2
    exit 2
fi

cleanup() {
    if [ "${KEEP_TEST_DB:-0}" = "1" ]; then
        echo "keeping database \"$TEST_DB\""
        return
    fi
    psql_q -d "$MAINT_DB" -c "DROP DATABASE IF EXISTS \"$TEST_DB\" WITH (FORCE)" >/dev/null
}
trap cleanup EXIT INT TERM

psql_q -d "$MAINT_DB" -c "DROP DATABASE IF EXISTS \"$TEST_DB\" WITH (FORCE)" >/dev/null
psql_q -d "$MAINT_DB" -c "CREATE DATABASE \"$TEST_DB\"" >/dev/null

server=$(psql_q -d "$TEST_DB" -c "SELECT current_setting('server_version')")
echo "server $server, database $TEST_DB"

psql_q -d "$TEST_DB" -f "$PGTAP_SQL" >"$out/pgtap-load.log" 2>&1
echo "pgTAP loaded from $PGTAP_SQL"

psql_q -d "$TEST_DB" -f test/fixtures.sql >"$out/fixtures.log" 2>&1
psql_q -d "$TEST_DB" -f sql/install.sql >"$out/install.log" 2>&1
echo "sql/install.sql loaded"

# --- run the files ----------------------------------------------------------

if [ "$#" -gt 0 ]; then
    files=''
    for prefix in "$@"; do
        for f in test/"$prefix"*.sql; do
            [ -f "$f" ] && files="$files $f"
        done
    done
else
    files=$(ls test/[0-9]*.sql)
fi

total=0
failed=0
files_run=0

for f in $files; do
    name=$(basename "$f" .sql)
    tap="$out/$name.tap"
    err="$out/$name.err"
    status=0
    "$PSQL" -X -q -A -t -v ON_ERROR_STOP=1 \
        -v ppm_version="$(cat VERSION)" \
        -d "$TEST_DB" -f "$f" >"$tap" 2>"$err" || status=$?

    counts=$(awk '
        /^1\.\.[0-9]+$/ { split($0, a, /\.\./); plan = a[2]; next }
        /^not ok/       { nok++; next }
        /^ok/           { ok++; next }
        END { printf "%d %d %d", plan + 0, ok + 0, nok + 0 }
    ' "$tap")
    plan=$(echo "$counts" | cut -d' ' -f1)
    ok=$(echo "$counts" | cut -d' ' -f2)
    nok=$(echo "$counts" | cut -d' ' -f3)

    files_run=$((files_run + 1))
    total=$((total + ok + nok))

    if [ "$status" -ne 0 ] || [ "$nok" -ne 0 ] || [ "$plan" -eq 0 ] || [ "$ok" -ne "$plan" ]; then
        failed=$((failed + 1))
        echo "FAIL $name  plan $plan, ok $ok, not ok $nok, psql exit $status"
        sed 's/^/    /' "$tap"
        [ -s "$err" ] && sed 's/^/    /' "$err"
    else
        echo "ok   $name  $ok tests"
    fi
done

echo
echo "$total tests in $files_run files, $failed files failed"
[ "$failed" -eq 0 ] || exit 1
