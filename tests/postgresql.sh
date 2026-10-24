#!/usr/bin/env bash
# PostgreSQL end to end (recipes/postgresql.json: PostgreSQL built with zig,
# with OpenSSL, zlib, lz4, zstd and libxml2 built in, ICU from Windows'
# icu.dll, and PL/Perl and PL/Python on the Perl and Python images as
# runtimes). Under each sandbox, `postgresql` makes a cluster in the app's
# data on its first run and serves it in the foreground; psql, pg_dump,
# pg_restore, pg_basebackup and pg_ctl, each a run of its own, reach it on
# 127.0.0.1 with the password the cluster was made with, from the password
# file in the app's data. Under soft: TLS (a test certificate), pgcrypto on
# OpenSSL, ICU collations, lz4 and zstd compression, XML, PL/Perl and
# PL/Python (with errors raised through them), a dump restored, a backup
# made, and nothing written in the deployment. Under low and in an
# AppContainer: a cluster made there, with the server's default settings,
# and the procedural languages (plperl.on_init too). A client outside an
# AppContainer can't reach the server in it (no loopback exemption): a
# known gap. Under each, the installed extension images join: pgvector's
# HNSW index answers a nearest-neighbour query, pg_cron, which the server
# preloads, runs a job every second, and PostGIS transforms a point with
# PROJ's proj.db, buffers with GEOS, reads GeoJSON and GML and uses a GiST
# index (and makes a topology, under soft); --noextension leaves pg_cron
# out.
#
#   POSTGRES_HOME=path\to\store bash tests/postgresql.sh [path\to\zigsaw.exe]
#
# Building PostgreSQL takes some 10 minutes, so this uses a store that has
# it and the three extensions (POSTGRES_HOME, or BUILD_HOME as tests/published.sh
# leaves it), and says so and stops if neither has. With LOG_DIR set, each
# server's output (initdb's too) is left there.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
ZIGSAW_HOME=${POSTGRES_HOME:-${BUILD_HOME:-}}
APP=org.postgresql.PostgreSQL
for id in $APP $APP.pgvector $APP.pg_cron $APP.PostGIS; do
    if [ -z "$ZIGSAW_HOME" ] || [ ! -f "$ZIGSAW_HOME\\refs\\$id.json" ]; then
        echo "tests/postgresql.sh needs a store with $id in POSTGRES_HOME or BUILD_HOME;"
        echo "build recipes\\postgresql.json, postgresql-pgvector.json, postgresql-pg-cron.json and postgresql-postgis.json into one first."
        exit 1
    fi
done
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
data="$ZIGSAW_HOME\\data\\$APP"
port=$((57000 + RANDOM % 900))

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

# pg <command> [args...]: one of the image's commands, in the sandbox.
pg() {
    local command=$1
    shift
    timeout 120 "$zigsaw" run ${SANDBOX:+--sandbox=$SANDBOX} --command=$command $APP "$@"
}
# sql <statement...>: psql's unaligned output, one line per row.
sql() {
    local args=() s
    for s in "$@"; do args+=(-c "$s"); done
    pg psql -p $port -X -At -v ON_ERROR_STOP=1 "${args[@]}" | tr -d '\r'
}
# is <want> <statement...>: the last row is want.
is() {
    local want=$1 got
    shift
    got=$(sql "$@" 2>&1 | tail -1)
    [ "$got" = "$want" ] || { echo "got: $got"; return 1; }
}

# start [postgres options]: a fresh cluster, made and served by `postgresql`,
# with zigsaw's run options in RUN_OPTIONS. check runs it in a subshell, so
# the server's run leaves its exit code in a file, for stop.
start() {
    local log="$work\\server-${SANDBOX:-soft}${RUN_OPTIONS:+-options}.out" i
    rm -rf "$data\\data" "$data\\pgpass.conf" "$work\\server.exit"
    (
        timeout 600 "$zigsaw" run ${SANDBOX:+--sandbox=$SANDBOX} ${RUN_OPTIONS:-} $APP -p $port "$@" >"$log" 2>&1
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
# stop: pg_ctl, from a run of its own, and the server's run ends with 0.
stop() {
    local i
    pg pg_ctl stop -m fast >/dev/null || return 1
    for i in $(seq 30); do [ -e "$work\\server.exit" ] && break; sleep 1; done
    [ "$(cat "$work\\server.exit" 2>/dev/null)" = 0 ] || { echo "the server's run exited with $(cat "$work\\server.exit" 2>/dev/null)"; return 1; }
}
# vectors: pgvector's HNSW index finds the nearest of three vectors.
vectors() {
    local out
    out=$(sql "create extension vector" "create table items (id int, v vector(3))" \
        "insert into items values (1, '[1,2,3]'), (2, '[4,5,6]'), (3, '[1,1,1]')" \
        "create index on items using hnsw (v vector_l2_ops)" "set enable_seqscan = off" \
        "select id from items order by v <-> '[1,1,2]' limit 1" \
        "explain (costs off) select id from items order by v <-> '[1,1,2]' limit 1" 2>&1)
    grep -qx 3 <<<"$out" && grep -q 'Index Scan using items_v_idx' <<<"$out" || { echo "$out"; return 1; }
}
# postgis: PostGIS on GEOS, PROJ (with proj.db, found through PROJ_DATA),
# json-c and libxml2, and a GiST index; topology in soft only.
postgis() {
    local out
    out=$(sql "create extension postgis" \
        "select postgis_lib_version() || '|' || postgis_geos_version() || '|' || split_part(postgis_proj_version(), ' ', 1)" \
        "select st_astext(st_snaptogrid(st_transform(st_setsrid(st_point(10, 50), 4326), 3857), 0.01))" \
        "select st_intersects(st_buffer(st_point(0, 0), 1), st_point(0.5, 0.5))" \
        "select st_asgeojson(st_geomfromgeojson('{\"type\":\"LineString\",\"coordinates\":[[1,2],[3,4]]}'))" \
        "select st_astext(st_geomfromgml('<gml:Point><gml:coordinates>1,2</gml:coordinates></gml:Point>'))" \
        "create table places (id int, g geometry(point, 4326))" \
        "insert into places select i, st_setsrid(st_point(i % 100, i / 100), 4326) from generate_series(0, 9999) i" \
        "create index on places using gist (g)" "analyze places" \
        "select count(*) from places where g && st_makeenvelope(10, 10, 12, 12, 4326)" \
        "explain (costs off) select count(*) from places where g && st_makeenvelope(10, 10, 12, 12, 4326)" 2>&1)
    grep -qx '3.6.4|3.15.0-CAPI-1.21.0|9.9.0' <<<"$out" &&
        grep -qx 'POINT(1113194.91 6446275.84)' <<<"$out" && grep -qx t <<<"$out" &&
        grep -qx '{"type":"LineString","coordinates":\[\[1,2\],\[3,4\]\]}' <<<"$out" &&
        grep -qx 'POINT(1 2)' <<<"$out" && grep -qx 9 <<<"$out" &&
        grep -q 'Index.* Scan .*places_g_idx' <<<"$out" || { echo "$out"; return 1; }
}
# topology: postgis_topology makes a topology and adds an edge to it.
topology() {
    local out
    out=$(sql "create extension postgis_topology" "select topology.createtopology('t', 4326) > 0" \
        "select topology.topogeo_addlinestring('t', 'LINESTRING(0 0, 1 1)'::geometry(linestring, 4326)) is not null" \
        "select count(*) from t.edge_data")
    [ "$(printf '%s\n' "$out" | tail -3 | tr '\n' ' ')" = "t t 1 " ] || { echo "$out" | tr '\n' ' '; return 1; }
}
# cron: pg_cron, which the server preloads, runs a job every second.
cron() {
    local i n=0
    sql "create extension pg_cron" "create table ticks (at timestamptz default now())" \
        "select cron.schedule('tick', '1 seconds', 'insert into ticks default values')" >/dev/null || return 1
    for i in $(seq 10); do
        sleep 1
        n=$(sql "select count(*) from ticks") || return 1
        [ "$n" -lt 2 ] || return 0
    done
    echo "$n tick(s) in 10 s; last run: $(sql "select status || ' ' || coalesce(return_message, '') from cron.job_run_details order by runid desc limit 1")"
    return 1
}

# Runs from the work directory: the app has no filesystem permission.
cd "$work" || exit 1
touch "$work\\start"
mkdir -p "$data"
cp "$root\\tests\\postgresql\\server.crt" "$root\\tests\\postgresql\\server.key" "$data\\"

check "postgresql makes a cluster and serves it, with TLS" \
    start -c ssl=on -c "ssl_cert_file=$data\\server.crt" -c "ssl_key_file=$data\\server.key"
version() { sql "select version()" | grep -q '^PostgreSQL 18\.6 on x86_64-windows, compiled by clang-'; }
check "it's PostgreSQL 18.6, built with clang" version
check "the cluster is UTF-8, in the builtin provider's C.UTF-8" is "UTF8|b|C.UTF-8" \
    "select pg_encoding_to_char(encoding), datlocprovider, datlocale from pg_database where datname = 'postgres'"
check "with the server's default settings" is "100|128MB" "select current_setting('max_connections') || '|' || current_setting('shared_buffers')"
check "its password is in the app's data" grep -q '^\*:\*:\*:postgres:[A-Za-z0-9]\{24\}$' "$data\\pgpass.conf"
nopass() { timeout 60 "$zigsaw" run --env="PGPASSFILE=$data\\none" --command=psql $APP -p $port -X -w -c "select 1" 2>&1 | grep -q 'no password supplied'; }
check "a client without it is refused" nopass
check "a connection over TLS 1.3" sh -c "\"\$0\" run --command=psql $APP 'host=localhost port=$port sslmode=require' -XAt -c 'select ssl, version from pg_stat_ssl where pid = pg_backend_pid()' | tr -d '\r' | grep -qx 't|TLSv1.3'" "$zigsaw"
check "pgcrypto hashes with OpenSSL" is "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" \
    "create extension pgcrypto" "select encode(digest('abc', 'sha256'), 'hex')"
check "ICU collations sort German and Swedish apart" is "aäz|azä" \
    "select string_agg(x, '' order by x collate \"de-x-icu\") || '|' || string_agg(x, '' order by x collate \"sv-x-icu\") from (values ('a'), (U&'\\00E4'), ('z')) v(x)"
check "lz4 compresses a column" is "lz4" \
    "create table big (v text compression lz4)" "insert into big select string_agg(md5(i::text), '') from generate_series(1, 2000) i" \
    "select pg_column_compression(v) from big"
check "zstd compresses WAL" is "zstd" "set wal_compression = zstd" "show wal_compression"
check "XML is parsed with libxml2" is "{zigsaw}" "select xpath('/a/b/text()', '<a><b>zigsaw</b></a>')::text"
check "a PL/Perl function runs on Perl's image" is "perl 5.42.3" \
    "create extension plperl" "create function perlv() returns text as \$\$ return sprintf('perl %vd', \$^V); \$\$ language plperl" "select perlv()"
check "a PL/Python function runs on Python's image" is "python 3.14.7" \
    "create extension plpython3u" "create function pyv() returns text as \$\$ import sys; return 'python %d.%d.%d' % sys.version_info[:3] \$\$ language plpython3u" "select pyv()"
errors() {
    local out
    out=$(pg psql -p $port -X -At \
        -c "do \$\$ spi_exec_query('select 1/0'); \$\$ language plperl" \
        -c "do \$\$ plpy.execute('select 1/0') \$\$ language plpython3u" \
        -c "do \$\$ begin perform 1/0; exception when division_by_zero then raise notice 'caught'; end \$\$" \
        -c "do \$\$ begin end \$\$ language nosuchlang" -c "select 'still here'" 2>&1 | tr -d '\r')
    [ "$(grep -c 'division by zero\|DivisionByZero' <<<"$out")" = 2 ] && grep -q 'NOTICE:  caught' <<<"$out" &&
        grep -q 'language "nosuchlang" does not exist' <<<"$out" && grep -qx 'still here' <<<"$out" || { echo "$out"; return 1; }
}
check "errors raised through PL/Perl, PL/Python and PL/pgSQL leave the session working" errors
dump() {
    pg pg_dump -p $port -Fc -f "$data\\postgres.dump" postgres &&
        pg createdb -p $port restored && pg pg_restore -p $port -d restored "$data\\postgres.dump" &&
        [ "$(pg psql -p $port -XAt -d restored -c 'select perlv() || pyv() || count(*) from big' | tr -d '\r')" = "perl 5.42.3python 3.14.71" ]
}
check "pg_dump's dump restores into another database" dump
backup() {
    pg pg_basebackup -p $port -Ft --compress=client-zstd --checkpoint=fast -D "$data\\backup" && test -s "$data\\backup\\base.tar.zst"
}
check "pg_basebackup makes a zstd-compressed backup" backup
check "pgvector's HNSW index finds the nearest vector" vectors
check "pg_cron, preloaded, runs a job every second" cron
check "PostGIS: GEOS, PROJ with its proj.db, json-c, GML and a GiST index" postgis
check "PostGIS topology makes a topology with an edge" topology
check "pg_ctl stops it from another run" stop
tree=$(cygpath -w "$("$zigsaw" run --command=pg_config $APP --bindir 2>/dev/null | tr -d '\r')\\..")
written() {
    local new
    new=$(find "$tree" -newer "$work\\start" -print 2>/dev/null | head -3)
    [ -z "$new" ] || { echo "written: $new"; return 1; }
}
check "nothing was written in the deployment" written

RUN_OPTIONS=--noextension=$APP.pg_cron
check "with --noextension=…pg_cron, a server starts without it" start
check "  and preloads nothing, while pgvector still joins" is "|1" \
    "create extension vector" "select current_setting('shared_preload_libraries') || '|' || count(*) from pg_extension where extname = 'vector'"
check "  and pg_ctl stops it" stop
unset RUN_OPTIONS

for SANDBOX in low appcontainer; do
    check "$SANDBOX: postgresql makes a cluster and serves it" start -c 'plperl.on_init=$main::booted = 47;'
    check "$SANDBOX: with the server's default settings" is "100|128MB" "select current_setting('max_connections') || '|' || current_setting('shared_buffers')"
    check "$SANDBOX: PL/Perl runs" is "perl 5.42.3" \
        "create extension plperl" \
        "create function perlv() returns text as \$\$ return sprintf('perl %vd', \$^V); \$\$ language plperl" \
        "select perlv()"
    check "$SANDBOX: plperl.on_init ran when Perl started" is 47 \
        "create extension plperlu" \
        "create function booted() returns int as \$\$ return \$main::booted; \$\$ language plperlu" \
        "select booted()"
    check "$SANDBOX: PL/Python runs" is "python 3.14.7" \
        "create extension plpython3u" \
        "create function pyv() returns text as \$\$ import sys; return 'python %d.%d.%d' % sys.version_info[:3] \$\$ language plpython3u" \
        "select pyv()"
    check "$SANDBOX: pgvector's HNSW index finds the nearest vector" vectors
    check "$SANDBOX: pg_cron runs a job every second" cron
    check "$SANDBOX: PostGIS, with PROJ's proj.db" postgis
    if [ $SANDBOX = appcontainer ]; then
        outside() { timeout 60 "$zigsaw" run --sandbox=soft --command=psql $APP -p $port -XAt -c "select 1" | tr -d '\r' | grep -qx 1; }
        gap "appcontainer: a client outside the container reaches the server in it" outside
    fi
    check "$SANDBOX: pg_ctl stops it from another run" stop
done
unset SANDBOX

check "no run labelled or granted the repository" sh -c "! icacls '$root' | grep -q -e 'Mandatory Label' -e 'S-1-15-'"

cd "$root" || exit 1
rm -rf "$data\\data" "$data\\pgpass.conf" "$data\\backup" "$data\\postgres.dump" "$data\\server.crt" "$data\\server.key"
[ -z "${LOG_DIR:-}" ] || cp "$(cygpath -u "$work")"/server-*.out "$(cygpath -u "$LOG_DIR")" 2>/dev/null
rm -rf "$work"
echo
echo "$failures check(s) failed, and $gaps known gap(s)."
exit $((failures > 0))
