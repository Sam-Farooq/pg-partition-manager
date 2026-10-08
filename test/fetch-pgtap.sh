#!/bin/sh
#
# Fetch pgTAP at a pinned tag and turn it into a single loadable SQL file.
#
#   test/fetch-pgtap.sh <version> <sha256> <dir>
#
# pgTAP is pure SQL and PL/pgSQL, with no shared library, so the whole of it
# can be loaded into one database with psql. That matters here because CI runs
# the server as a container: CREATE EXTENSION needs the control file on the
# server's own filesystem, and nothing on the runner can put it there.
#
# This does not run pgTAP's own Makefile, which is PGXS and wants pg_config.
# For a server newer than 9.6 that Makefile turns sql/pgtap.sql.in into
# sql/pgtap.sql with exactly the two substitutions below and applies none of
# its compat patches. The output of this script was compared byte for byte
# against the Makefile's on PostgreSQL 16.15 before it was committed.
set -eu

version=${1:?usage: fetch-pgtap.sh <version> <sha256> <dir>}
sha=${2:?missing sha256}
dir=${3:-.pgtap}

out="$dir/pgtap-$version.sql"
if [ -f "$out" ]; then
    echo "pgtap: $out already present"
    exit 0
fi

mkdir -p "$dir"
tarball="$dir/pgtap-$version.tar.gz"
url="https://github.com/theory/pgtap/archive/refs/tags/v$version.tar.gz"

echo "pgtap: fetching $url"
curl --fail --silent --show-error --location --output "$tarball" "$url"

if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$tarball" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$tarball" | cut -d' ' -f1)
else
    echo "pgtap: no sha256sum or shasum on PATH, refusing to use an unverified tarball" >&2
    exit 1
fi

if [ "$actual" != "$sha" ]; then
    echo "pgtap: checksum mismatch" >&2
    echo "  expected $sha" >&2
    echo "  actual   $actual" >&2
    rm -f "$tarball"
    exit 1
fi

tar -xzf "$tarball" -C "$dir"

src="$dir/pgtap-$version/sql/pgtap.sql.in"
[ -f "$src" ] || { echo "pgtap: $src is missing from the tarball" >&2; exit 1; }

os=$(uname | tr '[:upper:]' '[:lower:]')
majmin=${version%.*}

sed -e "s/__OS__/$os/g" -e "s/__VERSION__/$majmin/g" "$src" > "$out.tmp"
mv "$out.tmp" "$out"

echo "pgtap: wrote $out ($(wc -l < "$out" | tr -d ' ') lines)"
