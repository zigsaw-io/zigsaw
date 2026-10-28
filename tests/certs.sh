#!/usr/bin/env bash
# Certificate trust (docs/networking.md#certificate-trust): which apps trust
# a root CA added to Windows, as a network that inspects TLS adds its own.
#
# Each run makes a test CA with Git Bash's openssl, name-constrained to
# localhost, 127.0.0.0/8 and ::1 and valid for a day, and a certificate for
# localhost that names the CA's CRL, with which tests/certs/server.py serves
# HTTPS on Python's image (and the CRL over HTTP), and PostgreSQL's server
# its TLS. While Windows doesn't trust the CA, every client must refuse them,
# under soft (so each one verifies). Then with the CA in the machine's
# Trusted Root store (LocalMachine\Root), each client under soft, low and
# appcontainer: Python's urllib, Node's fetch, Java's HttpClient on the JDK
# and the JRE, MinGit's ls-remote, CMake's file(DOWNLOAD), zig fetch, psql
# with sslrootcert=system, PHP's streams and curl, Composer, and Perl's
# HTTP::Tiny. The last four, and psql, read the file of Windows' roots
# zigsaw writes (${roots}), which each sandbox's runs must be able to read.
#
#   CERTS_HOME=path\to\store bash tests/certs.sh [path\to\zigsaw.exe]
#
# The store (CERTS_HOME, or BUILD_HOME) needs Python's image; each other
# client is skipped, saying so, if the store hasn't its image (CI's suites
# store has them all). Adding the CA to LocalMachine\Root takes an
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
COMPOSER=org.getcomposer.composer
PERL=org.perl.perl
has() { [ -f "$ZIGSAW_HOME\\refs\\$1.json" ]; }
if [ -z "$ZIGSAW_HOME" ] || ! has $PY; then
    echo "tests/certs.sh needs a store with $PY in CERTS_HOME or BUILD_HOME"
    exit 1
fi
export ZIGSAW_HOME
command -v openssl >/dev/null || { echo "tests/certs.sh needs openssl (Git Bash has it)"; exit 1; }
work=$(cygpath -w "$(mktemp -d)")
port=$((47000 + RANDOM % 900))
crlport=$((port + 900))
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
        printf 'gap   %s  (known gap)\n      %s\n' "$label" "$(grep -v '^\s*$' <<<"$out" | tail -1 | cut -c1-110)"
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
# Composer resolves zigsaw/certs from the server's repository (composer.json).
composer_get() {
    local out
    out=$(z "$1" $COMPOSER update --dry-run --no-interaction --no-plugins --no-scripts 2>&1 | tr -d '\r')
    grep -q 'Locking zigsaw/certs (1.0.0)' <<<"$out" && return 0
    # Its error, which Composer wraps over lines (and follows with the
    # command's usage), on one; any other error, as it is.
    if grep -q 'curl error' <<<"$out"; then
        grep -A3 'curl error' <<<"$out" | grep -v '^update \[' | sed 's/^ *//;s/ *$//' | tr -d '\n'
        echo
    else
        grep -v '^\s*$' <<<"$out" | grep -v '^update \[' | tail -3 | tr '\n' ' '
        echo
    fi
    return 1
}
# Perl's image has no network permission, which an AppContainer needs.
# Perl's scripts are files (below): with -e, Perl opens nul, which an
# AppContainer on Server 2025 can't (tests/acprobe.zig).
perl_get() { says ok z "$1" --share=network $PERL get.pl "$url/ok"; }
# The file of Windows' roots the images that take only a file are given
# (SSL_CERT_FILE=${roots}): the run can read it, and it has some.
roots_read() {
    local n
    n=$(z "$1" $PERL roots.pl 2>"$work\\stderr" | tr -d '\r')
    [ "$n" -gt 0 ] 2>/dev/null || { echo "got \"$n\"; $(tr -d '\r' <"$work\\stderr" | grep -v '^\s*$' | tail -1)"; return 1; }
}

# The clients the store has: "<image> <function> <name>".
clients=()
for c in "$PY python_get Python" "$NODE node_get Node" "$JDK jdk_get Java_on_the_JDK" "$JRE jre_get Java_on_the_JRE" \
    "$GIT git_get MinGit" "$CMAKE cmake_get CMake" "$ZIG zig_get zig" "$PG psql_get psql" \
    "$PHP php_stream_get PHP's_streams" "$PHP php_curl_get PHP's_curl" "$COMPOSER composer_get Composer" "$PERL perl_get Perl"; do
    set -- $c
    if has "$1"; then clients+=("$c"); else echo "skip  ${3//_/ }: the store hasn't $1"; fi
done
# want <function> <sandbox>: what each client is meant to do once Windows
# trusts the CA. In an AppContainer, the clients whose programs Server 2025
# keeps from running there (tests/acprobe.zig) are known gaps there.
want() {
    case $1/$2 in
    zig_get/low) echo gap ;; # zig's std opens the store to write: CertificateBundleLoadFailure
    jre_get/appcontainer | git_get/appcontainer) ac_if self-path-dos nul ;;
    # Composer starts its subprocesses (git, to guess the project's version)
    # through Symfony's Process, whose pipes on Windows open NUL.
    composer_get/appcontainer) ac_if nul ;;
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
# Its CRL, which the server's certificate names: curl over Schannel (CMake's)
# refuses a certificate whose revocation it can't check.
printf '%s\n' '[ca]' 'default_ca = test' '[test]' 'database = index.txt' 'crlnumber = crlnumber' \
    'default_md = sha256' 'default_crl_days = 1' >ca.cnf
: >index.txt
echo 01 >crlnumber
openssl ca -config ca.cnf -gencrl -keyfile ca.key -cert ca.crt -out ca.crl.pem >/dev/null 2>&1 &&
    openssl crl -in ca.crl.pem -outform DER -out ca.crl || { echo "making the test CA's CRL failed"; exit 1; }
printf '%s\n' "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1" "basicConstraints=critical,CA:FALSE" \
    "keyUsage=critical,digitalSignature,keyEncipherment" "extendedKeyUsage=serverAuth" \
    "crlDistributionPoints=URI:http://localhost:$crlport/ca.crl" >leaf.ext
openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj "/CN=localhost" >/dev/null 2>&1 &&
    openssl x509 -req -in leaf.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -extfile leaf.ext -out leaf.crt >/dev/null 2>&1 ||
    { echo "making the server's certificate failed"; exit 1; }
serial=$(openssl x509 -noout -serial -in ca.crt | sed 's/^serial=//')
echo "The test CA's serial: $serial"

cp "$root\\tests\\certs\\server.py" "$root\\tests\\certs\\Get.java" .
printf '%s\n' 'use HTTP::Tiny;' 'my $r = HTTP::Tiny->new(verify_SSL => 1)->get($ARGV[0]);' \
    'print $r->{success} ? $r->{content} : "$r->{status} $r->{content}\n";' >get.pl
printf '%s\n' 'open my $f, "<", $ENV{SSL_CERT_FILE} or die "$ENV{SSL_CERT_FILE}: $!\n";' \
    'print scalar(grep /^-----BEGIN CERTIFICATE-----/, <$f>), "\n";' >roots.pl
# On a failure, curl's own reason (Schannel's lines of its log) last.
printf '%s\n' 'file(DOWNLOAD "${URL}" STATUS status TLS_VERIFY ON LOG log)' 'list(GET status 0 code)' 'list(GET status 1 why)' \
    'message(STATUS "download ${code}")' 'if(code)' '  message(STATUS "${why}")' \
    '  string(REGEX MATCHALL "schannel: [^\n]*" lines "${log}")' '  foreach(l IN LISTS lines)' '    message(STATUS "${l}")' '  endforeach()' \
    'endif()' >download.cmake
# zig fetch looks for a build.zig.
printf '%s\n' 'pub fn build(_: *@import("std").Build) void {}' >build.zig
# Composer's project: zigsaw/certs, from the server's repository only.
printf '{"repositories": [{"type": "composer", "url": "%s"}, {"packagist.org": false}], "require": {"zigsaw/certs": "1.0.0"}}\n' "$url" >composer.json
if has $JDK; then z soft --command=javac $JDK -d classes Get.java >/dev/null 2>&1 || echo "compiling Get.java failed"; fi

"$zigsaw" run $PY server.py $port leaf.crt leaf.key ready $crlport ca.crl >server.out 2>&1 &
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
if has $PERL; then
    for sandbox in soft low appcontainer; do
        row "$(want roots_read $sandbox)" "$sandbox: a run reads Windows' roots from \${roots}" roots_read $sandbox
    done
    # A file written after the app's AppContainer runs were granted the one
    # before, as when Windows' roots change: it comes from the store's tmp\
    # with the ACL it had there, so each run grants the file itself.
    rm -f "$(cygpath -u "$ZIGSAW_HOME")"/certs/roots-*.pem
    roots_read soft >/dev/null
    row "$(want roots_read appcontainer)" "appcontainer: reads it too when it's written after the app's grant" roots_read appcontainer
fi

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
