#!/usr/bin/env bash
# PHP end to end: PHP's runtime image (recipes/php.json) runs PHP's official
# Windows build with its php.ini and extensions under each sandbox, and the
# APCu and Xdebug images (recipes/php-apcu.json, php-xdebug.json), which the
# SDK image's php-ext builds with zig, pass their own test suites in it. An
# app that lists PHP, APCu and Xdebug as runtimes loads both through their
# .ini files under each sandbox, and Xdebug's step debugger connects to a
# DBGp client from it, except in an AppContainer, which can't reach
# 127.0.0.1 (docs/gaps.md).
#
# Not in CI: tests/build.sh's PHP section is, with a small test extension.
#
#   PHP_HOME=path\to\store bash tests/php.sh [path\to\zigsaw.exe]
#
# It builds the PHP images into the store unless it has them, and removes
# what it installed afterwards. APCu's tests come from its release tarball,
# which its build left in the store's downloads; Xdebug's from its GitHub
# tag, as its PECL tarball has none (SEED_DOWNLOADS may have it). About two
# minutes once the images are built.

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
installed=()
for id in $SDK $PHP $APCU $XDEBUG; do [ -f "$ZIGSAW_HOME\\refs\\$id.json" ] || installed+=("$id"); done

check "php-sdk.json builds PHP's SDK image" z build "$root\\recipes\\php-sdk.json"
check "php.json builds PHP's runtime image from it" z build "$root\\recipes\\php.json"
check "php-apcu.json builds APCu with the SDK's php-ext" z build "$root\\recipes\\php-apcu.json"
check "php-xdebug.json builds Xdebug with it" z build "$root\\recipes\\php-xdebug.json"

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

ext_files() {
    local id ext d
    for id in $APCU:apcu $XDEBUG:xdebug; do
        ext=${id#*:} d=$(deploy_of "${id%%:*}")
        [ "$(ls "$d" | tr '\n' ' ')" = "about.bat conf.d php_$ext.dll " ] || { echo "${id%%:*} has $(ls "$d" | tr '\n' ' ')"; return 1; }
        [ -f "$d\\conf.d\\$ext.ini" ] || { echo "no conf.d\\$ext.ini"; return 1; }
    done
}
check "each extension image has its DLL, its .ini and about.bat, and nothing else" ext_files
about() { z run $APCU | tr -d '\r' | grep -q '^This image is the PHP extension apcu, for PHP 8.5.11'; }
check "an extension image run as an app says what it is" about

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
        [ "$out" = "ini apcu.ini xdebug.ini app.ini
loaded apcu xdebug
apcu works
xdebug mode develop, debugger not connected" ] || { echo "$sb, got: $out"; return 1; }
    done
}
check "it loads both through their .ini files, then its own, under soft, low and appcontainer" consumer_runs
# Xdebug connects to the listener, a DBGp client run by PHP's runtime, which
# takes the connection and tells it to run.
debugs() {
    local sb=$1 port out heard
    port=$((9100 + RANDOM % 800))
    (cd "$work\\consumer" && "$zigsaw" run --command=php $PHP listener.php $port 10 >"$work\\listener.out" 2>&1) &
    local listener=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q listening "$work\\listener.out" 2>/dev/null && break; sleep 0.5; done
    out=$(cd "$work\\consumer" && z run --sandbox=$sb --env=XDEBUG_MODE=debug --env=XDEBUG_SESSION=1 --env=XDEBUG_CONFIG=client_port=$port $CONSUMER 2>&1 | tr -d '\r' | grep '^xdebug mode')
    wait $listener
    heard=$(tr -d '\r' <"$work\\listener.out" | paste -sd' ')
    case $sb in
    appcontainer)
        # An AppContainer can't connect to 127.0.0.1 without a loopback
        # exemption, which needs an administrator (docs/gaps.md).
        [ "$out" = "xdebug mode debug, debugger not connected" ] && [ "$heard" = "listening no connection" ] ;;
    *) [ "$out" = "xdebug mode debug, debugger connected" ] && [ "$heard" = "listening init PHP status stopping" ] ;;
    esac || { echo "$sb: app: $out; listener: $heard"; return 1; }
}
check "Xdebug's step debugger connects to a DBGp client under soft" debugs soft
check "and under low" debugs low
check "but not under appcontainer, which can't reach 127.0.0.1 (known gap)" debugs appcontainer

z rm --delete-data $CONSUMER >/dev/null 2>&1
for id in "${installed[@]}"; do z rm --delete-data "$id" >/dev/null 2>&1; done
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
