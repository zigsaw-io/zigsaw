#!/usr/bin/env bash
# End-to-end checks for `zigsaw updates`: what a check finds and keeps, when it
# tells, and the scheduled task and zigsaw-notify.exe. Nothing here installs
# anything by itself, and the rows check that too. tests/install.sh has `upgrade`
# and what install.ps1 does.
#
#   tests/zot.sh bash tests/updates.sh [path\to\zigsaw.exe]
#
# The rows about what's waiting need a registry on localhost:5000; without one
# they're skipped, and the rest run, as for the standard user's job. Scheduled
# tasks are real ones, under a name of this run's own (ZIGSAW_TASK_NAME), and are
# removed at the end: the user's own task is never touched, which is checked. No
# notification is shown: ZIGSAW_NOTIFY_REPORT takes it. Takes seconds.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root\\zig-out\\bin\\zigsaw.exe}
notify="$(dirname "$zigsaw")\\zigsaw-notify.exe"
work=$(cygpath -wl "$(mktemp -d)")
mkdir -p "$work\\cwd" && cd "$work\\cwd" || exit 1

export ZIGSAW_TASK_NAME="ZigsawTest-updates-$$"
export ZIGSAW_GRANTS_KEY="Software\\ZigsawTest\\updates-$$"
export ZIGSAW_SHORTCUTS_DIR="$work\\links"
export ZIGSAW_USER_FOLDERS="$work\\folders"
export DOCKER_CONFIG="$work\\docker"
mkdir -p "$DOCKER_CONFIG" "$ZIGSAW_USER_FOLDERS"
# Whatever this machine has for real, it's to be the same afterwards.
sch="$(cygpath -u "$WINDIR")/System32/schtasks.exe"
# Its definition, not its status, which says when it last ran.
real_task() { "$sch" /query /tn "Zigsaw update check" /xml 2>&1 | tr -d '\r'; }
real_before=$(real_task)

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

store_a="$work\\a"
store_b="$work\\b"
za() { ZIGSAW_HOME="$store_a" "$zigsaw" "$@"; }
zb() { ZIGSAW_HOME="$store_b" "$zigsaw" "$@"; }

task_name_of() { # <store>: the name `updates on` gives it, from `grants`
    ZIGSAW_HOME="$1" "$zigsaw" grants | tr -d '\r' | grep -F "for $1" | sed -n 's/^  scheduled task "\(.*\)", for .*/\1/p'
}
has_task() { "$sch" /query /tn "$1" >/dev/null 2>&1; }

# --- What's waiting --------------------------------------------------------------
registry=localhost:5000
if curl -sf "http://127.0.0.1:5000/v2/" >/dev/null; then
    repo="$registry/zigsaw-updates-$RANDOM"
    recipe() { # <version> [network]
        local extra=
        [ "${2:-}" = network ] && extra=', "network": true'
        printf '{ "id": "test.updates.app", "version": "%s", "command": "app.cmd", "permissions": { "sandbox": "soft"%s }, "exports": {},\n  "modules": [{ "name": "scripts", "sources": [{ "path": "app.cmd" }] }] }\n' "$1" "$extra" >"$work\\app.json"
        printf '@echo version %s\r\n' "$1" >"$work\\app.cmd"
    }
    publish() { recipe "$@" && za build "$work\\app.json" >/dev/null 2>&1 && za push test.updates.app "$repo:latest" >/dev/null 2>&1; }
    installed_version() { zb list 2>/dev/null | tr -d '\r' | awk '$1 == "test.updates.app" { print $2 }'; }
    state="$store_b\\updates\\state.json"
    # As if the last notification were long ago: 1970, near enough.
    long_ago() { sed -i 's/"notified_at": [0-9]*/"notified_at": 1/' "$(cygpath -u "$state")"; }
    told() { [ -n "$(zb updates check --notify 2>/dev/null)" ]; }

    never_checked() { zb updates 2>&1 | grep -q 'Nothing has checked'; }
    check "before any check, it says so, reading nothing" never_checked

    publish 1 || { echo "publishing the fixture failed"; exit 1; }
    zb pull --yes "$repo:latest" >/dev/null 2>&1 || { echo "pulling the fixture failed"; exit 1; }

    nothing_new() {
        local out
        out=$(zb updates check 2>/dev/null) || { echo "$out"; return 1; }
        grep -q 'Nothing is waiting' <<<"$out"
    }
    check "with nothing new, a check finds nothing, and exits 0" nothing_new
    nothing_listed() { ! zb list 2>&1 | grep -q 'waiting'; }
    check "  and list has no line about it" nothing_listed

    check "version 2 goes out under the same tag" publish 2
    finds_new() {
        local before out
        before=$(ls "$store_b\\blobs\\sha256")
        out=$(zb updates check 2>/dev/null) || { echo "$out"; return 1; }
        grep -q 'test.updates.app 1 -> 2 (' <<<"$out" || { echo "$out"; return 1; }
        # Its new config, and no layer.
        [ "$(comm -13 <(echo "$before") <(ls "$store_b\\blobs\\sha256") | wc -l)" = 1 ] || { echo "it fetched more than the config"; return 1; }
        [ "$(installed_version)" = 1 ] || { echo "it installed something"; return 1; }
    }
    check "a check finds it, fetching no layer and installing nothing" finds_new
    list_says() { zb list 2>&1 | grep -q '1 update waiting: `zigsaw updates` lists it'; }
    check "  list has one line about it" list_says

    tells() {
        local out
        out=$(zb updates check --notify 2>/dev/null) || { echo "$out"; return 1; }
        [ "$(wc -l <<<"$out")" = 2 ] || { echo "$out"; return 1; }
        grep -q '^zigsaw: 1 update waiting$' <<<"$out" && grep -q '^test.updates.app 1 to 2\. Click to see' <<<"$out" && grep -q 'nothing gets installed' <<<"$out"
    }
    check "the check the task runs tells, in a title and a text" tells
    check "  and not again the next day" fails told
    reminds() { long_ago && told; }
    check "  but again after some days: a banner that's missed leaves nothing" reminds
    check "  and not the day after that" fails told
    looks() { zb updates 2>/dev/null | grep -q 'test.updates.app 1 -> 2 (' && long_ago; }
    check "zigsaw updates lists it" looks
    check "  having looked, it isn't told again, however long it's been" fails told

    check "version 3, which asks for the network, goes out" publish 3 network
    check "something new is told at once, though the last was looked at" told
    says_access() { zb updates 2>/dev/null | tr -d '\r' | grep -A1 'test.updates.app 1 -> 3 (' | grep -q 'permits.*network'; }
    check "  and what it may reach beyond the installed one is listed" says_access

    quiet() {
        publish 4 network || return 1
        [ -z "$(zb updates check --quiet 2>/dev/null)" ] && grep -q '"to": "4"' "$state" || return 1
        # While Windows holds notifications back: not told yet, so told next.
        told
    }
    check "--quiet, while Windows holds notifications back, keeps what it found and doesn't count as telling" quiet

    # Only ever `update` installs it.
    [ "$(installed_version)" = 1 ]
    check "after all that, nothing was installed" test $? -eq 0
    updated() {
        zb update --yes test.updates.app >/dev/null 2>&1 || return 1
        [ "$(installed_version)" = 4 ] || return 1
        zb updates 2>/dev/null | grep -q 'Nothing is waiting' && ! zb list 2>&1 | grep -q waiting
    }
    check "once updated, nothing's waiting, without another check" updated

    pinned_or_built() {
        local out manifest
        manifest=$(grep -o 'sha256:[0-9a-f]*' "$store_b\\refs\\test.updates.app.json" | head -1)
        ZIGSAW_HOME="$work\\pinned" "$zigsaw" pull --yes "$repo@$manifest" >/dev/null 2>&1 || return 1
        publish 5 network || return 1
        # A digest, and a recipe: neither can be told anything by a tag.
        out=$(ZIGSAW_HOME="$work\\pinned" "$zigsaw" updates check 2>/dev/null) || { echo "$out"; return 1; }
        grep -q 'Nothing is waiting' <<<"$out" || { echo "$out"; return 1; }
        out=$(za updates check 2>/dev/null) || { echo "$out"; return 1; }
        grep -q 'Nothing is waiting' <<<"$out" || { echo "$out"; return 1; }
    }
    check "an app pulled by digest, and one built from a recipe, aren't waiting for anything" pinned_or_built

    # A registry that's gone: the app can't be checked, and what was found stays.
    offline() {
        local out ref="$store_b\\refs\\test.updates.app.json"
        zb updates check --notify >/dev/null 2>&1
        sed -i "s|$registry/|localhost:1/|" "$(cygpath -u "$ref")"
        out=$(zb updates check --notify 2>/dev/null) && { echo "it exited 0"; return 1; }
        [ -z "$out" ] || { echo "it told: $out"; return 1; }
        out=$(zb updates 2>/dev/null)
        grep -q 'test.updates.app 4 -> 5 (' <<<"$out" || { echo "$out"; return 1; }
        grep -q "Couldn't check test.updates.app" <<<"$out" || { echo "$out"; return 1; }
        sed -i "s|localhost:1/|$registry/|" "$(cygpath -u "$ref")"
    }
    check "without its registry: exit 1, nothing told, what was found stays, and it says what it couldn't check" offline

    # zigsaw itself, from a release's files in a directory.
    release="$work\\release"
    mkdir -p "$release"
    newer_zigsaw() {
        local out
        printf '999.0.0\n' >"$release\\VERSION"
        out=$(ZIGSAW_UPGRADE_FROM="$release" zb updates check --notify 2>/dev/null) || { echo "$out"; return 1; }
        grep -q 'updates waiting$' <<<"$out" || { echo "$out"; return 1; }
        ZIGSAW_UPGRADE_FROM="$release" zb updates 2>/dev/null | grep -q 'zigsaw 999.0.0 is out; this is .* `zigsaw upgrade` installs it'
    }
    check "a newer zigsaw is waiting too, and installed by another command" newer_zigsaw
    same_zigsaw() {
        "$zigsaw" version | tr -d '\r' | cut -d' ' -f2 >"$release\\VERSION"
        ZIGSAW_UPGRADE_FROM="$release" zb updates check >/dev/null 2>&1
        ! ZIGSAW_UPGRADE_FROM="$release" zb updates 2>/dev/null | grep -q ' is out'
    }
    check "  the same zigsaw isn't" same_zigsaw
    no_release() {
        local out
        out=$(ZIGSAW_UPGRADE_FROM="$work\\nowhere" zb updates check 2>/dev/null) && { echo "it exited 0"; return 1; }
        grep -q "Couldn't find out zigsaw's latest version" <<<"$out"
    }
    check "  and not finding out is said, and isn't a failure of anything else" no_release
    elsewhere() {
        printf '999.0.0\n' >"$release\\VERSION"
        ZIGSAW_UPGRADE_FROM="$release" zb updates check >/dev/null 2>&1
        ! zb updates check 2>/dev/null | grep -q ' is out'
    }
    check "  a build outside its store's bin doesn't ask, so no test or dev build reaches GitHub" elsewhere

    # zigsaw-notify.exe, which the task starts, with what it would show in a file.
    report="$work\\report.txt"
    notifies() {
        rm -f "$report"
        publish 6 network || return 1
        env -u ZIGSAW_HOME ZIGSAW_NOTIFY_REPORT="$report" "$notify" --store "$store_b" --task "$ZIGSAW_TASK_NAME-unused" || return 1
        grep -q '^zigsaw: 1 update waiting$' "$report" && grep -q '^test.updates.app 4 to 6\.' "$report"
    }
    check "zigsaw-notify has zigsaw check the store it's told, and shows what it says" notifies
    notifies_once() {
        rm -f "$report"
        ZIGSAW_NOTIFY_REPORT="$report" "$notify" --store "$store_b" --task "$ZIGSAW_TASK_NAME-unused" || return 1
        [ ! -e "$report" ]
    }
    check "  and shows nothing when nothing's due" notifies_once
else
    printf 'note  no registry on %s: the rows about what is waiting are skipped\n' "$registry"
fi

# --- The scheduled task ----------------------------------------------------------
store_c="$work\\c"
zc() { ZIGSAW_HOME="$store_c" "$zigsaw" "$@"; }
turns_on() {
    local out name xml
    out=$(zc updates on 2>&1) || { echo "$out"; return 1; }
    grep -q 'the daily check is on: .* installs nothing' <<<"$out" || { echo "$out"; return 1; }
    name=$(task_name_of "$store_c")
    [ -n "$name" ] && has_task "$name" || { echo "no task: '$name'"; return 1; }
    xml=$("$sch" /query /tn "$name" /xml | tr -d '\r')
    grep -qF "<Command>$notify</Command>" <<<"$xml" || { echo "$xml"; return 1; }
    grep -qF -- "--store $store_c" <<<"$xml" || { echo "$xml"; return 1; }
    # Windows leaves out the run level when it's the least, the default.
    ! grep -q 'HighestAvailable' <<<"$xml" || { echo "it asks for more rights"; return 1; }
    grep -q '<LogonType>InteractiveToken</LogonType>' <<<"$xml" &&
        grep -q '<StartWhenAvailable>true</StartWhenAvailable>' <<<"$xml" && grep -q '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>' <<<"$xml" &&
        grep -q '<RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>' <<<"$xml" || { echo "$xml"; return 1; }
}
check "updates on adds a task for this store, as the user, with no more rights" turns_on
says_on() { zc updates 2>/dev/null | grep -q 'A daily check is on; it installs nothing'; }
check "  zigsaw updates says it's on" says_on
is_listed() { zc grants 2>/dev/null | grep -qF "for $store_c"; }
check "  zigsaw grants lists it, as something changed outside the store" is_listed
# The real thing, where it can be: the task only runs while its user has a desktop,
# which a test as another account, and maybe a runner, hasn't.
has_desktop() { tasklist /FI "IMAGENAME eq explorer.exe" /FI "USERNAME eq $USERNAME" /NH 2>/dev/null | grep -qi '^explorer'; }
runs_by_itself() {
    local name
    has_desktop || { printf 'note  no desktop for %s here, so the task was not started\n' "$USERNAME" >&2; return 0; }
    name=$(task_name_of "$store_c")
    rm -f "$store_c\\updates\\state.json"
    "$sch" /run /tn "$name" >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [ -s "$store_c\\updates\\state.json" ] && return 0
        sleep 1
    done
    echo "the task didn't run"
    return 1
}
check "  run as Windows runs it, it checks, with nothing to tell" runs_by_itself
turns_off() {
    local name
    name=$(task_name_of "$store_c")
    zc updates off >/dev/null 2>&1 || return 1
    ! has_task "$name" && [ -f "$store_c\\updates\\off" ] && zc updates 2>/dev/null | grep -q 'No daily check is on'
}
check "updates off removes it, and remembers" turns_off
off_stays_off() {
    zc updates on --unless-off >/dev/null 2>&1 || return 1
    [ -z "$(task_name_of "$store_c")" ]
}
check "  so what an install runs leaves it off" off_stays_off
off_twice() { zc updates off >/dev/null 2>&1; }
check "  and off when it's off already is fine" off_twice
on_again() {
    zc updates on >/dev/null 2>&1 || return 1
    [ -n "$(task_name_of "$store_c")" ] && [ ! -e "$store_c\\updates\\off" ]
}
check "updates on, asked for, starts it again" on_again
zc updates off >/dev/null 2>&1

no_notify() {
    local out dir="$work\\alone"
    mkdir -p "$dir"
    cp "$zigsaw" "$dir\\zigsaw.exe"
    out=$(ZIGSAW_HOME="$work\\d" "$dir\\zigsaw.exe" updates on 2>&1) && { echo "it worked"; return 1; }
    grep -q "isn't next to zigsaw" <<<"$out"
}
check "without zigsaw-notify next to it, updates on says so" no_notify

# A store deleted by hand leaves its task behind, for repair, or for itself.
store_gone="$work\\gone"
gone_repair() {
    local name out
    ZIGSAW_HOME="$store_gone" "$zigsaw" updates on >/dev/null 2>&1 || return 1
    name=$(task_name_of "$store_gone")
    [ -n "$name" ] || return 1
    rm -rf "$store_gone"
    zc grants 2>/dev/null | grep -F "$store_gone" | grep -q 'since deleted' || { echo "grants doesn't say"; return 1; }
    out=$(zc repair 2>&1)
    grep -qF "as its store $store_gone is gone" <<<"$out" || { echo "$out"; return 1; }
    ! has_task "$name"
}
check "repair, from any store, removes the task of a store since deleted" gone_repair
gone_self() {
    local name
    ZIGSAW_HOME="$store_gone" "$zigsaw" updates on >/dev/null 2>&1 || return 1
    name=$(task_name_of "$store_gone")
    [ -n "$name" ] || return 1
    rm -rf "$store_gone"
    ZIGSAW_NOTIFY_REPORT="$work\\never" "$notify" --store "$store_gone" --task "$name"
    ! has_task "$name" && [ ! -e "$work\\never" ] && [ ! -e "$store_gone" ]
}
check "a task whose store has gone removes itself when it runs" gone_self
repairs_own() {
    local name
    mkdir -p "$store_c" && rm -f "$store_c\\updates\\off"
    # From elsewhere than the store's bin: not its to take over.
    zc updates on >/dev/null 2>&1 || return 1
    name=$(task_name_of "$store_c")
    "$sch" /delete /tn "$name" /f >/dev/null 2>&1
    zc repair >/dev/null 2>&1
    ! has_task "$name"
}
check "repair by a zigsaw outside the store's bin leaves the task alone" repairs_own

no_leftovers() { [ -z "$("$sch" /query /fo csv /nh 2>/dev/null | grep -F "\\$ZIGSAW_TASK_NAME")" ]; }
check "no task of this run is left" no_leftovers
real_same() { [ "$real_before" = "$(real_task)" ]; }
check "the real task, if this machine has one, is as it was" real_same

# Should a row have failed halfway.
"$sch" /query /fo csv /nh 2>/dev/null | tr -d '\r' | grep -F "\"\\$ZIGSAW_TASK_NAME" | cut -d'"' -f2 |
    while IFS= read -r t; do "$sch" /delete /tn "$t" /f >/dev/null 2>&1; done
# Installed apps' files aren't for deleting by hand.
for store in "$store_a" "$store_b" "$work\\pinned"; do
    [ -e "$store" ] && ZIGSAW_HOME="$store" "$zigsaw" rm --delete-data test.updates.app >/dev/null 2>&1
done
reg delete "HKCU\\$ZIGSAW_GRANTS_KEY" /f >/dev/null 2>&1
reg query 'HKCU\Software\ZigsawTest' 2>/dev/null | grep -q . || reg delete 'HKCU\Software\ZigsawTest' /f >/dev/null 2>&1
cd /
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
