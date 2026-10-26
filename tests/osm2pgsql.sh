#!/usr/bin/env bash
# osm2pgsql end to end (recipes/osm2pgsql.json: osm2pgsql built with zig, with
# Lua, PROJ from GDAL's SDK and libpq from PostgreSQL's), against PostgreSQL
# with PostGIS, whose server runs under soft on a port of its own. From a work
# directory the app may use (its cwd permission), under soft and at low
# integrity: the pgsql output with its default style (beside the program, by
# zigsaw's patch), from tests/osm2pgsql/tiny.osm, updated with change.osc
# (--append, with the tiles it expires); the flex output with a Lua style
# that `require`s a module from the working directory, from tiny.osm.pbf,
# with a flat node file and an area table in UTM zone 32N (PROJ's proj.db);
# gzip and bzip2 input; and osm2pgsql-expire. In an AppContainer,
# osm2pgsql-expire runs, and osm2pgsql reaches the server on 127.0.0.1, as
# its container is exempt from loopback isolation while it runs. Nothing is
# written in the store's deployments.
#
#   OSM2PGSQL_HOME=path\to\store bash tests/osm2pgsql.sh [path\to\zigsaw.exe]
#
# The store needs osm2pgsql, PostgreSQL and PostGIS (OSM2PGSQL_HOME, or
# BUILD_HOME as tests/published.sh leaves it); this says so and stops if
# neither has them. Like tests/postgresql.sh, it makes a new cluster in
# PostgreSQL's data there, and removes it after. With LOG_DIR set, the
# server's output is left there.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
ZIGSAW_HOME=${OSM2PGSQL_HOME:-${BUILD_HOME:-}}
APP=org.osm2pgsql.osm2pgsql
PG=org.postgresql.PostgreSQL
for id in $APP $PG $PG.PostGIS; do
    if [ -z "$ZIGSAW_HOME" ] || [ ! -f "$ZIGSAW_HOME\\refs\\$id.json" ]; then
        echo "tests/osm2pgsql.sh needs a store with $id in OSM2PGSQL_HOME or BUILD_HOME;"
        echo "build or pull osm2pgsql, PostgreSQL and PostGIS into one first."
        exit 1
    fi
done
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
data="$ZIGSAW_HOME\\data\\$PG"
port=$((58000 + RANDOM % 900))

failures=0
gaps=0
check() {
    local label=$1
    shift
    local out
    if out=$("$@" 2>&1); then
        printf 'ok    %s\n' "$label"
    else
        printf 'FAIL  %s\n      %s\n' "$label" "$(grep -v '^\s*$' <<<"$out" | tail -1 | cut -c1-110)"
        failures=$((failures + 1))
    fi
}
# gap <label> <command...>: a check that fails for a known gap.
gap() {
    local label=$1
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'ok    %s  (a known gap that passes now)\n' "$label"
    else
        printf 'gap   %s  (known gap)\n' "$label"
        gaps=$((gaps + 1))
    fi
}

# pg <command> [args...]: one of PostgreSQL's commands, under soft.
pg() {
    local command=$1
    shift
    timeout 120 "$zigsaw" run --command=$command $PG "$@"
}
# sql <database> <statement...>: psql's unaligned output, one line per row.
sql() {
    local db=$1 args=() s
    shift
    for s in "$@"; do args+=(-c "$s"); done
    pg psql -p $port -X -At -v ON_ERROR_STOP=1 -d "$db" "${args[@]}" | tr -d '\r'
}
# is <want> <database> <statement...>: the last row is want.
is() {
    local want=$1 got
    shift
    got=$(sql "$@" 2>&1 | tail -1)
    [ "$got" = "$want" ] || { echo "got: $got"; return 1; }
}
# start: a fresh cluster, made and served by `postgresql` under soft; the
# server's run leaves its exit code in a file, for stop.
start() {
    local log="$work\\server.out" i
    rm -rf "$data\\data" "$data\\pgpass.conf" "$work\\server.exit"
    (
        timeout 600 "$zigsaw" run $PG -p $port >"$log" 2>&1
        echo $? >"$work\\server.exit"
    ) </dev/null >/dev/null 2>&1 &
    for i in $(seq 60); do
        pg pg_isready -q -p $port && return 0
        [ ! -e "$work\\server.exit" ] || break
        sleep 1
    done
    tail -5 "$log"
    return 1
}
stop() {
    local i
    pg pg_ctl stop -m fast >/dev/null || return 1
    for i in $(seq 30); do [ -e "$work\\server.exit" ] && break; sleep 1; done
    [ "$(cat "$work\\server.exit" 2>/dev/null)" = 0 ] || { echo "the server's run exited with $(cat "$work\\server.exit" 2>/dev/null)"; return 1; }
}
# database <name>: a database with PostGIS and hstore.
database() { sql postgres "create database $1" >/dev/null && sql "$1" "create extension postgis" "create extension hstore" >/dev/null; }

# o <command> [args...]: one of osm2pgsql's commands, run from the work
# directory, in $SANDBOX if set, with the server's password; a connection
# that can't be made fails in 5 s (in an AppContainer it would take 42).
o() {
    local command=$1
    shift
    timeout 120 "$zigsaw" run ${SANDBOX:+--sandbox=$SANDBOX} --env="PGPASSWORD=$password" --env=PGCONNECT_TIMEOUT=5 --command="$command" $APP "$@" 2>&1 | tr -d '\r'
    return "${PIPESTATUS[0]}"
}
# import <database> [osm2pgsql args...]: osm2pgsql into the database on the
# server, its output shown only if it fails.
import() {
    local db=$1 out
    shift
    out=$(o osm2pgsql -H localhost -P $port -U postgres -d "$db" "$@") || { echo "$out" | tail -5; return 1; }
}
# has <pattern> <command> [args...]: the command's output has a line matching.
has() {
    local pattern=$1 out
    shift
    out=$(o "$@") && grep -q -- "$pattern" <<<"$out" || { echo "$out" | tail -3; return 1; }
}

# versions: osm2pgsql --version names osm2pgsql's, Lua's and PROJ's.
versions() {
    local out
    out=$(o osm2pgsql --version) && grep -q 'osm2pgsql version 2\.3\.1' <<<"$out" &&
        grep -q 'Lua 5\.4\.9' <<<"$out" && grep -q 'Proj.* 9\.9\.0' <<<"$out" || { echo "$out"; return 1; }
}
# prompted <database>: -W asks for the password, and reads it from stdin;
# without PGPASSWORD.
prompted() {
    local out
    out=$(printf '%s\n' "$password" | timeout 120 "$zigsaw" run ${SANDBOX:+--sandbox=$SANDBOX} --command=osm2pgsql $APP \
        -H localhost -P $port -U postgres -W -d "$1" -O pgsql tiny.osm 2>&1) || { echo "$out" | tail -3; return 1; }
}
# compressed <database> <file>: the flex style's points from a compressed file.
compressed() { import "$1" -O flex -S style.lua "$2" && is 2 "$1" "select count(*) from zs_points"; }

cd "$work" || exit 1
touch "$work\\start"
cp "$root\\tests\\osm2pgsql\\tiny.osm" "$root\\tests\\osm2pgsql\\tiny.osm.pbf" "$root\\tests\\osm2pgsql\\change.osc" \
    "$root\\tests\\osm2pgsql\\style.lua" "$root\\tests\\osm2pgsql\\naming.lua" .
gzip -c tiny.osm >tiny.osm.gz
bzip2 -c tiny.osm >tiny.osm.bz2

check "PostgreSQL serves a cluster, under soft" start
password=$(cut -d: -f5 "$data\\pgpass.conf" 2>/dev/null | tr -d '\r')

counts="(select count(*) from planet_osm_point) || '|' || (select count(*) from planet_osm_line) || '|' || (select count(*) from planet_osm_polygon)"
park="select st_srid(geom) || '|' || (round(st_area(geom)) = round(st_area(st_transform(st_difference(st_makeenvelope(7.418, 43.734, 7.421, 43.736, 4326), st_makeenvelope(7.419, 43.7345, 7.420, 43.7355, 4326)), 32632)))) from zs_areas where kind = 'park'"

for SANDBOX in soft low; do
    [ $SANDBOX = soft ] && label= || label="$SANDBOX: "
    db=osm_$SANDBOX
    rm -f nodes.bin tiles.txt
    check "${label}osm2pgsql is 2.3.1, with Lua 5.4.9 and PROJ 9.9.0" versions
    check "${label}a database with PostGIS and hstore" database $db
    check "${label}-W takes the password from stdin" prompted $db
    check "${label}the pgsql output, with its default style, from .osm" import $db -O pgsql --slim --hstore-all tiny.osm
    check "${label}  makes two points, a line and two polygons" is "2|1|2" $db "select $counts"
    check "${label}  with UTF-8 names, and every tag in hstore" is "Café Zig|Musée|true" $db \
        "select string_agg(name, '|' order by osm_id) || '|' || bool_and(tags ? 'name') from planet_osm_point"
    check "${label}--append takes change.osc, expiring tiles" import $db -O pgsql --slim --hstore-all --append --expire-tiles=14 --expire-output=tiles.txt change.osc
    check "${label}  the café renamed, the museum gone, a bench new" is "Café Saw|bench" $db \
        "select string_agg(coalesce(name, amenity), '|' order by osm_id) from planet_osm_point"
    check "${label}  and its tile expired" grep -qx '14/8529/5974' tiles.txt
    check "${label}the flex output with a Lua style, from .osm.pbf, with flat nodes" import $db -O flex -S style.lua --slim --flat-nodes=nodes.bin tiny.osm.pbf
    check "${label}  makes the style's tables" is "2|1|2" $db \
        "select (select count(*) from zs_points) || '|' || (select count(*) from zs_lines) || '|' || (select count(*) from zs_areas)"
    check "${label}  with names from the module it requires" is "CAFé ZIG|MUSéE" $db "select string_agg(shout, '|' order by node_id) from zs_points"
    check "${label}  and the park in UTM zone 32N, with its pond cut out" is "32632|true" $db "$park"
    check "${label}  and the flat node file in the work directory" test -s nodes.bin
    check "${label}gzip-compressed input" compressed $db tiny.osm.gz
    check "${label}bzip2-compressed input" compressed $db tiny.osm.bz2
    check "${label}osm2pgsql-expire lists the map's tiles" has '^14/8529/5974$' osm2pgsql-expire -z 14 tiny.osm
done

SANDBOX=appcontainer
check "appcontainer: osm2pgsql-expire lists the map's tiles" has '^14/8529/5974$' osm2pgsql-expire -z 14 tiny.osm
check "appcontainer: a database with PostGIS and hstore" database osm_appcontainer
check "appcontainer: osm2pgsql reaches the server on 127.0.0.1" import osm_appcontainer -O pgsql --slim tiny.osm
# Without the exemption, it reaches the port it uses, postgresql, through
# zigsaw: PGPORT is ${uses:postgresql}, which --port moves to the server's.
forwarded() {
    local out
    out=$(ZIGSAW_LOOPBACK_EXEMPTION=0 timeout 120 "$zigsaw" run --sandbox=appcontainer --env="PGPASSWORD=$password" --env=PGCONNECT_TIMEOUT=5 \
        --port=postgresql=$port --command=osm2pgsql $APP -U postgres -d osm_forwarded -O pgsql --slim tiny.osm 2>&1 | tr -d '\r'; exit "${PIPESTATUS[0]}") ||
        { echo "$out" | tail -5; return 1; }
}
check "appcontainer: a database for the forwarded run" database osm_forwarded
check "appcontainer, without the loopback exemption: osm2pgsql reaches the server through zigsaw" forwarded
unset SANDBOX

check "the server stops" stop

written() {
    local new
    new=$(find "$(cygpath -u "$ZIGSAW_HOME")"/deploy/*/ -newer "$work\\start" -type f -print 2>/dev/null | head -3)
    [ -z "$new" ] || { echo "written: $new"; return 1; }
}
check "nothing was written in the store's deployments" written

check "no run labelled or granted the repository" sh -c "! icacls '$root' | grep -q -e 'Mandatory Label' -e 'S-1-15-'"

cd "$root" || exit 1
rm -rf "$data\\data" "$data\\pgpass.conf"
[ -z "${LOG_DIR:-}" ] || cp "$(cygpath -u "$work")"/server.out "$(cygpath -u "$LOG_DIR")/osm2pgsql-server.out" 2>/dev/null
rm -rf "$work"
echo
echo "$failures check(s) failed, and $gaps known gap(s)."
exit $((failures > 0))
