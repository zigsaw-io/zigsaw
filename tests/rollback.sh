#!/usr/bin/env bash
# End-to-end checks for going back: the version an update replaces is kept,
# `zigsaw rollback` returns to it without the network and has updates pass over
# the version it left, and `zigsaw hold` keeps updates away. Store a builds a
# small app from a recipe and pushes each version under one tag; store b pulls
# it, as anyone would. Then the app's data: an install over a version keeps a
# copy of it, which a rollback takes back if told to, in a store of its own.
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

# --- Data ----------------------------------------------------------------------------
# An app whose every version reads only the data it wrote itself, as a
# database server does across major versions: a file in its home, and a
# registry key it keeps. Built in a store of its own, each version over the
# one before.
DATA=test.rollback.data
KEY="Software\\ZigsawTest\\rollback-data-$$"
store_d="$work\\d"
zd() { ZIGSAW_HOME="$store_d" "$zigsaw" "$@"; }
data_recipe() { # <version>
    printf '{ "id": "%s", "version": "%s", "command": "data.cmd", "permissions": { "sandbox": "soft" },\n  "registry": ["%s"],\n  "exports": { "rbdata": { "command": "data.cmd" } },\n  "modules": [{ "name": "scripts", "sources": [{ "path": "data.cmd" }] }] }\n' "$DATA" "$1" "${KEY//\\/\\\\}" >"$work\\data.json"
    sed "s/@V@/$1/g; s/@KEY@/${KEY//\\/\\\\}/g; s/\$/\r/" >"$work\\data.cmd" <<'EOF'
@echo off
if "%1"=="write" goto write
if "%1"=="hold" goto hold
findstr /b /c:"format @V@ " "%USERPROFILE%\state.txt" >nul 2>nul
if errorlevel 1 goto unreadable
type "%USERPROFILE%\state.txt"
reg query "HKCU\@KEY@" /v state 2>nul | findstr state
exit /b 0
:unreadable
echo version @V@ cannot read this data
exit /b 3
:write
>"%USERPROFILE%\state.txt" echo format @V@ %2
reg add "HKCU\@KEY@" /v state /d "key @V@ %2" /f >nul
exit /b 0
:hold
>"%USERPROFILE%\held" echo held
:wait
if exist "%USERPROFILE%\stop" exit /b 0
ping -n 2 127.0.0.1 >nul
goto wait
EOF
}
data_build() { data_recipe "$1" && zd build "$work\\data.json" 2>&1; }
rbdata() { "$store_d\\bin\\rbdata.exe" "$@" 2>&1 | tr -d '\r'; return "${PIPESTATUS[0]}"; }
# What a run of the installed version reads: its file's line and its key's.
reads() { # <version> <word>
    local out
    out=$(rbdata read) || { echo "$out"; return 1; }
    grep -qx "format $1 $2" <<<"$out" && grep -q "key $1 $2" <<<"$out" || { echo "$out"; return 1; }
}
cannot_read() { # <version>
    local out
    out=$(rbdata read) && { echo "it read: $out"; return 1; }
    grep -q "version $1 cannot read this data" <<<"$out" || { echo "$out"; return 1; }
}
data_line() { zd list 2>/dev/null | tr -d '\r' | grep "^$DATA "; }
data_version() { data_line | awk '{ print $2 }'; }
live="$store_d\\volumes\\$DATA"
copy="$store_d\\snapshots\\$DATA"
record="$store_d\\versions\\$DATA.data.json"
# Where a swap has the app's data between its renames: no app's id starts with a dot.
aside="$store_d\\snapshots\\.swap-$DATA"
# The file as the copy has it: "format <version> <word>".
copy_has() { [ "$(tr -d '\r' <"$copy\\home\\state.txt" 2>/dev/null)" = "format $1 $2" ] || { echo "the copy has: $(cat "$copy\\home\\state.txt" 2>&1)"; return 1; }; }
record_names() { grep -q "\"version\": \"$1\"" "$record" || { echo "the record: $(cat "$record" 2>&1)"; return 1; }; }

data_build 1 >/dev/null || { echo "building the data fixture failed"; exit 1; }
rbdata write one >/dev/null
first_install() { reads 1 one && [ ! -e "$copy" ] && [ ! -e "$record" ] && ! data_line | grep -q 'with data'; }
check "a first install has data, and no copy of it" first_install

copied() {
    local out
    out=$(data_build 2) || { echo "$out"; return 1; }
    grep -q '  kept     its data as 1 left it (.* in [0-9]* file(s), copied in .*), for `zigsaw rollback`' <<<"$out" || { echo "$out"; return 1; }
    copy_has 1 one && record_names 1 || return 1
    [ -f "$copy\\registry\\user.dat" ] || { echo "the copy has no hive"; return 1; }
    [ ! -e "$copy\\home\\AppData\\Local\\Temp" ] || { echo "the copy has Temp"; return 1; }
    data_line | grep -q '(previous 1, with data)' || { data_line; return 1; }
    [ -z "$(ls "$store_d\\tmp" | grep snapshot)" ] || { echo "a copy is left in tmp"; return 1; }
}
check "an install over a version copies the data as that one left it, hive included, Temp left out; list says so" copied
rbdata write two >/dev/null
check "  the new version reads what it wrote, and the copy stays as the old one left it" eval 'reads 2 two && copy_has 1 one'
prune_keeps_data() {
    local out
    out=$(zd prune 2>&1) || { echo "$out"; return 1; }
    grep -q 'kept the data of 1 app(s) as an earlier version left it (.*) for `zigsaw rollback`; --previous deletes it' <<<"$out" || { echo "$out"; return 1; }
    copy_has 1 one
}
check "prune keeps the copy, and says what it costs" prune_keeps_data

data_stays() {
    local out
    out=$(zd rollback $DATA </dev/null 2>&1) || { echo "$out"; return 1; }
    grep -q "$DATA's data as 1 left it .* is kept" <<<"$out" && grep -q 'Take its data back too? \[y/N\]' <<<"$out" || { echo "$out"; return 1; }
    grep -q 'nothing answered: its data stays' <<<"$out" && grep -q "rollback --data-only $DATA" <<<"$out" || { echo "$out"; return 1; }
    [ "$(data_version)" = 1 ] && cannot_read 1 && copy_has 1 one && record_names 1
}
check "rollback asks about the data; with nothing answered it goes back and the data stays, which the old version can't read" data_stays
data_only() {
    local out
    out=$(zd rollback --data-only $DATA 2>&1) || { echo "$out"; return 1; }
    grep -q "$DATA 1: its data is back to how this version left it" <<<"$out" || { echo "$out"; return 1; }
    [ "$(data_version)" = 1 ] && reads 1 one && copy_has 2 two && record_names 2 || return 1
    grep -q '"set_aside": true' "$record" && data_line | grep -q '(previous 2, with data)'
}
check "rollback --data-only takes the data back, key included, and sets the newer data aside" data_only
check "  again, it has none of the installed version's to take" fails zd rollback --data-only $DATA
with_data() {
    local out
    out=$(zd rollback --data $DATA </dev/null 2>&1) || { echo "$out"; return 1; }
    grep -q 'its data went back too, to how 2 left it' <<<"$out" || { echo "$out"; return 1; }
    [ "$(data_version)" = 2 ] && reads 2 two && copy_has 1 one && record_names 1
}
check "rollback --data returns to the version left, with its data, without asking" with_data
answered() {
    local out
    out=$(echo y | zd rollback $DATA 2>&1) || { echo "$out"; return 1; }
    [ "$(data_version)" = 1 ] && reads 1 one && copy_has 2 two || { echo "$out"; return 1; }
    out=$(echo n | zd rollback $DATA 2>&1) || { echo "$out"; return 1; }
    [ "$(data_version)" = 2 ] && cannot_read 2 && copy_has 2 two || { echo "$out"; return 1; }
    zd rollback --data-only $DATA >/dev/null 2>&1 && reads 2 two && copy_has 1 one
}
check "answered y the data goes back, answered n it stays, and --data-only still takes it" answered
kept_data() {
    local out
    out=$(printf '\n' | zd rollback $DATA 2>&1) || { echo "$out"; return 1; }
    [ "$(data_version)" = 1 ] && cannot_read 1 && copy_has 1 one || { echo "$out"; return 1; }
    out=$(zd rollback --keep-data $DATA </dev/null 2>&1) || { echo "$out"; return 1; }
    ! grep -q 'Take its data back' <<<"$out" && [ "$(data_version)" = 2 ] && reads 2 two || { echo "$out"; return 1; }
}
check "an empty answer leaves the data; --keep-data leaves it without asking" kept_data
check "--data and --keep-data together are refused" fails zd rollback --data --keep-data $DATA

# While a run of the app goes on.
hold_start() { ZIGSAW_HOME="$store_d" "$zigsaw" run $DATA hold >/dev/null 2>&1 & hold_pid=$!; local n=0; until [ -e "$live\\home\\held" ] || [ $((n += 1)) -gt 50 ]; do sleep 0.2; done; [ -e "$live\\home\\held" ]; }
hold_end() { : >"$live\\home\\stop"; wait "$hold_pid"; rm -f "$live\\home\\stop" "$live\\home\\held"; }
# Going forward again kept the data as 1 left it, which was 2's by then.
hold_start || echo "the held run didn't start"
while_running() {
    local out
    [ "$(data_version)" = 2 ] || { echo "at $(data_version)"; return 1; }
    out=$(zd rollback --data $DATA 2>&1) && { echo "it exited 0"; return 1; }
    grep -q "$DATA stays at 2: a run of it goes on" <<<"$out" && [ "$(data_version)" = 2 ] || { echo "$out"; return 1; }
    out=$(zd rollback --data-only $DATA 2>&1) && { echo "it exited 0"; return 1; }
    [ "$(data_version)" = 2 ] && copy_has 2 two && record_names 1 && [ "$(tr -d '\r' <"$live\\home\\state.txt")" = "format 2 two" ]
}
check "while the app runs, its data doesn't go back: --data and --data-only refuse, and nothing changes" while_running
owed() {
    local out
    out=$(data_build 3) || { echo "$out"; return 1; }
    grep -q "a run of $DATA goes on: its next run copies its data as 2 left it first" <<<"$out" || { echo "$out"; return 1; }
    [ -e "$store_d\\versions\\$DATA.data-owed.json" ] && [ ! -e "$copy" ] && [ ! -e "$record" ]
}
check "an install while the app runs owes the copy, and drops the one before" owed
hold_end
owed_taken() {
    local out
    out=$(rbdata read) && { echo "version 3 read: $out"; return 1; }
    grep -q "kept $DATA's data as 2 left it (" <<<"$out" || { echo "$out"; return 1; }
    [ ! -e "$store_d\\versions\\$DATA.data-owed.json" ] && copy_has 2 two && record_names 2 && data_line | grep -q '(previous 2, with data)'
}
check "  the app's next run takes it before it starts" owed_taken

# A swap that zigsaw didn't finish: the data set aside, and nothing in its place.
rbdata write three >/dev/null
stopped_early() {
    local out
    mv "$(cygpath -u "$live")" "$(cygpath -u "$aside")" || return 1
    out=$(rbdata read) || { echo "$out"; return 1; }
    grep -q "put $DATA's data back" <<<"$out" && [ ! -e "$aside" ] && reads 3 three && copy_has 2 two
}
check "a swap stopped after its first step: the app's next run puts its data back" stopped_early
stopped_late() {
    mv "$(cygpath -u "$live")" "$(cygpath -u "$aside")" && mv "$(cygpath -u "$copy")" "$(cygpath -u "$live")" && rm -f "$record" || return 1
    rbdata read >/dev/null
    [ ! -e "$aside" ] && copy_has 3 three && record_names 2 && grep -q '"set_aside": true' "$record" || return 1
    # As the swap would have left it: the data of 2, with 3's set aside as 2's... put right again.
    rm -rf "$(cygpath -u "$live")" && mv "$(cygpath -u "$copy")" "$(cygpath -u "$live")" && rm -f "$record" && reads 3 three
}
check "  stopped after its second: the data set aside becomes what's kept" stopped_late

# A volume the app mounts isn't its own, and isn't copied; nor is it lost.
zd override --volume=rbvol:mounted $DATA >/dev/null 2>&1
rbdata write three >/dev/null
echo shared >"$store_d\\volumes\\rbvol\\shared.txt"
mounted() {
    local out
    out=$(data_build 4) || { echo "$out"; return 1; }
    copy_has 3 three && [ ! -e "$copy\\mounted" ] || { echo "the copy has the mount"; return 1; }
    rbdata write four >/dev/null
    zd rollback --data $DATA >/dev/null 2>&1 && reads 3 three || return 1
    [ "$(cat "$live\\mounted\\shared.txt" 2>&1)" = shared ] && [ "$(cat "$store_d\\volumes\\rbvol\\shared.txt")" = shared ]
}
check "a mounted volume is left out of the copy, and is mounted again in the data taken back" mounted
zd override --reset $DATA >/dev/null 2>&1

low_writes() {
    zd run --sandbox=low $DATA write low >/dev/null 2>&1 || { zd run --sandbox=low $DATA write low 2>&1 | tail -3; return 1; }
    [ "$(tr -d '\r' <"$live\\home\\state.txt")" = "format 3 low" ]
}
check "the data taken back is the app's to write under the low sandbox too" low_writes

# Turned off for the app.
opted_out() {
    local out
    zd override --nosnapshot $DATA 2>&1 | grep -q -- '--nosnapshot' || return 1
    out=$(data_build 5) || { echo "$out"; return 1; }
    ! grep -q 'kept     its data' <<<"$out" && [ ! -e "$copy" ] && [ ! -e "$record" ] || { echo "$out"; return 1; }
    data_line | grep -q '(previous 3)' || { data_line; return 1; }
    out=$(zd rollback --data $DATA 2>&1) && { echo "it exited 0"; return 1; }
    grep -q 'none of its data is kept as 3 left it' <<<"$out" && [ "$(data_version)" = 5 ]
}
check "override --nosnapshot: an install keeps no copy, drops the one before, and rollback --data says so" opted_out
opted_in() {
    zd override --snapshot $DATA >/dev/null 2>&1 && zd override --reset $DATA >/dev/null 2>&1 || return 1
    rbdata write five >/dev/null
    data_build 6 | grep -q 'kept     its data as 5 left it' && copy_has 5 five
}
check "  and without it, the next install keeps one again" opted_in

# A copy nothing vouches for: an older zigsaw updated the app since.
stale() {
    local out
    sed -i 's/"manifest": "sha256:[0-9a-f]*"/"manifest": "sha256:0000"/' "$(cygpath -u "$record")"
    ! data_line | grep -q 'with data' || { data_line; return 1; }
    out=$(zd rollback $DATA </dev/null 2>&1) || { echo "$out"; return 1; }
    ! grep -q 'Take its data back' <<<"$out" && grep -q 'its data stays as 6 left it: none is kept as 5 left it' <<<"$out" || { echo "$out"; return 1; }
    # And as any install, it kept the data as the version left had it.
    [ "$(data_version)" = 5 ] && record_names 6
}
check "a copy whose record names another version isn't offered, and the rollback keeps one of its own" stale

forgotten() {
    local out
    out=$(zd prune --previous 2>&1) || { echo "$out"; return 1; }
    grep -q "1 copy of an app's data (" <<<"$out" || { echo "$out"; return 1; }
    [ ! -e "$copy" ] && [ ! -e "$record" ]
}
check "prune --previous deletes the copy with the version" forgotten
data_removed() {
    local out
    data_build 7 >/dev/null && [ -e "$copy" ] || return 1
    mkdir -p "$store_d\\snapshots\\gone.app" && echo x >"$store_d\\snapshots\\gone.app\\f.txt"
    out=$(zd rm $DATA 2>&1) || { echo "$out"; return 1; }
    grep -q 'deleted its data as 5 left it (.*), kept for `zigsaw rollback`' <<<"$out" || { echo "$out"; return 1; }
    [ ! -e "$copy" ] && [ ! -e "$record" ] && [ -e "$live\\home\\state.txt" ] || return 1
    # Not a swap's folder, though: that's an app's data on its way.
    mkdir -p "$store_d\\snapshots\\.swap-gone.app" && echo x >"$store_d\\snapshots\\.swap-gone.app\\f.txt"
    zd prune >/dev/null 2>&1 && [ "$(ls -A "$store_d\\snapshots")" = .swap-gone.app ] || { ls -A "$store_d\\snapshots"; return 1; }
    rm -rf "$(cygpath -u "$store_d\\snapshots\\.swap-gone.app")"
}
check "rm deletes the copy and leaves the data; prune deletes copies no installed app has, and not a swap's folder" data_removed
zd volume rm rbvol >/dev/null 2>&1
zd prune --volumes >/dev/null 2>&1
reg delete "HKCU\\$KEY" /f >/dev/null 2>&1

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
