#!/usr/bin/env bash
# End-to-end checks for `zigsaw push` and `zigsaw pull` against a real
# registry: apps round-trip between two stores through it, byte for byte.
#
#   tests/registry.sh [registry-host] [path\to\zigsaw.exe]
#
# The registry defaults to localhost:5000 and must already be running with no
# authentication, for example zot (https://zotregistry.dev):
#   zot serve config.json   # with "http": { "address": "127.0.0.1", "port": "5000" }
# Also makes read-only anonymous requests to ghcr.io and Docker Hub.
#
# To also check registry logins, run a second registry that requires one and
# set AUTH_REGISTRY (e.g. localhost:5001), AUTH_USER and AUTH_PASSWORD. For zot,
# add "auth": { "htpasswd": { "path": "htpasswd" } } to its "http" settings,
# with a bcrypt htpasswd line, e.g. from PHP's password_hash(..., PASSWORD_BCRYPT).

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
registry=${1:-localhost:5000}
zigsaw=${2:-$root/zig-out/bin/zigsaw.exe}
if ! curl -sf "http://${registry/localhost/127.0.0.1}/v2/" >/dev/null; then
    echo "no registry answers at $registry; start one first (see the top of this script)"
    exit 1
fi

work=$(cygpath -w "$(mktemp -d)")
repo="$registry/zigsaw-test-$RANDOM"

# Two stores: apps are built in one, pushed, and pulled into the other.
store_a="$work\\a"
store_b="$work\\b"
za() { ZIGSAW_HOME="$store_a" "$zigsaw" "$@"; }
zb() { ZIGSAW_HOME="$store_b" "$zigsaw" "$@"; }

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
fails() { ! "$@"; }

za build "$root/recipes/busybox.json" >/dev/null 2>&1 || { echo "building busybox failed"; exit 1; }
digest=$(za list | awk '$1 == "net.frippery.busybox" { print $3 }')

tags_list() { curl -s "http://${registry/localhost/127.0.0.1}/v2/${repo#*/}/busybox/tags/list" | grep -q FRP-6075-g169694ebd; }
second_push() { [ "$(za -v push net.frippery.busybox "$repo/busybox" 2>&1 | grep -c ' upload ')" -eq 0 ]; }
pulled_runs() { [ "$(zb run net.frippery.busybox echo pulled | tr -d '\r')" = pulled ]; }
same_digest() { [ "$(zb list | awk '$1 == "net.frippery.busybox" { print $3 }')" = "$digest" ]; }
missing_tag() { zb pull "$repo/busybox:nope" 2>&1 | grep -q 'not found'; }
# Container images, as found on real registries, are refused, not installed.
refused() { zb pull "$1" 2>&1 | grep -qE 'not a zigsaw app|multi-platform index'; }

check "push" za push net.frippery.busybox "$repo/busybox"
check "the tag defaults to the app's version" tags_list
check "pushing again uploads nothing" second_push
check "pull into an empty store" zb pull "$repo/busybox:FRP-6075-g169694ebd"
check "the pulled app runs" pulled_runs
check "the pulled image has the pushed digest" same_digest
full_digest=$(grep -o 'sha256:[0-9a-f]*' "$store_a\\refs\\net.frippery.busybox.json")
check "pull by digest" zb pull "$repo/busybox@$full_digest"
check "a digest that doesn't match is refused" fails zb pull "$repo/busybox@sha256:$(printf '0%.0s' {1..64})"
check "a missing tag is reported" missing_tag
check "the pulled app's commands are installed" test -f "$store_b\\bin\\busybox.exe"

# `update` follows the tag an app was pulled by, and leaves a digest alone.
za push net.frippery.busybox "$repo/busybox:latest" >/dev/null 2>&1
zb pull "$repo/busybox:latest" >/dev/null 2>&1
update_up_to_date() { zb update net.frippery.busybox 2>&1 | grep -q 'up to date'; }
update_moved_tag() {
    sed 's/"version": "[^"]*"/"version": "reg-2"/' "$root/recipes/busybox.json" >"$work\\busybox-2.json" &&
        za build "$work\\busybox-2.json" >/dev/null 2>&1 &&
        za push net.frippery.busybox "$repo/busybox:latest" >/dev/null 2>&1 &&
        zb update net.frippery.busybox >/dev/null 2>&1 &&
        zb list | grep -q '^net.frippery.busybox  *reg-2 '
}
update_pinned() { zb pull "$repo/busybox@$full_digest" >/dev/null 2>&1 && zb update net.frippery.busybox 2>&1 | grep -q pinned; }
check "update: an unmoved tag is up to date" update_up_to_date
check "update: a moved tag is pulled again" update_moved_tag
check "update: an app pulled by digest is pinned" update_pinned
# Back to the recipe's version, which the checks below push and pull.
za build "$root/recipes/busybox.json" >/dev/null 2>&1

# App ids name images in the default registry, here the test registry.
sza() { ZIGSAW_REGISTRY="$repo" ZIGSAW_HOME="$store_a" "$zigsaw" "$@"; }
szb() { ZIGSAW_REGISTRY="$repo" ZIGSAW_HOME="$store_b" "$zigsaw" "$@"; }
check "push by app id" sza push net.frippery.busybox
short_pull() {
    szb pull net.frippery.busybox:FRP-6075-g169694ebd >/dev/null 2>&1 &&
        grep -q "\"source\": \"$repo/net.frippery.busybox:FRP-6075-g169694ebd\"" "$store_b\\refs\\net.frippery.busybox.json"
}
check "pull by app id; the ref records the full reference" short_pull
check "pull by app id defaults to :latest" sh -c "ZIGSAW_REGISTRY='$repo' ZIGSAW_HOME='$store_a' \"\$0\" push net.frippery.busybox net.frippery.busybox:latest && ZIGSAW_REGISTRY='$repo' ZIGSAW_HOME='$store_b' \"\$0\" pull net.frippery.busybox" "$zigsaw"
other_app_image() {
    za push net.frippery.busybox "$repo/org.example.other:1" >/dev/null 2>&1 &&
        szb pull org.example.other:1 2>&1 | grep -q 'holds net.frippery.busybox, not org.example.other'
}
check "pull by app id refuses an image of another app" other_app_image
check "push by app id refuses another app's image" sh -c "ZIGSAW_REGISTRY='$repo' ZIGSAW_HOME='$store_a' \"\$0\" push net.frippery.busybox org.example.other:2 2>&1 | grep -q 'is the image of org.example.other'" "$zigsaw"

# A large app: its 100 MB layer streams both ways.
za build "$root\\recipes\\node.json" >/dev/null 2>&1 || { echo "building node failed"; exit 1; }
check "push node (100 MB layer)" za push org.nodejs.node "$repo/node"
check "pull node" zb pull "$repo/node:24.21.0"
check "the pulled node runs" zb run org.nodejs.node -e 'process.exit(0)'

# Real registries, read-only and anonymous: the token flow works.
check "ghcr.io: anonymous token, container image refused" refused ghcr.io/oras-project/oras:v1.2.0
check "Docker Hub: anonymous token, container image refused" refused docker.io/library/alpine:3.20

if [ -n "${AUTH_REGISTRY:-}" ]; then
    auth_repo="$AUTH_REGISTRY/zigsaw-test-$RANDOM/busybox"
    unset ZIGSAW_REGISTRY_USERNAME ZIGSAW_REGISTRY_PASSWORD
    with_login() { ZIGSAW_REGISTRY_USERNAME="$AUTH_USER" ZIGSAW_REGISTRY_PASSWORD="$AUTH_PASSWORD" "$@"; }
    asks_for_login() { za push net.frippery.busybox "$auth_repo" 2>&1 | grep -q 'needs credentials'; }
    wrong_password() { ZIGSAW_REGISTRY_USERNAME="$AUTH_USER" ZIGSAW_REGISTRY_PASSWORD=wrong za push net.frippery.busybox "$auth_repo" 2>&1 | grep -q 'refused the credentials'; }
    # A fresh store, so the pulls below really fetch from the login registry.
    store_c="$work\c"
    zc() { ZIGSAW_HOME="$store_c" "$zigsaw" "$@"; }
    check "login registry: push without credentials asks for them" asks_for_login
    check "login registry: a wrong password is refused" wrong_password
    check "login registry: push with credentials" with_login za push net.frippery.busybox "$auth_repo"
    check "login registry: pull without credentials fails" fails zc pull "$auth_repo:FRP-6075-g169694ebd"
    check "login registry: pull with credentials" with_login zc pull "$auth_repo:FRP-6075-g169694ebd"
fi

# Installed apps are protected against deletion, so remove them through zigsaw.
for store in "$work\a" "$work\b" "$work\c"; do
    for id in net.frippery.busybox org.nodejs.node; do ZIGSAW_HOME="$store" "$zigsaw" rm --delete-data "$id" >/dev/null 2>&1; done
    ZIGSAW_HOME="$store" "$zigsaw" prune >/dev/null 2>&1
done
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
