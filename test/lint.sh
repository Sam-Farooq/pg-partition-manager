#!/bin/sh
#
# Conventions this repository keeps, checked. There is no SQL formatter here:
# the things worth failing a build over are the ones a formatter does not
# look at, and a formatter that rewrites PL/pgSQL bodies would be worse than
# none.
#
# Needs nothing but sh, grep and awk. No database.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

fails=0
report() {
    if [ "$2" -eq 0 ]; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        fails=$((fails + 1))
    fi
}

sql_files=$(ls sql/*.sql)
test_sql=$(ls test/[0-9]*.sql)
code_files="$sql_files $test_sql test/fixtures.sql test/run_tests.sh
            test/lint.sh test/fetch-pgtap.sh"
all_text="$code_files Makefile README.md LICENSE VERSION .gitignore
          .github/workflows/ci.yml"

# --- whitespace -------------------------------------------------------------

bad=$(grep -ln ' $' $all_text || true)
[ -z "$bad" ] || echo "  trailing whitespace: $bad"
report "no trailing whitespace" "$([ -z "$bad" ] && echo 0 || echo 1)"

bad=$(grep -lU "$(printf '\r')" $all_text || true)
[ -z "$bad" ] || echo "  carriage returns: $bad"
report "no CRLF line endings" "$([ -z "$bad" ] && echo 0 || echo 1)"

bad=''
for f in $all_text; do
    [ -n "$(tail -c 1 "$f")" ] && bad="$bad $f"
done
[ -z "$bad" ] || echo "  no final newline:$bad"
report "every file ends with a newline" "$([ -z "$bad" ] && echo 0 || echo 1)"

# A tab in SQL is a different width in psql, in \d output and in a diff. The
# Makefile is exempt because make requires them.
bad=$(grep -ln "$(printf '\t')" $code_files || true)
[ -z "$bad" ] || echo "  tabs: $bad"
report "no tabs outside the Makefile" "$([ -z "$bad" ] && echo 0 || echo 1)"

# Code only. A row of a markdown table cannot be wrapped, so the README is
# checked for whitespace and for the version string but not for width.
long=$(awk 'length > 100 { printf "%s:%d ", FILENAME, FNR }' $code_files Makefile)
[ -z "$long" ] || echo "  over 100 columns: $long"
report "no code line over 100 columns" "$([ -z "$long" ] && echo 0 || echo 1)"

# --- sql/ is loadable twice -------------------------------------------------
#
# install.sql is the upgrade path, so every object has to be replaceable. One
# plain CREATE TABLE in here turns a re-install into an error, and 00_install
# only notices because it loads the file a second time.

bad=$(grep -n '^CREATE FUNCTION\|^CREATE VIEW\|^CREATE OR REPLACE TABLE' $sql_files || true)
[ -z "$bad" ] || echo "  not replaceable: $bad"
report "every function and view is CREATE OR REPLACE" "$([ -z "$bad" ] && echo 0 || echo 1)"

bad=$(grep -n '^CREATE TABLE \|^CREATE INDEX ' $sql_files | grep -v 'IF NOT EXISTS' || true)
[ -z "$bad" ] || echo "  missing IF NOT EXISTS: $bad"
report "every table and index is IF NOT EXISTS" "$([ -z "$bad" ] && echo 0 || echo 1)"

# install.sql has to include every file, in order, or a fresh install gets a
# different set of objects than an upgrade.
included=$(grep -o '^\\ir [0-9].*\.sql' sql/install.sql | awk '{ print "sql/" $2 }')
present=$(ls sql/[0-9]*.sql)
if [ "$included" = "$present" ]; then
    report "install.sql includes every sql file in order" 0
else
    echo "  included: $(echo "$included" | tr '\n' ' ')"
    echo "  present:  $(echo "$present" | tr '\n' ' ')"
    report "install.sql includes every sql file in order" 1
fi

# --- function conventions ---------------------------------------------------
#
# Every function pins search_path, because a function that resolves an
# unqualified name through the caller's search_path can be made to call
# something else. Every function is documented, because \df+ is the only help
# anyone gets at a psql prompt.

bad=''
for f in $sql_files; do
    case $f in */install.sql) continue ;; esac
    fn=$(grep -c '^CREATE OR REPLACE FUNCTION' "$f" || true)
    sp=$(grep -c '^SET search_path = pg_catalog, pg_temp' "$f" || true)
    cm=$(grep -c '^COMMENT ON FUNCTION' "$f" || true)
    [ "$fn" = "$sp" ] || bad="$bad $f(search_path $sp/$fn)"
    [ "$fn" = "$cm" ] || bad="$bad $f(comment $cm/$fn)"
done
[ -z "$bad" ] || echo " $bad"
report "every function sets search_path and has a comment" \
       "$([ -z "$bad" ] && echo 0 || echo 1)"

# --- test conventions -------------------------------------------------------

bad=''
for f in $test_sql; do
    p=$(grep -c '^SELECT plan(' "$f" || true)
    e=$(grep -c '^SELECT \* FROM finish();' "$f" || true)
    [ "$p" = 1 ] || bad="$bad $f(plan $p)"
    [ "$e" = 1 ] || bad="$bad $f(finish $e)"
done
[ -z "$bad" ] || echo " $bad"
report "every test file has one plan and one finish" "$([ -z "$bad" ] && echo 0 || echo 1)"

# A test that cannot fail is worse than a missing test, because it reports as
# coverage.
bad=$(grep -n 'ok(true\|ok( *true\|SELECT pass(' $test_sql || true)
[ -z "$bad" ] || echo "  always passes: $bad"
report "no assertion that cannot fail" "$([ -z "$bad" ] && echo 0 || echo 1)"

# Three files run outside a transaction on purpose, and each says so in its
# header. Any other file that does has forgotten to roll back, and will leave
# tables behind for the next file to trip over.
bad=''
for f in $test_sql; do
    if ! grep -q '^BEGIN;' "$f"; then
        grep -q 'autocommit' "$f" || bad="$bad $f"
    fi
done
[ -z "$bad" ] || echo "  no transaction and no reason given:$bad"
report "a test file outside a transaction says why" "$([ -z "$bad" ] && echo 0 || echo 1)"

# --- the version string -----------------------------------------------------

version=$(cat VERSION)
case $version in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "  VERSION is not three numbers: $version" ;;
esac
status=0
echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || status=1
grep -q "SELECT '$version'::text;" sql/001_schema.sql || status=1
grep -q "$version" README.md || status=1
report "VERSION, ppm.version() and the README agree on $version" "$status"

# --- pinning ----------------------------------------------------------------

status=0
grep -qE '^PGTAP_VERSION *\?= *[0-9]+\.[0-9]+\.[0-9]+$' Makefile || status=1
grep -qE '^PGTAP_SHA256 *\?= *[0-9a-f]{64}$' Makefile || status=1
report "pgTAP is pinned by version and sha256" "$status"

unpinned=$(grep -n 'uses:' .github/workflows/ci.yml \
           | grep -vE 'uses: *[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+@v?[0-9]' || true)
[ -z "$unpinned" ] || echo "  not pinned to a tag: $unpinned"
report "every CI action is pinned to a version tag" \
       "$([ -z "$unpinned" ] && echo 0 || echo 1)"

echo
if [ "$fails" -eq 0 ]; then
    echo "lint: all checks passed"
else
    echo "lint: $fails check(s) failed"
    exit 1
fi
