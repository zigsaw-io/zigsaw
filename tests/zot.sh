#!/usr/bin/env bash
# Runs a command with two local zot registries (https://zotregistry.dev), as
# tests/registry.sh wants them: one on localhost:5000 without logins, and one
# on localhost:5001 that wants a login, with AUTH_REGISTRY, AUTH_USER and
# AUTH_PASSWORD set for it. The password is new each time, and what the
# registries stored is gone afterwards.
#
#   tests/zot.sh <command> [args...]
#   e.g. tests/zot.sh bash tests/registry.sh
#
# zot is the zigsaw app recipes/zot.json builds, run by the zigsaw under test
# (ZIGSAW, default zig-out\bin\zigsaw.exe), from the store in ZOT_HOME, or
# else BUILD_HOME (where tests/published.sh builds it), or else a temporary
# one. If zot isn't installed there at the recipe's version, it's built
# there first: minutes with its vendored modules in the store's downloads
# (or SEED_DOWNLOADS, for a temporary store), and some 15 minutes without.
# A zigsaw whose `run` is broken breaks this too: zot doesn't start, and its
# logs are shown.
#
# Needs Git Bash, curl, and zig, for the password's bcrypt hash.

set -u
export MSYS_NO_PATHCONV=1
root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${ZIGSAW:-$root\\zig-out\\bin\\zigsaw.exe}
ZOT=dev.zotregistry.zot

store=${ZOT_HOME:-${BUILD_HOME:-}}
own_store=false
if [ -z "$store" ]; then
    store=$(cygpath -w "$(mktemp -d)")
    own_store=true
    if [ -n "${SEED_DOWNLOADS:-}" ]; then
        mkdir -p "$store\\cache\\downloads"
        cp -l "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$store")/cache/downloads/" 2>/dev/null ||
            cp -n "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$store")/cache/downloads/"
    fi
fi
z() { ZIGSAW_HOME="$store" "$zigsaw" "$@"; }
dir=$(mktemp -d)
version=$(grep -o '"version": *"[^"]*"' "$root\\recipes\\zot.json" | cut -d'"' -f4)
if ! z list 2>/dev/null | grep -q "^$ZOT  *$version "; then
    echo "building zot $version in $store..."
    # Its SDK from the recipes too, as published images may not have the
    # digests the recipes pin yet.
    for recipe in busybox go zot; do
        z build "$root\\recipes\\$recipe.json" >"$dir/build.log" 2>&1 || { tail -20 "$dir/build.log"; rm -rf "$dir"; exit 1; }
    done
fi

user=zigsaw-test
password="test-$RANDOM$RANDOM$RANDOM"
zig run "$root\\tests\\htpasswd.zig" -- "$user" "$password" >"$dir/htpasswd" || { echo "making the htpasswd file failed"; exit 1; }

# config <port> <more "http" settings>. Paths are relative to $dir, the
# registries' working directory, which zot's image may use.
config() {
    printf '{ "distSpecVersion": "1.1.1", "storage": { "rootDirectory": "data-%s" },\n  "http": { "address": "127.0.0.1", "port": "%s"%s }, "log": { "level": "warn" } }\n' \
        "$1" "$1" "$2" >"$dir/zot-$1.json"
}
config 5000 ""
config 5001 ', "auth": { "htpasswd": { "path": "htpasswd" } }'
# zigsaw itself in the background, not a function or subshell running it, so
# that `kill` below ends zigsaw.
cd "$dir"
ZIGSAW_HOME="$store" "$zigsaw" run $ZOT serve zot-5000.json >zot-5000.log 2>&1 &
plain=$!
ZIGSAW_HOME="$store" "$zigsaw" run $ZOT serve zot-5001.json >zot-5001.log 2>&1 &
login=$!
cd "$OLDPWD"

# Up when the plain one answers, and the other asks for a login.
up=false
for _ in $(seq 60); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5000/v2/)" = 200 ] &&
        [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5001/v2/)" = 401 ]; then
        up=true
        break
    fi
    sleep 0.5
done
if $up; then
    AUTH_REGISTRY=localhost:5001 AUTH_USER=$user AUTH_PASSWORD=$password "$@"
    code=$?
else
    echo "zot didn't start:"
    cat "$dir"/zot-*.log
    code=1
fi
# Ending zigsaw ends zot with it: the run's job object.
kill $plain $login 2>/dev/null
wait 2>/dev/null
rm -rf "$dir"
if $own_store; then
    for id in $ZOT org.golang.go net.frippery.busybox; do z rm --delete-data $id >/dev/null 2>&1; done
    z prune --downloads >/dev/null 2>&1
    rm -rf "$store"
fi
exit $code
