#!/usr/bin/env bash
# End-to-end checks for what the enforcing sandboxes change on the host, and
# what `zigsaw rm` undoes: low integrity labels on the paths a --sandbox=low
# run may write, access granted to an app's AppContainer, and what each lets
# a run write. Two busybox apps; tests/matrix.sh runs real tools.
#
#   tests/sandbox.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and network access (for the busybox download, unless
# SEED_DOWNLOADS has it). Always uses a temporary store, and removes it, and
# the AppContainer profiles it made, afterwards.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
# SEED_DOWNLOADS: another store's cache\downloads, whose files are linked, or
# copied, into this one's, so as not to download them again.
if [ -n "${SEED_DOWNLOADS:-}" ]; then
    mkdir -p "$ZIGSAW_HOME\\cache\\downloads"
    cp -l "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/" 2>/dev/null ||
        cp -n "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/"
fi

BB=net.frippery.busybox
OTHER=test.sandbox.other

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

z() { "$zigsaw" "$@" </dev/null; }
# writes <app> <sandbox> <file> [run options...]: whether a run can create the file.
writes() {
    local app=$1 sb=$2 file=$3
    shift 3
    z run --sandbox="$sb" "$@" "$app" sh -c "echo x > '$file'"
}
# What icacls says about a path's integrity label, and its ACEs for
# AppContainer packages (S-1-15-2-) and capabilities (S-1-15-3-).
label_of() { icacls "$1" | grep -o 'Mandatory Label\\[A-Za-z]* Mandatory Level:([A-Z()]*)'; }
low_label() { label_of "$1" | grep -q 'Low Mandatory Level:(OI)(CI)(NW)'; }
no_label() { ! label_of "$1"; }
has_ace() { icacls "$1" | grep -q "$2"; }
granted() { grep -qxF "$2" "$ZIGSAW_HOME\\grants\\$1.txt" 2>/dev/null; }

"$zigsaw" build "$root/recipes/busybox.json" >/dev/null 2>&1 || { echo "building busybox failed"; exit 1; }
sed "s/\"net.frippery.busybox\"/\"$OTHER\"/" "$root/recipes/busybox.json" >"$work\\other.json"
"$zigsaw" build "$work\\other.json" >/dev/null 2>&1 || { echo "building the second app failed"; exit 1; }

mkdir -p "$work\\rw" "$work\\ro" "$work\\outside" "$work\\cwd" "$work\\ac" "$work\\mine"
echo secret >"$work\\outside\\secret.txt"

# --- What a low run can write ------------------------------------------------

check "low: writes its data directory" z run --sandbox=low $BB sh -c 'echo x > "$APPDATA/f"'
check "low: writes a path it may write" writes $BB low "$work\\rw\\f" --filesystem="$work\\rw"
check "  which is labelled low, for everything in it" low_label "$work\\rw"
check "  and recorded for rm" granted $BB "low $work\\rw"
check "  what it wrote inherits the label" sh -c "icacls '$work\\rw\\f' | grep -q 'Low Mandatory Level:(I)(NW)'"
check "low: can't write a read-only grant" fails writes $BB low "$work\\ro\\f" --filesystem="$work\\ro:ro"
check "  which isn't labelled" no_label "$work\\ro"
check "low: can't write elsewhere" fails writes $BB low "$work\\outside\\f"
check "low: reads elsewhere (not enforced)" z run --sandbox=low $BB cat "$work\\outside\\secret.txt"
check "low: writes cwd with the cwd permission" sh -c "cd '$work\\cwd' && \"\$0\" run --sandbox=low --filesystem=cwd $BB sh -c 'echo x > \"\$1\"' sh '$work\\cwd\\f' </dev/null" "$zigsaw"
check "  and the run's data directory is labelled" low_label "$ZIGSAW_HOME\\data\\$BB"
refuses_profile() {
    local out
    out=$(writes $BB low "$USERPROFILE\\zigsaw-sandbox-test" --filesystem="$USERPROFILE" 2>&1) && return 1
    grep -q "it's your user profile" <<<"$out" || { echo "$out"; return 1; }
    [ ! -e "$USERPROFILE\\zigsaw-sandbox-test" ] && no_label "$USERPROFILE"
}
check "low: won't label the user profile" refuses_profile
check "low: --ephemeral writes its own data directory" z run --sandbox=low --ephemeral $BB sh -c 'echo x > "$APPDATA/f"'

# --- AppContainer grants, and a low run after one ------------------------------

check "appcontainer: writes a granted path" writes $BB appcontainer "$work\\ac\\f" --filesystem="$work\\ac"
check "  granted to the app's capability, not its package SID" sh -c "icacls '$work\\ac' | grep -q 'S-1-15-3-1024-' && ! icacls '$work\\ac' | grep -q 'S-1-15-2-'"
check "  and recorded for rm" granted $BB "$work\\ac"
check "low after appcontainer: runs, and reads what that run wrote" z run --sandbox=low --filesystem="$work\\ac" $BB cat "$work\\ac\\f"
check "appcontainer: can't write elsewhere" fails writes $BB appcontainer "$work\\outside\\f"

# --- Labels two apps share, labels zigsaw didn't make, and rm ---------------------

check "a second app's low run writes the same path" writes $OTHER low "$work\\rw\\g" --filesystem="$work\\rw"
check "  and shares the label, recorded for both" granted $OTHER "low $work\\rw"
icacls "$work\\mine" /setintegritylevel '(OI)(CI)low' >/dev/null
check "a path labelled low by hand is written" writes $BB low "$work\\mine\\f" --filesystem="$work\\mine"
check "  but not recorded" fails granted $BB "low $work\\mine"

rm_keeps_shared() {
    local out
    out=$("$zigsaw" rm $BB 2>&1) || { echo "$out"; return 1; }
    grep -q "kept the low integrity label of $(sed 's/\\/\\\\/g' <<<"$work\\rw")" <<<"$out" || { echo "$out"; return 1; }
    low_label "$work\\rw"
}
check "rm keeps a label another app still needs" rm_keeps_shared
check "  removes its own labels" no_label "$work\\cwd"
check "  and what was below them inherited" sh -c "! icacls '$work\\cwd\\f' | grep -q 'Mandatory Label'"
check "  revokes its AppContainer grants" sh -c "! icacls '$work\\ac' | grep -q 'S-1-15-'"
check "  leaves a label it didn't make" low_label "$work\\mine"
check "the second app's rm removes the shared label" sh -c "\"\$0\" rm $OTHER >/dev/null 2>&1 && ! icacls '$work\\rw' | grep -q 'Mandatory Label'" "$zigsaw"

rm -rf "$ZIGSAW_HOME" "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
