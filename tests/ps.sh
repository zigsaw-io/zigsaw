#!/usr/bin/env bash
# End-to-end checks for `zigsaw ps` (src/ps.zig): the runs and builds going in
# a store, in each sandbox, through a shim, one inside another, one whose
# zigsaw was killed, and a build's command; with --processes and filters.
# BusyBox apps whose runs wait for a file before they end.
#
#   tests/ps.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and network access (for the busybox download, unless
# SEED_DOWNLOADS has it). Always uses a temporary store (on TMPDIR's drive),
# and removes it, and the AppContainer profiles it made, afterwards. Takes
# about half a minute.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
# The record of what stores changed (src/ledger.zig): one of this run's own.
suite_key="Software\\ZigsawTest\\ps-$$-grants"
export ZIGSAW_GRANTS_KEY="$suite_key"
# Folders that stand in for yours: no run here may label the real ones.
mkdir -p "$work\\folders\\Documents"
export ZIGSAW_USER_FOLDERS="$work\\folders"
if [ -n "${SEED_DOWNLOADS:-}" ]; then
    mkdir -p "$ZIGSAW_HOME\\cache\\downloads"
    cp -l "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/" 2>/dev/null ||
        cp -n "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/"
fi

BB=net.frippery.busybox
OTHER=test.ps.other
BUILT=test.ps.built
hold_dir="$work\\hold"
mkdir -p "$hold_dir"
# Whatever happens, every run and build here is let go.
trap 'touch "$hold_dir\\all.stop" 2>/dev/null; wait; reg delete "HKCU\\$suite_key" /f >/dev/null 2>&1' EXIT

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

z() { "$zigsaw" "$@" </dev/null; }
says() { # <text> <command...>: the command succeeds, and says it
    local text=$1 out
    shift
    out=$("$@" 2>&1) || { echo "$out"; return 1; }
    grep -qF -- "$text" <<<"$out" || { echo "$out"; return 1; }
}
matches() { # <extended regex> <command...>: the command succeeds, and a line of what it says matches
    local pattern=$1 out
    shift
    out=$("$@" 2>&1) || { echo "$out"; return 1; }
    grep -qE -- "$pattern" <<<"$(tr -d '\r' <<<"$out")" || { echo "$out"; return 1; }
}
silent_about() { # <text> <command...>: the command succeeds, and doesn't say it
    local text=$1 out
    shift
    out=$("$@" 2>&1) || { echo "$out"; return 1; }
    ! grep -qF -- "$text" <<<"$out" || { echo "$out"; return 1; }
}
refuses() { # <text> <command...>: the command fails, and says why
    local text=$1 out
    shift
    out=$("$@" 2>&1) && { echo "succeeded: $out"; return 1; }
    grep -qF -- "$text" <<<"$out" || { echo "$out"; return 1; }
}

# A script that marks <name>.started, then waits for <name>.stop, or for
# all.stop. Every hold has a name of its own: no marker is ever deleted.
waits() { echo "touch '$hold_dir\\$1.started'; while [ ! -f '$hold_dir\\$1.stop' ] && [ ! -f '$hold_dir\\all.stop' ]; do sleep 0.2; done"; }
started() { # <name>: waits up to 10 s for the hold to start; a failure if it doesn't
    local i
    for i in $(seq 100); do [ -f "$hold_dir\\$1.started" ] && return 0; sleep 0.1; done
    printf 'FAIL  %s started, for the checks that need it\n' "$1"
    failures=$((failures + 1))
    return 1
}
# hold <name> <program> <args...>: in the background; `release <name>` ends it.
declare -A held
hold() {
    local name=$1
    shift
    "$@" </dev/null >/dev/null 2>&1 &
    held[$name]=$!
    started "$name"
}
release() {
    touch "$hold_dir\\$1.stop"
    wait "${held[$1]}" 2>/dev/null
    return 0
}
# The RUN column of the first line ps lists for <filter>.
run_of() { z ps "$1" 2>/dev/null | tr -d '\r' | awk 'NR == 2 { print $1 }'; }
records() { ls "$(cygpath -u "$ZIGSAW_HOME")/running" 2>/dev/null | grep -c '\.json$'; }

cd "$work" || exit 1
"$zigsaw" build "$root/recipes/busybox.json" >/dev/null 2>&1 || { echo "building busybox failed"; exit 1; }
sed "s/\"net.frippery.busybox\"/\"$OTHER\"/" "$root/recipes/busybox.json" >"$work\\other.json"
"$zigsaw" build "$work\\other.json" >/dev/null 2>&1 || { echo "building the second app failed"; exit 1; }

check "nothing running: ps says so, and lists nothing" says "nothing is running" z ps
check "  and succeeds" silent_about "RUN" z ps

# --- Runs, in each sandbox -----------------------------------------------------

for sb in soft low appcontainer; do
    if hold $sb "$zigsaw" run --sandbox=$sb --filesystem="$hold_dir" $BB sh -c "$(waits $sb)"; then
        check "$sb: ps lists the run, with its sandbox" matches "^[0-9]+ +$BB +[^ ]+ +$sb +[0-9]+ " z ps
        check "  and its command" says "busybox.exe sh -c" z ps
        check "  its processes and their memory, with --processes" matches "^ +[0-9]+ +[0-9]+ +[0-9]+ (KB|MB) .*busybox\.exe\"? sh -c" z ps --processes
        check "  each under the one that started it" matches "^ +[0-9]+ +[0-9]+ .*[0-9][smhd] {4,}sh " z ps --processes
        check "  a record of its own in running\\" test "$(records)" = 1
    fi
    release $sb
    check "  gone once it ends, and its record too" says "nothing is running" z ps
    check "  no record is left" test "$(records)" = 0
done

# --- What a run is held to, and how it was started ---------------------------

if hold limited "$zigsaw" run --sandbox=low --memory=200MB --filesystem="$hold_dir" $BB sh -c "$(waits limited)"; then
    check "--memory: ps says the limit beside the memory" matches " MB \(of 200MB\) " z ps
fi
release limited

# A shim's run has the app's overrides: here, the folder it marks.
z override --filesystem="$hold_dir" $BB >/dev/null 2>&1
if hold shim "$ZIGSAW_HOME\\bin\\busybox.exe" sh -c "$(waits shim)"; then
    check "through the app's shim: listed as the app's run" matches "^[0-9]+ +$BB +[^ ]+ +low " z ps
fi
release shim
z override --reset $BB >/dev/null 2>&1

# --- Filters -------------------------------------------------------------------

hold one "$zigsaw" run --sandbox=soft $BB sh -c "$(waits one)"
hold two "$zigsaw" run --sandbox=soft $OTHER sh -c "$(waits two)"
check "two runs, two lines" test "$(z ps | tr -d '\r' | grep -cE '^[0-9]+ ')" = 2
check "ps <app-id> lists only that app's" silent_about "$OTHER" z ps $BB
check "  ignoring case" says "$BB" z ps NET.Frippery.BusyBox
two_run=$(run_of $OTHER)
check "ps <run> lists that run" matches "^$two_run +$OTHER " z ps "$two_run"
check "  and no other" silent_about "$BB" z ps "$two_run"
check "ps <a, b> lists either" test "$(z ps $BB "$two_run" | tr -d '\r' | grep -cE '^[0-9]+ ')" = 2
check "a filter that matches nothing says so" says "nothing running is no.such.app" z ps no.such.app
check "an unknown option is refused" refuses "usage:" z ps --nope
release one
release two

# --- A run inside another ------------------------------------------------------
#
# A soft run's app starts zigsaw, as a command of --share=commands does: the
# inner run is in the outer one's job.

# zigsaw started from inside a run takes the user's environment, but for
# zigsaw's own variables: the run passes this store's on.
inner_env=(--env=ZIGSAW_HOME="$ZIGSAW_HOME" --env=ZIGSAW_GRANTS_KEY="$ZIGSAW_GRANTS_KEY" --env=ZIGSAW_USER_FOLDERS="$ZIGSAW_USER_FOLDERS")
if hold outer "$zigsaw" run --sandbox=soft "${inner_env[@]}" $BB sh -c "'$(cygpath -m "$zigsaw")' run --sandbox=soft $OTHER sh -c \"$(waits outer)\""; then
    outer_run=$(run_of $BB)
    inner_run=$(run_of $OTHER)
    check "a run inside another is listed, as inside it" matches "^$inner_run +$OTHER .*\(in run $outer_run\)" z ps
    check "  the outer run's processes show it as a run" matches "-> run $inner_run \($OTHER\)" z ps --processes $BB
    # The inner zigsaw's own processes: under the inner run, not the outer.
    check "  its processes are listed under it, and not twice" test "$(z ps --processes | tr -d '\r' | grep -cE "^ +[0-9]+ +$inner_run ")" = 1
fi
release outer

# --- A run whose zigsaw was killed ----------------------------------------------

if hold killed "$zigsaw" run --sandbox=low --filesystem="$hold_dir" $BB sh -c "$(waits killed)"; then
    killed_run=$(run_of $BB)
    taskkill /F /PID "$killed_run" >/dev/null 2>&1
    sleep 0.5
    check "a killed run's record stays until ps" test "$(records)" = 1
    check "  which doesn't list it" says "nothing is running" z ps
    check "  and deletes it" test "$(records)" = 0
fi
release killed

# --- A build's command -----------------------------------------------------------

bb_digest=$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\refs\\$BB.json")
mkdir -p "$work\\built"
printf '{ "id": "%s", "version": "1", "command": "out.txt", "exports": {}, "sdk": { "busybox": "%s@%s" },\n  "modules": [{ "name": "waits", "sources": [],\n    "build": ["echo first", "%s", "echo x > \\"$PREFIX/out.txt\\""] }] }\n' \
    "$BUILT" "$BB" "$bb_digest" "$(waits build | sed 's/\\/\\\\/g; s/"/\\"/g')" >"$work\\built\\recipe.json"
if hold build "$zigsaw" build --rebuild --memory=1GB "$work\\built\\recipe.json"; then
    check "a build is listed as one, at its command" matches "^[0-9]+ +$BUILT +1 +build +[0-9]+ .*\[waits 2/3\] touch" z ps
    check "  with its limit" says "(of 1GB)" z ps
    check "  and the command's processes" matches "^ +[0-9]+ .* sh(\.exe)? " z ps --processes $BUILT
fi
release build
check "  gone once it's built" says "nothing is running" z ps
check "no record is left" test "$(records)" = 0

z rm --delete-data $BUILT >/dev/null 2>&1
z rm --delete-data $OTHER >/dev/null 2>&1
z rm --delete-data $BB >/dev/null 2>&1
z prune --downloads --volumes >/dev/null 2>&1
cd /
rm -rf "$(cygpath -u "$ZIGSAW_HOME")" "$(cygpath -u "$work")"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
