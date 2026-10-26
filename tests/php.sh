#!/usr/bin/env bash
# PHP end to end: PHP's runtime image (recipes/php.json) runs PHP's official
# Windows build with its php.ini and extensions under each sandbox. The
# extension images (recipes/php-apcu.json, php-xdebug.json, php-igbinary.json,
# php-redis.json, php-ssh2.json, php-yaml.json, php-zstd.json), which the SDK
# image's php-ext builds with zig, yaml's and zstd's with libraries their
# recipes build first, join PHP's runs once installed, through PHP's
# extension point, under each sandbox, and pass their own test suites:
# ssh2's and redis's against servers of tests/php/servers, built with Go, as
# this machine has none. An app that lists PHP, APCu and Xdebug as runtimes
# loads those through their .ini files, the installed others too, and
# Xdebug's step debugger connects to a DBGp client from it, in every sandbox,
# and in an AppContainer without the loopback exemption, through zigsaw.
# Composer's image
# (recipes/composer.json) installs a project offline; Kanboard
# (recipes/kanboard.json), whose dependencies a build installed with it,
# serves its pages and API with PHP's web server, under soft only.
#
# Not in CI: tests/build.sh's PHP section is, with a small test extension.
#
#   PHP_HOME=path\to\store bash tests/php.sh [path\to\zigsaw.exe]
#
# It builds the PHP images into the store unless it has them, and removes
# what it installed afterwards. The extensions' tests come from their
# release tarballs, which their builds left in the store's downloads;
# Xdebug's from its GitHub tag, as its PECL tarball has none (SEED_DOWNLOADS
# may have it). About three minutes once the images are built.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
ZIGSAW_HOME=${PHP_HOME:-${BUILD_HOME:-}}
if [ -z "$ZIGSAW_HOME" ]; then
    echo "tests/php.sh needs a store in PHP_HOME or BUILD_HOME; it builds PHP's images there unless it has them."
    exit 1
fi
export ZIGSAW_HOME
case "$ZIGSAW_HOME" in *' '*) echo "PHP_HOME can't have a space: run-tests.php splits its options at spaces"; exit 1 ;; esac
work=$(cygpath -w "$(mktemp -d)")
XDEBUG_TESTS_URL=https://github.com/xdebug/xdebug/archive/refs/tags/3.5.3.tar.gz
XDEBUG_TESTS_SHA256=954e56021668121ecc50b92d2ad1ce945f22ecf81ffc5bb5835219485b12ef5f

failures=0
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

z() { "$zigsaw" "$@"; }
manifest_of() { grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\refs\\$1.json"; }
own_layer() { grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of "$1" | cut -d: -f2)" | tail -1 | cut -d: -f2; }
deploy_of() { echo "$ZIGSAW_HOME\\deploy\\$(own_layer "$1")"; }
recipe_sha256() { grep -o '"sha256": *"[0-9a-f]*"' "$root\\recipes\\$1" | head -1 | cut -d'"' -f4; }

PHP=net.php.php SDK=net.php.php.Sdk APCU=net.php.php.APCu XDEBUG=net.php.php.Xdebug CONSUMER=test.php.consumer
IGBINARY=net.php.php.Igbinary REDIS=net.php.php.Redis SSH2=net.php.php.SSH2 SERVERS=test.php.servers
YAML=net.php.php.Yaml ZSTD=net.php.php.Zstd COMPOSER=org.getcomposer.composer KANBOARD=org.kanboard.Kanboard
installed=()
for id in $SDK $PHP $APCU $XDEBUG $IGBINARY $REDIS $SSH2 $YAML $ZSTD $SERVERS $COMPOSER $KANBOARD; do
    [ -f "$ZIGSAW_HOME\\refs\\$id.json" ] || installed+=("$id")
done

check "php-sdk.json builds PHP's SDK image" z build "$root\\recipes\\php-sdk.json"
check "php.json builds PHP's runtime image from it" z build "$root\\recipes\\php.json"
check "php-apcu.json builds APCu with the SDK's php-ext" z build "$root\\recipes\\php-apcu.json"
check "php-xdebug.json builds Xdebug with it, with compression (zlib from php8.dll)" z build "$root\\recipes\\php-xdebug.json"
check "php-igbinary.json builds igbinary" z build "$root\\recipes\\php-igbinary.json"
check "php-redis.json builds redis, with igbinary's image as an SDK" z build "$root\\recipes\\php-redis.json"
check "php-ssh2.json builds ssh2 (libssh2 and OpenSSL, as PHP ships them)" z build "$root\\recipes\\php-ssh2.json"
check "php-yaml.json builds libyaml with CMake, then yaml with it" z build "$root\\recipes\\php-yaml.json"
check "php-zstd.json builds libzstd with CMake, then zstd with it" z build "$root\\recipes\\php-zstd.json"
check "composer.json builds Composer's image, on PHP's runtime" z build "$root\\recipes\\composer.json"
check "kanboard.json builds Kanboard, its dependencies installed by Composer's alias" z build "$root\\recipes\\kanboard.json"
check "tests/php/servers builds the SSH and Redis servers with Go" z build "$root\\tests\\php\\servers\\servers.json"

# --- the runtime ---------------------------------------------------------------

mkdir -p "$work\\cwd"
php_dir=$(deploy_of $PHP)
runtime_runs() {
    local sb out
    for sb in soft low appcontainer; do
        out=$(cd "$work\\cwd" && z run --sandbox=$sb $PHP -r 'echo PHP_VERSION, " ", php_ini_loaded_file(), "\n"; foreach (["curl", "fileinfo", "gd", "intl", "mbstring", "openssl", "pdo_sqlite", "sqlite3", "sodium", "zip"] as $e) if (!extension_loaded($e)) echo "no $e\n";' | tr -d '\r')
        [ "$out" = "8.5.11 $php_dir\\php.ini" ] || { echo "$sb, got: $out"; return 1; }
    done
}
check "the runtime runs PHP with its php.ini and extensions, under soft, low and appcontainer" runtime_runs
runtime_files() {
    [ -f "$php_dir\\php.exe" ] && [ -f "$php_dir\\ext\\php_curl.dll" ] && [ -f "$php_dir\\extras\\ssl\\cacert.pem" ] || { echo "missing PHP's files"; return 1; }
    [ ! -e "$php_dir\\dev" ] || { echo "has the SDK's dev"; return 1; }
}
check "it has PHP's files, without the SDK's headers and php-ext" runtime_files
https_works() {
    local out
    out=$(cd "$work\\cwd" && z run $PHP -r '$c = curl_init("https://www.php.net/"); curl_setopt($c, CURLOPT_RETURNTRANSFER, true); echo curl_exec($c) === false ? curl_error($c) : "curl ok", "\n"; echo strlen((string) file_get_contents("https://www.php.net/")) > 1000 ? "stream ok" : "stream fails", "\n";' 2>&1 | tr -d '\r')
    [ "$out" = "curl ok
stream ok" ] || { echo "got: $out"; return 1; }
}
check "HTTPS works through curl (curl.se's certificates) and through streams (Windows' stores)" https_works

# --- the extension images ------------------------------------------------------

# Its DLL, its .ini, about.bat, the DLL's import library, and the headers
# its config.w32 installs, for extensions that build with it (APCu's and
# igbinary's).
ext_files() {
    local id ext d want
    for id in $APCU:apcu $XDEBUG:xdebug $IGBINARY:igbinary $REDIS:redis $SSH2:ssh2; do
        ext=${id#*:} d=$(deploy_of "${id%%:*}")
        want="about.bat conf.d lib php_$ext.dll "
        case $ext in apcu | igbinary) want="about.bat conf.d include lib php_$ext.dll " ;; esac
        [ "$(ls "$d" | tr '\n' ' ')" = "$want" ] || { echo "${id%%:*} has $(ls "$d" | tr '\n' ' ')"; return 1; }
        [ -f "$d\\conf.d\\$ext.ini" ] && [ -f "$d\\lib\\php_$ext.lib" ] || { echo "no conf.d\\$ext.ini or lib\\php_$ext.lib"; return 1; }
    done
    [ -f "$(deploy_of $IGBINARY)\\include\\ext\\igbinary\\src\\php7\\igbinary.h" ] || { echo "no igbinary.h"; return 1; }
}
check "each extension image has its DLL, its .ini, about.bat, its import library, and the headers it installs" ext_files
# yaml's and zstd's have the licence of the library linked into their DLL,
# and not its headers or static library.
lib_ext_files() {
    local id ext d
    for id in $YAML:yaml $ZSTD:zstd; do
        ext=${id#*:} d=$(deploy_of "${id%%:*}")
        [ "$(ls "$d" | tr '\n' ' ')" = "LICENSE LICENSE.lib$ext about.bat conf.d lib php_$ext.dll " ] || { echo "${id%%:*} has $(ls "$d" | tr '\n' ' ')"; return 1; }
        [ "$(ls "$d\\lib")" = "php_$ext.lib" ] || { echo "${id%%:*}'s lib has $(ls "$d\\lib" | tr '\n' ' ')"; return 1; }
    done
}
check "yaml's and zstd's images have their library's licence, and not its headers or static library" lib_ext_files
about() { z run $APCU | tr -d '\r' | grep -q '^This image is the PHP extension apcu, for PHP 8.5.11'; }
check "an extension image run as an app says what it is" about

# Installed, the extensions join PHP's runs, through the runtime's
# extension point: redis after igbinary, which it needs and links with.
EXTS='["apcu", "xdebug", "igbinary", "redis", "ssh2", "yaml", "zstd"]'
loaded() {
    z run "$@" -r 'foreach ('"$EXTS"' as $e) echo extension_loaded($e) ? $e : "-", " "; echo implode(" ", array_map("basename", array_map("trim", explode(",", (string) php_ini_scanned_files())))), "\n";' 2>/dev/null | tr -d '\r'
}
joins() {
    local sb out
    for sb in soft low appcontainer; do
        out=$(cd "$work\\cwd" && loaded --sandbox=$sb $PHP)
        [ "$out" = "apcu xdebug igbinary redis ssh2 yaml zstd apcu.ini igbinary.ini redis.ini ssh2.ini xdebug.ini yaml.ini zstd.ini" ] || { echo "$sb, got: $out"; return 1; }
    done
}
check "installed, the seven extensions join PHP's runs, redis after igbinary, under soft, low and appcontainer" joins
left_out() {
    local out
    out=$(cd "$work\\cwd" && loaded --noextension=$IGBINARY $PHP)
    [ "$out" = "apcu xdebug - - ssh2 yaml zstd apcu.ini ssh2.ini xdebug.ini yaml.ini zstd.ini" ] || { echo "got: $out"; return 1; }
    (cd "$work\\cwd" && z run --noextension=$IGBINARY $PHP -r '' 2>&1) | grep -qF "$REDIS doesn't join this run: it needs $IGBINARY" || { echo "no note about redis"; return 1; }
}
check "--noextension leaves igbinary out, and redis, which needs it, with a note" left_out
uses_libs() {
    local out
    out=$(cd "$work\\cwd" && z run $PHP -r '$r = new Redis(); $r->setOption(Redis::OPT_SERIALIZER, Redis::SERIALIZER_IGBINARY); echo $r->_unserialize($r->_serialize(["x" => 42]))["x"], " ", function_exists("ssh2_connect") ? "ssh2" : "-", " ", xdebug_info("mode") ? "xdebug" : "-", "\n";' 2>&1 | tr -d '\r')
    [ "$out" = "42 ssh2 xdebug" ] || { echo "got: $out"; return 1; }
}
check "redis serializes with igbinary's DLL" uses_libs
built_in_libs() {
    local out
    out=$(cd "$work\\cwd" && z run $PHP -r 'echo yaml_parse(yaml_emit(["x" => [1, 2]]))["x"][1], " ", zstd_uncompress(zstd_compress(str_repeat("z", 1000))) === str_repeat("z", 1000) ? "zstd" : "-", "\n";' 2>&1 | tr -d '\r')
    [ "$out" = "2 zstd" ] || { echo "got: $out"; return 1; }
    (cd "$work\\cwd" && z run $PHP --ri zstd 2>&1) | tr -d '\r' | grep -qx 'Zstd library => external' || { echo "zstd's library isn't the one its recipe built"; return 1; }
}
check "yaml and zstd work with the libraries their recipes built (zstd's external, not its bundled copy)" built_in_libs

# APCu's tests, from its release tarball, which its build left in the
# store's downloads.
mkdir -p "$work\\apcu"
tar -xzf "$(cygpath -u "$ZIGSAW_HOME\\cache\\downloads\\$(recipe_sha256 php-apcu.json)")" -C "$(cygpath -u "$work\\apcu")" --strip-components=1
# php-ext test's output ends with how many failed; run-tests.php's summary
# says how many passed, which mustn't be none.
passed() {
    local out=$1
    grep -q '^php-ext: 0 tests failed' <<<"$out" || { grep -A20 '^php-ext: [0-9]* tests failed' <<<"$out" | tr '\n' ' '; return 1; }
    grep -qE '^Tests passed +: +[1-9]' <<<"$out" || { echo "no tests passed: $(tail -1 <<<"$out")"; return 1; }
}
apcu_suite() {
    local out
    out=$(cd "$work\\apcu" && z run --command=php-ext $SDK test tests --ext "$(deploy_of $APCU)\\php_apcu.dll" 2>&1 | tr -d '\r')
    passed "$out"
}
check "APCu passes its test suite" apcu_suite

# Xdebug's tests, from its GitHub tag, with its own copy of run-tests.php,
# which knows the {TMPFILE:} placeholders and the AFTER section they use.
xdebug_tgz=
for d in "${SEED_DOWNLOADS:-}" "$ZIGSAW_HOME\\cache\\downloads"; do
    [ -n "$d" ] && [ -f "$d\\$XDEBUG_TESTS_SHA256" ] && xdebug_tgz="$d\\$XDEBUG_TESTS_SHA256"
done
if [ -z "$xdebug_tgz" ]; then
    xdebug_tgz="$work\\xdebug.tar.gz"
    curl -sfL "$XDEBUG_TESTS_URL" -o "$xdebug_tgz" || echo "couldn't download $XDEBUG_TESTS_URL"
fi
mkdir -p "$work\\xdebug"
xdebug_sources() {
    [ "$(sha256sum <"$xdebug_tgz" | cut -c1-64)" = "$XDEBUG_TESTS_SHA256" ] || { echo "Xdebug's tarball has another hash"; return 1; }
    tar -xzf "$(cygpath -u "$xdebug_tgz")" -C "$(cygpath -u "$work\\xdebug")" --strip-components=1
}
check "Xdebug's tests come from its 3.5.3 tag" xdebug_sources
xdebug_suite() {
    local out
    out=$(cd "$work\\xdebug" && z run --command=php-ext $SDK test --runner run-xdebug-tests.php "$@" --ext "$(deploy_of $XDEBUG)\\php_xdebug.dll" 2>&1 | tr -d '\r')
    passed "$out"
}
check "Xdebug passes its tests: base, coverage, develop, filter, gcstats, library, profiler, tracing" \
    xdebug_suite tests/base tests/coverage tests/develop tests/filter tests/gcstats tests/library tests/profiler tests/tracing
# remote_log-win writes its log into Windows' Temp and deletes it, which it
# can't while Xdebug has it open, so it passes only where the file isn't
# there yet: it goes before and after.
rm -f "C:\\Windows\\Temp\\remote-log-win.txt"
check "Xdebug passes its step debugger's tests" xdebug_suite tests/debugger
rm -f "C:\\Windows\\Temp\\remote-log-win.txt"

# igbinary's, ssh2's and redis's tests, from their release tarballs.
for x in igbinary:php-igbinary.json ssh2:php-ssh2.json redis:php-redis.json; do
    mkdir -p "$work\\${x%%:*}"
    tar -xzf "$(cygpath -u "$ZIGSAW_HOME\\cache\\downloads\\$(recipe_sha256 "${x#*:}")")" -C "$(cygpath -u "$work\\${x%%:*}")" --strip-components=1
done
igbinary_suite() {
    local out
    out=$(cd "$work\\igbinary" && z run --command=php-ext $SDK test tests --ext "$(deploy_of $IGBINARY)\\php_igbinary.dll" 2>&1 | tr -d '\r')
    passed "$out"
}
check "igbinary passes its test suite" igbinary_suite

# yaml's and zstd's, from their PECL tarballs (their recipes' second source:
# the first is their library's).
pecl_sha256() { grep -A1 'pecl.php.net/get' "$root\\recipes\\$1" | grep -o '"sha256": *"[0-9a-f]*"' | cut -d'"' -f4; }
lib_suite() {
    local ext=$1 id=$2 out
    mkdir -p "$work\\$ext"
    tar -xzf "$(cygpath -u "$ZIGSAW_HOME\\cache\\downloads\\$(pecl_sha256 php-$ext.json)")" -C "$(cygpath -u "$work\\$ext")" --strip-components=1
    out=$(cd "$work\\$ext" && z run --command=php-ext $SDK test tests --ext "$(deploy_of $id)\\php_$ext.dll" 2>&1 | tr -d '\r')
    passed "$out"
}
check "yaml passes its test suite, as php.net's build of it does" lib_suite yaml $YAML
check "zstd passes its test suite, as php.net's build of it does" lib_suite zstd $ZSTD

# The SSH server takes a password, or the key ssh2's tests have, and runs
# commands with BusyBox's sh; Redis is miniredis. Each says its port.
"$zigsaw" run $SERVERS -ssh 127.0.0.1:0 -redis 127.0.0.1:0 -user zigsaw -pass secret \
    -authorized "$work\\ssh2\\tests\\testkey_rsa.pub" >"$work\\servers.out" 2>&1 &
servers=$!
for _ in $(seq 20); do [ "$(grep -c listening "$work\\servers.out" 2>/dev/null)" = 2 ] && break; sleep 0.5; done
ssh_port=$(tr -d '\r' <"$work\\servers.out" | sed -n 's/^ssh listening on .*:\([0-9]*\)$/\1/p')
redis_port=$(tr -d '\r' <"$work\\servers.out" | sed -n 's/^redis listening on .*:\([0-9]*\)$/\1/p')
check "the SSH and Redis servers listen" test -n "$ssh_port" -a -n "$redis_port"
# ssh2_send_signal.phpt traps SIGINT in bash, which Windows has neither of;
# with MSVC's build, it fails the same way.
rm -f "$work\\ssh2\\tests\\ssh2_send_signal.phpt"
ssh2_suite() {
    local out
    out=$(cd "$work\\ssh2" && z run --command=php-ext --env=TEST_SSH2_HOSTNAME=127.0.0.1 --env=TEST_SSH2_PORT=$ssh_port \
        --env=TEST_SSH2_USER=zigsaw --env=TEST_SSH2_PASS=secret $SDK test tests --ext "$(deploy_of $SSH2)\\php_ssh2.dll" 2>&1 | tr -d '\r')
    passed "$out"
}
check "ssh2 passes its test suite against the SSH server, but for signals" ssh2_suite
# redis's own runner stops at the first Error, and miniredis lacks some of
# what tests read: tests/php/redis-each.php runs each test on its own. MSVC
# 14.44's build gets the same results, test by test (docs/findings.md).
redis_suite() {
    local out p f
    cp "$root\\tests\\php\\redis-each.php" "$work\\redis\\tests\\"
    out=$(cd "$work\\redis\\tests" && z run --command=php.exe $SDK -n -d "extension=$(deploy_of $IGBINARY)\\php_igbinary.dll" \
        -d "extension=$(deploy_of $REDIS)\\php_redis.dll" redis-each.php . 127.0.0.1 "$redis_port" 2>&1 | tr -d '\r')
    p=$(sed -n 's/^== PASSED //p' <<<"$out") f=$(sed -n 's/^== FAILED //p' <<<"$out")
    [ "${p:-0}" -ge 108 ] && [ "${f:-999}" -le 46 ] || { echo "passed ${p:-?}, failed ${f:-?}: $(tail -2 <<<"$out" | tr '\n' ' ')"; return 1; }
}
check "redis passes its tests against miniredis as MSVC's build does: 108 or more, 46 or fewer failing" redis_suite
kill $servers 2>/dev/null
wait $servers 2>/dev/null

# --- an app with the extensions as runtimes ------------------------------------

mkdir -p "$work\\consumer"
cp "$(cygpath -u "$root")"/tests/php/{check.php,app.ini,listener.php} "$(cygpath -u "$work")/consumer/"
sed -e "s/@PHP@/$(manifest_of $PHP)/" -e "s/@APCU@/$(manifest_of $APCU)/" -e "s/@XDEBUG@/$(manifest_of $XDEBUG)/" \
    "$root\\tests\\php\\consumer.json.in" >"$work\\consumer\\consumer.json"
check "an app with PHP, APCu and Xdebug as runtimes builds" z build "$work\\consumer\\consumer.json"
consumer_runs() {
    local sb out
    for sb in soft low appcontainer; do
        out=$(cd "$work\\consumer" && z run --sandbox=$sb $CONSUMER | tr -d '\r')
        [ "$out" = "ini apcu.ini xdebug.ini igbinary.ini redis.ini ssh2.ini yaml.ini zstd.ini app.ini
loaded apcu xdebug
apcu works
xdebug mode develop, debugger not connected" ] || { echo "$sb, got: $out"; return 1; }
    done
}
check "it loads both through their .ini files, the installed others, then its own, under soft, low and appcontainer" consumer_runs
# Xdebug connects to the listener, a DBGp client run by PHP's runtime, which
# takes the connection and tells it to run.
debugs() {
    local sb=$1 port out heard
    port=$((9100 + RANDOM % 800))
    (cd "$work\\consumer" && "$zigsaw" run --command=php --noextension=$XDEBUG $PHP listener.php $port 10 >"$work\\listener.out" 2>&1) &
    local listener=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q listening "$work\\listener.out" 2>/dev/null && break; sleep 0.5; done
    # Xdebug's image uses port 9003, dbgp, which --port moves.
    out=$(cd "$work\\consumer" && z run --sandbox=$sb --env=XDEBUG_MODE=debug --env=XDEBUG_SESSION=1 --port=dbgp=$port $CONSUMER 2>&1 | tr -d '\r' | grep '^xdebug mode')
    wait $listener
    heard=$(tr -d '\r' <"$work\\listener.out" | paste -sd' ')
    [ "$out" = "xdebug mode debug, debugger connected" ] && [ "$heard" = "listening init PHP status stopping" ] ||
        { echo "$sb: app: $out; listener: $heard"; return 1; }
}
check "Xdebug's step debugger connects to a DBGp client under soft" debugs soft
check "and under low" debugs low
# The consumer has the network: its container is exempt from loopback
# isolation while it runs. Without the exemption, zigsaw forwards the port.
check "and under appcontainer" debugs appcontainer
forwarded_debugs() { (export ZIGSAW_LOOPBACK_EXEMPTION=0 && debugs appcontainer); }
check "and under appcontainer without the loopback exemption, through zigsaw" forwarded_debugs

# --- Composer and Kanboard ----------------------------------------------------

# A project that requires a package from a path repository, without
# Packagist: Composer installs it offline. Its script runs composer by name.
composer_installs() {
    local sb=$1 out
    rm -rf "$work\\composer" && cp -r "$(cygpath -u "$root")/tests/php/composer" "$(cygpath -u "$work")/composer"
    out=$(cd "$work\\composer" && z run --sandbox=$sb --ephemeral $COMPOSER install --no-interaction --no-ansi 2>&1 | tr -d '\r')
    grep -q 'Installing zigsaw/hello (1.0.0)' <<<"$out" || { echo "$sb: $(tail -1 <<<"$out")"; return 1; }
    out=$(cd "$work\\composer" && z run --sandbox=$sb --ephemeral $COMPOSER run-script which --no-ansi 2>&1 | tr -d '\r')
    grep -q '^Composer version 2\.10\.3' <<<"$out" || { echo "$sb, its script: $(tail -1 <<<"$out")"; return 1; }
    # Without what zigsaw says about grants: the run's grant of the working
    # directory under low goes when it ends.
    out=$(cd "$work\\composer" && z run --sandbox=$sb $PHP -r 'require "vendor/autoload.php"; echo Zigsaw\Hello\Hello::hi(), "\n";' 2>&1 | tr -d '\r' |
        grep -v -e '^labelled ' -e '^removed the low integrity label ')
    [ "$out" = "hello from a package Composer installed" ] || { echo "$sb, PHP: $out"; return 1; }
}
check "Composer installs a project offline, and runs its script, under soft" composer_installs soft
check "and under low" composer_installs low

# Kanboard's web server, its service on a port of its own, without opening a
# browser.
kanboard_port=$((9100 + RANDOM % 800))
kanboard_start() {
    "$zigsaw" run --sandbox=$1 --ephemeral --port=http=$kanboard_port $KANBOARD --no-browser >"$work\\kanboard.out" 2>&1 &
    kanboard=$!
    for _ in $(seq 40); do grep -q 'Development Server' "$work\\kanboard.out" 2>/dev/null && break; sleep 0.25; done
}
kanboard_stop() { kill $kanboard 2>/dev/null; wait $kanboard 2>/dev/null; }
kb() { curl -s -m 10 -c "$work\\jar" -b "$work\\jar" "$@"; }
kanboard_serves() {
    local url="http://127.0.0.1:$kanboard_port" csrf out p
    csrf=$(kb "$url/?controller=AuthController&action=login" | sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' | head -1)
    [ -n "$csrf" ] || { echo "no login form"; return 1; }
    out=$(kb -o /dev/null -w '%{http_code} %{redirect_url}' --data-urlencode "csrf_token=$csrf" -d username=admin -d password=admin "$url/?controller=AuthController&action=check")
    [ "$out" = "302 $url/?controller=DashboardController&action=show" ] || { echo "logging in: $out"; return 1; }
    out=$(kb -u admin:admin -d '{"jsonrpc":"2.0","method":"createProject","id":1,"params":{"name":"zigsaw"}}' "$url/jsonrpc.php")
    [ "$out" = '{"jsonrpc":"2.0","result":1,"id":1}' ] || { echo "createProject: $out"; return 1; }
    kb -u admin:admin -d '{"jsonrpc":"2.0","method":"getAllProjects","id":2}' "$url/jsonrpc.php" | grep -q '"name":"zigsaw"' || { echo "no project"; return 1; }
    for p in /app/common.php /vendor/autoload.php /libs/picodb/lib/PicoDb/Database.php /cli; do
        out=$(kb -o /dev/null -w '%{http_code}' "$url$p")
        [ "$out" = 403 ] || { echo "$p: $out"; return 1; }
    done
    [ "$(kb -o /dev/null -w '%{http_code}' "$url/assets/js/app.min.js")" = 200 ] || { echo "no app.min.js"; return 1; }
}
kanboard_start soft
check "Kanboard logs in, creates a project through its API, and keeps its code from the web, under soft" kanboard_serves
kanboard_stop
# In an AppContainer, Kanboard listens on an internal port, and zigsaw's
# relay publishes it; the address it gives is the published one.
kanboard_published() {
    grep -q "Kanboard is at http://127.0.0.1:$kanboard_port/ " "$work\\kanboard.out" || { cat "$work\\kanboard.out"; return 1; }
    kanboard_serves
}
kanboard_start appcontainer
check "and under appcontainer, through the service zigsaw publishes" kanboard_published
kanboard_stop
kanboard_data() {
    local out
    out=$(z run --command=kanboard-cli $KANBOARD db:version 2>&1 | tr -d '\r')
    grep -qE '^Current version: [0-9]+' <<<"$out" || { echo "kanboard-cli: $out"; return 1; }
    [ -f "$ZIGSAW_HOME\\data\\$KANBOARD\\db.sqlite" ] || { echo "no db.sqlite in its data"; return 1; }
}
check "kanboard-cli makes its database in the app's data" kanboard_data
# PHP's is_writable() is false at low integrity, even for what the run may
# write: it leaves the integrity label out of its access check, and
# Kanboard refuses to start (docs/gaps.md).
kanboard_low() {
    kb "http://127.0.0.1:$kanboard_port/" | grep -q 'must be writeable by your web server user'
}
kanboard_start low
check "but under low it refuses its data directory, which PHP takes for read-only (known gap)" kanboard_low
kanboard_stop

z rm --delete-data $CONSUMER >/dev/null 2>&1
for id in "${installed[@]}"; do z rm --delete-data "$id" >/dev/null 2>&1; done
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
