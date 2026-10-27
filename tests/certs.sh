#!/usr/bin/env bash
# Certificate trust (docs/networking.md#certificate-trust): which apps trust
# a root CA added to Windows, as a network that inspects TLS adds its own.
#
# Each run makes a test CA with Git Bash's openssl, name-constrained to
# localhost, 127.0.0.0/8 and ::1 and valid for a day, and a certificate for
# localhost, with which tests/certs/server.py serves HTTPS on Python's image
# and PostgreSQL's server its TLS. While Windows doesn't trust the CA, every
# client must refuse them, under soft (so each one verifies). Then with the
# CA in the machine's Trusted Root store (LocalMachine\Root), each client
# under soft, low and appcontainer: Python's urllib, Node's fetch, Java's
# HttpClient on the JDK and the JRE, MinGit's ls-remote, CMake's
# file(DOWNLOAD), zig fetch, psql with sslrootcert=system, and PHP's streams
# and curl if the store has PHP. Apps that keep a bundle of CAs of their own
# are known gaps.
#
#   CERTS_HOME=path\to\store bash tests/certs.sh [path\to\zigsaw.exe]
#
# The store (CERTS_HOME, or BUILD_HOME) needs Python's image; each other
# client is skipped, saying so, if the store hasn't its image (CI's suites
# store has them all but PHP's). Adding the CA to LocalMachine\Root takes an
# elevated shell, which CI's runners are. Elsewhere, CERTS_ELEVATE=1 runs
# certutil through a UAC prompt, once to add the CA and once to take it out;
# without either, only the rows from before it's trusted run. The CA is
# taken out when the suite ends, a failure too; if the suite is killed, run
# `certutil -delstore Root <serial>` as an administrator, with the serial it
# printed.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
ZIGSAW_HOME=${CERTS_HOME:-${BUILD_HOME:-}}
PY=org.python.python
NODE=org.nodejs.node
JDK=org.openjdk.java.Sdk
JRE=org.openjdk.java
GIT=org.git_scm.MinGit
CMAKE=org.cmake.cmake
ZIG=org.ziglang.zig
PG=org.postgresql.PostgreSQL
PHP=net.php.php
has() { [ -f "$ZIGSAW_HOME\\refs\\$1.json" ]; }
if [ -z "$ZIGSAW_HOME" ] || ! has $PY; then
    echo "tests/certs.sh needs a store with $PY in CERTS_HOME or BUILD_HOME"
    exit 1
fi
export ZIGSAW_HOME
command -v openssl >/dev/null || { echo "tests/certs.sh needs openssl (Git Bash has it)"; exit 1; }
work=$(cygpath -w "$(mktemp -d)")
port=$((47000 + RANDOM % 900))
pgport=$((port + 1000))
url="https://localhost:$port"
pgdata="$ZIGSAW_HOME\\data\\$PG"

. "$(dirname "$0")/acprobe.sh"

failures=0
gaps=0
# What the clients say when they don't trust the server's certificate.
refusal='certif|issuer|PKIX|SEC_E_|TLS|SSL'
# row <want> <label> <command...>: want is ok (it connects), refuses (it
# doesn't, as it mustn't, saying something of certificates or TLS), or gap
# (a known gap: it doesn't). CERTS_VERBOSE=1 shows why each refused.
row() {
    local want=$1 label=$2 out rc
    shift 2
    out=$("$@" 2>&1)
    rc=$?
    if [ $want = refuses ] && [ $rc != 0 ] && ! grep -qiE "$refusal" <<<"$out"; then rc=0; fi
    case $want/$rc in
    refuses/[1-9]*)
        printf 'ok    %s\n' "$label"
        [ "${CERTS_VERBOSE:-0}" = 0 ] || printf '      %s\n' "$(grep -v '^\s*$' <<<"$out" | tail -1 | cut -c1-110)"
        ;;
    ok/0) printf 'ok    %s\n' "$label" ;;
    gap/0) printf 'ok    %s  (a known gap that passes now)\n' "$label" ;;
    gap/*)
        printf 'gap   %s  (known gap)\n' "$label"
        gaps=$((gaps + 1))
        ;;
    *)
        printf 'FAIL  %s\n      %s\n' "$label" "$(grep -v '^\s*$' <<<"$out" | tail -1 | cut -c1-110)"
        failures=$((failures + 1))
        ;;
    esac
}
z() {
    local sandbox=$1
    shift
    timeout 120 "$zigsaw" run --sandbox="$sandbox" "$@"
}
# says <want> <command...>: the last line the command prints is want; else
# it says what came, and the last line of its errors.
says() {
    local want=$1 out
    shift
    out=$("$@" 2>"$work\\stderr" | tr -d '\r' | grep -v '^\s*$' | tail -1)
    [ "$out" = "$want" ] || { echo "got \"$out\"; $(tr -d '\r' <"$work\\stderr" | grep -v '^\s*$' | tail -1)"; return 1; }
}

# The clients, each given a sandbox.
python_get() { says ok z "$1" $PY -c "import urllib.request; print(urllib.request.urlopen('$url/ok').read().decode().strip())"; }
node_get() { says ok z "$1" $NODE -e "fetch('$url/ok').then(r => r.text()).then(t => console.log(t.trim()), e => { console.log(String(e.cause || e)); process.exitCode = 1 })"; }
jdk_get() { says ok z "$1" $JDK Get.java "$url/ok"; }
jre_get() { says ok z "$1" $JRE -cp classes Get "$url/ok"; }
# A repository that isn't there: git got as far as asking for it.
git_get() {
    local out
    out=$(z "$1" $GIT ls-remote "$url/repo.git" 2>&1 | tr -d '\r')
    grep -q "repository '$url/repo.git/' not found" <<<"$out" || { grep -v '^\s*$' <<<"$out" | tail -1; return 1; }
}
cmake_get() { says "-- download 0" z "$1" $CMAKE "-DURL=$url/ok" -P download.cmake; }
# zig's image has no network permission, which zig fetch needs in an
# AppContainer.
zig_get() {
    local out
    out=$(z "$1" --share=network $ZIG fetch "$url/pkg.tar.gz" 2>&1) || { grep -v '^\s*$' <<<"$out" | tail -1; return 1; }
}
psql_get() { says 1 z "$1" --command=psql $PG "host=localhost port=$pgport dbname=postgres user=postgres sslmode=verify-full sslrootcert=system" -XAt -c "select 1"; }
# Its warnings on one line: the TLS one comes before "Failed to open stream".
# (A handler of its own, too, as an installed Xdebug adds its stack to them.)
php_stream_get() { says ok z "$1" $PHP -r "\$w = []; set_error_handler(function (\$n, \$m) use (&\$w) { \$w[] = \$m; return true; }); \$r = file_get_contents('$url/ok'); echo \$r === false ? implode(' / ', \$w) : trim(\$r), PHP_EOL;"; }
php_curl_get() { says ok z "$1" $PHP -r "\$c = curl_init('$url/ok'); curl_setopt(\$c, CURLOPT_RETURNTRANSFER, true); \$r = curl_exec(\$c); echo \$r === false ? curl_error(\$c) : trim(\$r), PHP_EOL;"; }

# The clients the store has: "<image> <function> <name>".
clients=()
for c in "$PY python_get Python" "$NODE node_get Node" "$JDK jdk_get Java_on_the_JDK" "$JRE jre_get Java_on_the_JRE" \
    "$GIT git_get MinGit" "$CMAKE cmake_get CMake" "$ZIG zig_get zig" "$PG psql_get psql" \
    "$PHP php_stream_get PHP's_streams" "$PHP php_curl_get PHP's_curl"; do
    set -- $c
    if has "$1"; then clients+=("$c"); else echo "skip  ${3//_/ }: the store hasn't $1"; fi
done
# want <function> <sandbox>: what each client is meant to do once Windows
# trusts the CA. In an AppContainer, the clients whose programs Server 2025
# keeps from running there (tests/acprobe.zig) are known gaps there.
want() {
    case $1/$2 in
    php_curl_get/*) echo gap ;; # its own bundle, extras\ssl\cacert.pem
    psql_get/*) echo gap ;;     # OpenSSL's default paths, under B:\prefix\ssl, where the build was
    zig_get/low) echo gap ;;    # zig's std opens the store to write: CertificateBundleLoadFailure
    node_get/appcontainer) ac_if final-path-dos self-path-dos nul ;;
    jdk_get/appcontainer | jre_get/appcontainer | git_get/appcontainer | cmake_get/appcontainer) ac_if self-path-dos nul ;;
    zig_get/appcontainer) ac_if self-path-dos ;;
    *) echo ok ;;
    esac
}

trusted=0
server=
pgserver=
elevated() { net session >/dev/null 2>&1; }
# admin <certutil arguments...>: certutil as an administrator, through a UAC
# prompt unless the shell is elevated.
admin() {
    if elevated; then
        certutil "$@" >/dev/null
    elif [ "${CERTS_ELEVATE:-0}" = 1 ]; then
        local list= a
        for a in "$@"; do list+="${list:+,}'\"$a\"'"; done
        powershell -NoProfile -Command "exit (Start-Process -FilePath certutil -ArgumentList $list -Verb RunAs -Wait -PassThru -WindowStyle Hidden).ExitCode"
    else
        return 1
    fi
}
cleanup() {
    if [ $trusted = 1 ]; then
        admin -delstore Root "$serial" || echo "taking the test CA out failed: run certutil -delstore Root $serial as an administrator"
    fi
    [ -z "$pgserver" ] || { z soft --port=postgresql=$pgport --command=pg_ctl $PG stop -m fast >/dev/null 2>&1; wait "$pgserver" 2>/dev/null; }
    [ -z "$server" ] || { kill "$server" 2>/dev/null; wait "$server" 2>/dev/null; }
    if has $PG; then rm -rf "$pgdata\\data" "$pgdata\\pgpass.conf"; fi
    acprobe_rm "$zigsaw" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT

cd "$work" || exit 1
acprobe_run "$zigsaw" "$root" "$work"

# --- The CA, and the servers -------------------------------------------------

openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 1 \
    -subj "/CN=zigsaw tests certs.sh $RANDOM$RANDOM" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "nameConstraints=critical,permitted;DNS:localhost,permitted;IP:127.0.0.0/255.0.0.0,permitted;IP:::1/ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff" \
    >/dev/null 2>&1 || { echo "making the test CA failed"; exit 1; }
printf '%s\n' "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1" "basicConstraints=critical,CA:FALSE" \
    "keyUsage=critical,digitalSignature,keyEncipherment" "extendedKeyUsage=serverAuth" >leaf.ext
openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj "/CN=localhost" >/dev/null 2>&1 &&
    openssl x509 -req -in leaf.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -extfile leaf.ext -out leaf.crt >/dev/null 2>&1 ||
    { echo "making the server's certificate failed"; exit 1; }
serial=$(openssl x509 -noout -serial -in ca.crt | sed 's/^serial=//')
echo "The test CA's serial: $serial"

cp "$root\\tests\\certs\\server.py" "$root\\tests\\certs\\Get.java" .
printf '%s\n' 'file(DOWNLOAD "${URL}" STATUS status TLS_VERIFY ON)' 'list(GET status 0 code)' 'list(GET status 1 why)' \
    'message(STATUS "download ${code}")' 'if(code)' '  message(STATUS "${why}")' 'endif()' >download.cmake
# zig fetch looks for a build.zig.
printf '%s\n' 'pub fn build(_: *@import("std").Build) void {}' >build.zig
if has $JDK; then z soft --command=javac $JDK -d classes Get.java >/dev/null 2>&1 || echo "compiling Get.java failed"; fi

"$zigsaw" run $PY server.py $port leaf.crt leaf.key ready >server.out 2>&1 &
server=$!
for i in $(seq 30); do [ -e ready ] && break; sleep 1; done
[ -e ready ] || { echo "the HTTPS server didn't start:"; tail -5 server.out; exit 1; }

if has $PG; then
    rm -rf "$pgdata\\data" "$pgdata\\pgpass.conf"
    "$zigsaw" run --port=postgresql=$pgport $PG -c ssl=on -c "ssl_cert_file=$work\\leaf.crt" -c "ssl_key_file=$work\\leaf.key" >pg.out 2>&1 &
    pgserver=$!
    for i in $(seq 60); do z soft --port=postgresql=$pgport --command=pg_isready $PG -q 2>/dev/null && break; sleep 1; done
    z soft --port=postgresql=$pgport --command=pg_isready $PG -q 2>/dev/null || { echo "PostgreSQL's server didn't start:"; tail -5 pg.out; exit 1; }
fi

# --- Before Windows trusts the CA --------------------------------------------

for c in "${clients[@]}"; do
    set -- $c
    row refuses "${3//_/ } refuses the server while Windows doesn't trust its CA" $2 soft
done

# --- Once it does ------------------------------------------------------------

if ! admin -addstore Root "$work\\ca.crt" || ! certutil -store Root "$serial" >/dev/null 2>&1; then
    echo "The test CA couldn't be added to LocalMachine\\Root: that takes an elevated shell, or CERTS_ELEVATE=1 for a UAC prompt."
else
    trusted=1
    for sandbox in soft low appcontainer; do
        for c in "${clients[@]}"; do
            set -- $c
            row "$(want $2 $sandbox)" "$sandbox: ${3//_/ } trusts it" $2 $sandbox
        done
    done
fi

acprobe_report
echo "$failures check(s) failed, and $gaps known gap(s)."
[ $failures = 0 ]
