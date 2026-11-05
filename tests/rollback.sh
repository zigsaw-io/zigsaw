#!/usr/bin/env bash
# End-to-end checks for going back: the version an update replaces is kept,
# `zigsaw rollback` returns to it without the network and has updates pass over
# the version it left, and `zigsaw hold` keeps updates away. Store a builds a
# small app from a recipe and pushes each version under one tag; store b pulls
# it, as anyone would.
#
#   tests/zot.sh bash tests/rollback.sh [path\to\zigsaw.exe]
#
# Needs a registry on localhost:5000. Takes well under a minute.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root\\zig-out\\bin\\zigsaw.exe}
work=$(cygpath -wl "$(mktemp -d)")
mkdir -p "$work\\cwd" && cd "$work\\cwd" || exit 1

export ZIGSAW_TASK_NAME="ZigsawTest-rollback-$$"
export ZIGSAW_GRANTS_KEY="Software\\ZigsawTest\\rollback-$$"
export ZIGSAW_SHORTCUTS_DIR="$work\\links"
export ZIGSAW_USER_FOLDERS="$work\\folders"
export DOCKER_CONFIG="$work\\docker"
mkdir -p "$DOCKER_CONFIG" "$ZIGSAW_USER_FOLDERS"

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

registry=localhost:5000
curl -sf "http://127.0.0.1:5000/v2/" >/dev/null || { echo "no registry on $registry: run this under tests/zot.sh"; exit 1; }

APP=test.rollback.app
repo="$registry/zigsaw-rollback-$RANDOM"
store_a="$work\\a"
store_b="$work\\b"
za() { ZIGSAW_HOME="$store_a" "$zigsaw" "$@"; }
zb() { ZIGSAW_HOME="$store_b" "$zigsaw" "$@"; }
recipe() { # <version> [network]
    local extra=
    [ "${2:-}" = network ] && extra=', "network": true'
    printf '{ "id": "%s", "version": "%s", "command": "app.cmd", "permissions": { "sandbox": "soft"%s },\n  "exports": { "rbapp": { "command": "app.cmd" } },\n  "modules": [{ "name": "scripts", "sources": [{ "path": "app.cmd" }] }] }\n' "$APP" "$1" "$extra" >"$work\\app.json"
    printf '@echo version %s\r\n' "$1" >"$work\\app.cmd"
}
publish() { recipe "$@" && za build "$work\\app.json" >/dev/null 2>&1 && za push $APP "$repo:latest" >/dev/null 2>&1; }
installed_version() { zb list 2>/dev/null | tr -d '\r' | awk -v id=$APP '$1 == id { print $2 }'; }
list_line() { zb list 2>/dev/null | tr -d '\r' | grep "^$APP "; }
runs_version() { [ "$("$store_b\\bin\\rbapp.exe" 2>/dev/null | tr -d '\r')" = "version $1" ]; }
versions_file() { echo "$store_b\\versions\\$APP.$1"; }
previous_manifest() { grep -o 'sha256:[0-9a-f]*' "$(versions_file previous.json)" | head -1; }
deployments() { find "$store_b/deploy" -mindepth 1 -maxdepth 1 -type d | wc -l; }

publish 1 || { echo "publishing the fixture failed"; exit 1; }
zb pull --yes "$repo:latest" >/dev/null 2>&1 || { echo "pulling the fixture failed"; exit 1; }

# --- What's kept --------------------------------------------------------------
nothing_yet() {
    local out
    out=$(zb rollback $APP </dev/null 2>&1) && { echo "it exited 0"; return 1; }
    grep -q 'nothing to go back to' <<<"$out" && runs_version 1
}
check "with only the version first installed, rollback has nothing to go back to" nothing_yet
check "rollback of an app that isn't installed fails" fails zb rollback no.such.app
check "rollback without an app is a usage error" fails zb rollback

publish 2
kept() {
    zb update --yes >/dev/null 2>&1 || return 1
    [ "$(installed_version)" = 2 ] && runs_version 2 || return 1
    list_line | grep -q '(previous 1)' && [ -e "$(versions_file previous.json)" ]
}
check "an update keeps the version it replaced, and list says so" kept
prune_keeps_blobs() {
    local out manifest
    manifest=$(previous_manifest)
    out=$(zb prune 2>&1) || { echo "$out"; return 1; }
    grep -q 'kept 1 previous version(s) (.*) for `zigsaw rollback`; --previous deletes them' <<<"$out" || { echo "$out"; return 1; }
    [ -e "$store_b\\blobs\\sha256\\${manifest#sha256:}" ] || { echo "its manifest went"; return 1; }
    # One layer per version here: only the installed one is unpacked.
    [ "$(deployments)" = 1 ] || { echo "$(deployments) deployments"; return 1; }
}
check "prune keeps the previous version's blobs, says what they cost, and not its unpacked files" prune_keeps_blobs

# --- Going back -------------------------------------------------------------------
# Every source pointing at a port nothing listens on: going back mustn't need one.
offline() { sed -i "s|$registry/|localhost:1/|" "$(cygpath -u "$store_b\\refs\\$APP.json")" "$(cygpath -u "$(versions_file previous.json)")"; }
online() { sed -i "s|localhost:1/|$registry/|" "$(cygpath -u "$store_b\\refs\\$APP.json")" "$(cygpath -u "$(versions_file previous.json)")"; }
went_back() {
    local out
    offline
    out=$(zb rollback $APP </dev/null 2>&1) || { online; echo "$out"; return 1; }
    online
    grep -q "went back: $APP 2 -> 1 (" <<<"$out" || { echo "$out"; return 1; }
    [ "$(installed_version)" = 1 ] && runs_version 1
}
check "rollback goes back, with no network, and the command runs the version gone back to" went_back
after_back() { list_line | grep -q '(previous 2)' && list_line | grep -q '(skips 2)'; }
check "  list says what it went back from, and that updates skip it" after_back

check_skips() {
    local out err
    out=$(zb update --check 2>"$work\\err") || { cat "$work\\err"; return 1; }
    [ -z "$out" ] || { echo "stdout: $out"; return 1; }
    grep -q "$APP 1: skipping 2 (" "$work\\err" || { cat "$work\\err"; return 1; }
}
check "update --check lists nothing, and notes that it skips the version left" check_skips
update_stays() {
    local out
    out=$(zb update --yes 2>&1) || { echo "$out"; return 1; }
    grep -q "$APP 1: skipping 2 (" <<<"$out" && [ "$(installed_version)" = 1 ]
}
check "update stays where rollback went, and exits 0" update_stays
not_told() {
    [ -z "$(zb updates check --notify 2>/dev/null)" ] || return 1
    zb updates 2>/dev/null | grep -q 'Nothing is waiting'
}
check "the daily check tells nothing, and finds nothing waiting" not_told

there_and_back() {
    zb rollback $APP </dev/null >/dev/null 2>&1 || return 1
    [ "$(installed_version)" = 2 ] && list_line | grep -q '(skips 1)' || return 1
    zb rollback $APP </dev/null >/dev/null 2>&1 || return 1
    [ "$(installed_version)" = 1 ] && list_line | grep -q '(skips 2)'
}
check "a second rollback returns to where it was, and skips the other" there_and_back

publish 3 network
newer() {
    local out
    out=$(zb update --check 2>/dev/null) || return 1
    grep -q "$APP 1 -> 3 (" <<<"$out" || { echo "$out"; return 1; }
    zb update --yes >/dev/null 2>&1 || return 1
    [ "$(installed_version)" = 3 ] && runs_version 3 || return 1
    [ ! -e "$(versions_file skip.json)" ] && list_line | grep -q '(previous 1)' && ! list_line | grep -q skips
}
check "a newer version gets through, and the skip goes" newer

publish 4
zb update --yes >/dev/null 2>&1
asks() {
    local out
    [ "$(installed_version)" = 4 ] || { echo "at $(installed_version)"; return 1; }
    out=$(zb rollback $APP </dev/null 2>&1) && { echo "it exited 0"; return 1; }
    grep -q "^$APP 3 may reach more than 4:" <<<"$out" && grep -q 'permits *the network$' <<<"$out" || { echo "$out"; return 1; }
    grep -q "$APP stays at 4: nothing answered" <<<"$out" || { echo "$out"; return 1; }
    [ "$(installed_version)" = 4 ] && [ ! -e "$(versions_file skip.json)" ]
}
check "going back to a version that may reach more asks, and with no answer stays" asks
refused() {
    echo n | zb rollback $APP >/dev/null 2>&1 && return 1
    [ "$(installed_version)" = 4 ]
}
check "  and stays when told no" refused
agreed() { zb rollback --yes $APP >/dev/null 2>&1 && [ "$(installed_version)" = 3 ] && list_line | grep -q '(skips 4)'; }
check "  and goes back with --yes" agreed

# --- Holding -------------------------------------------------------------------
held() {
    local out
    out=$(zb hold $APP 2>&1) || { echo "$out"; return 1; }
    grep -q "held $APP at 3" <<<"$out" && list_line | grep -q '(held)' && [ -e "$(versions_file held)" ]
}
check "hold holds, and list says so" held
held_again() { zb hold $APP 2>&1 | grep -q 'was held already' && list_line | grep -q '(held)'; }
check "  holding again says it was" held_again
check "hold of an app that isn't installed fails" fails zb hold no.such.app
check "hold without an app is a usage error" fails zb hold

publish 5
held_check() {
    local out
    out=$(zb update --check 2>"$work\\err") || { cat "$work\\err"; return 1; }
    [ -z "$out" ] || { echo "stdout: $out"; return 1; }
    grep -q "$APP 3: held; \`zigsaw unhold $APP\` lets updates in" "$work\\err" || { cat "$work\\err"; return 1; }
}
check "update --check lists nothing for a held app, and says why" held_check
held_update() {
    zb update --yes >/dev/null 2>&1 || return 1
    zb update --yes $APP >/dev/null 2>&1 || return 1
    [ "$(installed_version)" = 3 ]
}
check "update leaves a held app alone, named or not, and exits 0" held_update
check "the daily check tells nothing about a held app" not_told
pull_held() {
    zb pull --yes "$repo:latest" >/dev/null 2>&1 || return 1
    [ "$(installed_version)" = 5 ] && list_line | grep -q '(held)'
}
check "pull of a held app installs, and the hold stays" pull_held
unheld() {
    local out
    out=$(zb unhold $APP 2>&1) || { echo "$out"; return 1; }
    grep -q "$APP 5: updates reach it again" <<<"$out" && ! list_line | grep -q held && [ ! -e "$(versions_file held)" ]
}
check "unhold lets updates in again" unheld
unheld_again() { zb unhold $APP 2>&1 | grep -q "wasn't held"; }
check "  unholding again says it wasn't held" unheld_again

publish 6
found_then_held() {
    zb updates check >/dev/null 2>&1
    zb updates 2>/dev/null | grep -q "$APP 5 -> 6 (" || { echo "the check found nothing"; return 1; }
    zb hold $APP >/dev/null 2>&1 || return 1
    zb updates 2>/dev/null | grep -q 'Nothing is waiting' && ! zb list 2>&1 | grep -q 'waiting'
}
check "what a check found isn't waiting once the app is held" found_then_held
unheld_updates() { zb unhold $APP >/dev/null 2>&1 && zb update --yes >/dev/null 2>&1 && [ "$(installed_version)" = 6 ] && runs_version 6; }
check "  and once it isn't, update installs it" unheld_updates

# --- When the previous version is gone -------------------------------------------
forget() {
    local out
    out=$(zb prune --previous 2>&1) || { echo "$out"; return 1; }
    grep -q 'forgot 1 previous version(s)' <<<"$out" || { echo "$out"; return 1; }
    [ ! -e "$(versions_file previous.json)" ] && ! list_line | grep -q previous || return 1
    out=$(zb rollback $APP </dev/null 2>&1) && return 1
    grep -q 'nothing to go back to' <<<"$out"
}
check "prune --previous forgets it, and rollback has nothing to go back to" forget

publish 7
zb update --yes >/dev/null 2>&1
blobs_gone() {
    local out manifest
    manifest=$(previous_manifest)
    # As a zigsaw before 0.76 prunes: the blobs go, and the file stays.
    rm -f "$store_b\\blobs\\sha256\\${manifest#sha256:}"
    out=$(zb rollback $APP </dev/null 2>&1) && return 1
    grep -q "the files of 6 (.*) are gone" <<<"$out" || { echo "$out"; return 1; }
    grep -qF "\`zigsaw pull $repo@$manifest\` brings it back" <<<"$out" || { echo "$out"; return 1; }
    zb prune >/dev/null 2>&1 && [ "$(installed_version)" = 7 ] && runs_version 7
}
check "a previous version whose blobs are gone: rollback says how to have it back, and prune copes" blobs_gone

# --- Built from a recipe ---------------------------------------------------------
# Store a built each version from the recipe, which is at 7.
recipe_skip() {
    local out
    za rollback $APP </dev/null >/dev/null 2>&1 || return 1
    out=$(za update --yes 2>&1) || { echo "$out"; return 1; }
    grep -q "$APP 6: skipping 7 (" <<<"$out" || { echo "$out"; return 1; }
    za list 2>/dev/null | tr -d '\r' | grep "^$APP " | awk '{ print $2 }' | grep -qx 6
}
check "an app built from a recipe goes back too, and a rebuild that makes the version left stays" recipe_skip

# --- Removing -----------------------------------------------------------------------
removed() {
    zb hold $APP >/dev/null 2>&1 && zb rm $APP >/dev/null 2>&1 || return 1
    [ -z "$(ls "$store_b\\versions")" ]
}
check "rm forgets what versions\\ had of the app" removed
strays() {
    : >"$store_b\\versions\\gone.app.held"
    : >"$store_b\\versions\\gone.app.skip.json"
    zb prune >/dev/null 2>&1 && [ -z "$(ls "$store_b\\versions")" ]
}
check "prune deletes what versions\\ has of apps that aren't installed" strays

# Installed apps' files aren't for deleting by hand.
for store in "$store_a" "$store_b"; do
    [ -e "$store" ] && ZIGSAW_HOME="$store" "$zigsaw" rm --delete-data $APP >/dev/null 2>&1
done
reg delete "HKCU\\$ZIGSAW_GRANTS_KEY" /f >/dev/null 2>&1
reg query 'HKCU\Software\ZigsawTest' 2>/dev/null | grep -q . || reg delete 'HKCU\Software\ZigsawTest' /f >/dev/null 2>&1
cd /
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
