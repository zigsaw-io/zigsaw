#!/usr/bin/env bash
# End-to-end checks for `zigsaw stop` and `zigsaw kill` (src/stop.zig): runs
# in each sandbox asked to end by Ctrl+C, a run that won't, one sharing its
# console with another program, a stop typed in the run's own terminal, kill,
# several runs at once, a run inside another, and builds.
#
#   tests/stop.sh [path\to\zigsaw.exe]
#
# Runs that are to get Ctrl+C run in a pseudoconsole of their own, as a
# terminal runs them, through the console test driver (tests/ctrlc.zig,
# `term`): Ctrl+C never reaches this script's console. Needs Git Bash and
# network access (for the busybox download, unless SEED_DOWNLOADS has it).
# Always uses a temporary store (on TMPDIR's drive), and removes it, and the
# AppContainer profiles it made, afterwards. Takes about a minute.

set -u
export MSYS_NO_PATHCONV=1
# Nothing here sends Ctrl+C to this console; should a mistake, this script
# goes on.
trap '' INT

cd "$(dirname "$0")/.." || exit 1
root=$(cygpath -w "$(pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
zig build ctrlc-driver || { echo "building the test driver failed"; exit 1; }
term="$root\\zig-out\\test\\zigsaw-ctrlc.exe"
ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
# The record of what stores changed (src/ledger.zig): one of this run's own.
suite_key="Software\\ZigsawTest\\stop-$$-grants"
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
OTHER=test.stop.other
BUILT=test.stop.built
hold_dir="$work\\hold"
mkdir -p "$hold_dir"
# Whatever happens, nothing here is left running.
trap 'touch "$hold_dir\\all.stop" 2>/dev/null; "$zigsaw" kill $BB $OTHER $BUILT >/dev/null 2>&1; wait; reg delete "HKCU\\$suite_key" /f >/dev/null 2>&1' EXIT

failures=0
check() {
    local label=$1
    shift
    local out
    if out=$("$@" 2>&1); then
        printf 'ok    %s\n' "$label"
    else
        printf 'FAIL  %s\n      %s\n' "$label" "$(grep -av '^\s*$' <<<"$out" | tail -1 | cut -c1-110)"
        failures=$((failures + 1))
    fi
}

z() { "$zigsaw" "$@" </dev/null; }
says() { # <text> <command...>: the command succeeds, and says it
    local text=$1 out
    shift
    out=$("$@" 2>&1) || { echo "$out"; return 1; }
    grep -aqF -- "$text" <<<"$out" || { echo "$out"; return 1; }
}
silent_about() { # <text> <command...>: the command succeeds, and doesn't say it
    local text=$1 out
    shift
    out=$("$@" 2>&1) || { echo "$out"; return 1; }
    ! grep -aqF -- "$text" <<<"$out" || { echo "$out"; return 1; }
}
refuses() { # <text> <command...>: the command fails, and says why
    local text=$1 out
    shift
    out=$("$@" 2>&1) && { echo "succeeded: $out"; return 1; }
    grep -aqF -- "$text" <<<"$out" || { echo "$out"; return 1; }
}
has() { # <text> <file>: the file says it
    grep -aqF -- "$1" "$2" || { tr -c '[:print:]\n' ' ' <"$2" | tail -c 300; return 1; }
}
lacks() { # <text> <file>: the file doesn't say it
    ! grep -aqF -- "$1" "$2" || { echo "it says: $1"; return 1; }
}

# A script that marks <name>.started, then waits for <name>.stop, or for
# all.stop. Every hold has a name of its own: no marker is ever deleted.
waits() { echo "touch '$hold_dir\\$1.started'; while [ ! -f '$hold_dir\\$1.stop' ] && [ ! -f '$hold_dir\\all.stop' ]; do sleep 0.2; done"; }
up() { # <filter>: waits up to 15 s for ps to list it
    local i
    for i in $(seq 75); do z ps "$1" 2>/dev/null | grep -aq "$1" && return 0; sleep 0.2; done
    printf 'FAIL  %s is running, for the checks that need it\n' "$1"
    failures=$((failures + 1))
    return 1
}
# The RUN column of the first line ps lists for <filter>.
run_of() { z ps "$1" 2>/dev/null | tr -d '\r' | awk 'NR == 2 { print $1 }'; }
records() { ls "$(cygpath -u "$ZIGSAW_HOME")/running" 2>/dev/null | grep -c '\.json$'; }
# in_term <name> <command line>: runs it in a terminal of its own, in the
# background; what it wrote goes to <name>.txt, its exit code to <name>.code.
declare -A termed
in_term() {
    ( "$term" term "$2" >"$work\\$1.txt" 2>&1; echo $? >"$work\\$1.code" ) &
    termed[$1]=$!
}
ended() { # <name>: waits for the terminal to end, up to 30 s
    local i
    for i in $(seq 150); do [ -f "$work\\$1.code" ] && return 0; sleep 0.2; done
    echo "still running"
    return 1
}
code_of() { cat "$work\\$1.code" 2>/dev/null | tr -d '\r\n'; }
# timed <var> <command...>: runs it, its output in $out, its seconds in <var>
timed() {
    local var=$1 start=$SECONDS
    shift
    out=$("$@" 2>&1)
    printf -v "$var" '%d' $((SECONDS - start))
}

cd "$work" || exit 1
"$zigsaw" build "$root/recipes/busybox.json" >/dev/null 2>&1 || { echo "building busybox failed"; exit 1; }
sed "s/\"net.frippery.busybox\"/\"$OTHER\"/" "$root/recipes/busybox.json" >"$work\\other.json"
"$zigsaw" build "$work\\other.json" >/dev/null 2>&1 || { echo "building the second app failed"; exit 1; }
zq=$(cygpath -m "$zigsaw")

# --- Asked by Ctrl+C, in each sandbox -------------------------------------------

for sb in soft low appcontainer; do
    in_term $sb "$zq run --sandbox=$sb $BB sleep 300"
    if up $BB; then
        run=$(run_of $BB)
        timed took z stop --time=20 $BB
        check "$sb: stop asks the run to end, and it does" says "stopped $run ($BB)" echo "$out"
        check "  by Ctrl+C, at once" test "$took" -lt 10
        ended $sb
        check "  the app ended as Ctrl+C ends it" test "$(code_of $sb)" = 130
        check "  the run says it was asked, and how" has "asked to stop: sent Ctrl+C to its console" "$work\\$sb.txt"
        check "  its zigsaw ended its record" test "$(records)" = 0
    fi
done

# A native shell started it: it gets Ctrl+C too, as from the key, and goes on.
in_term shell "cmd /d /c $zq run --sandbox=low $BB sleep 300 & echo shell-went-on"
if up $BB; then
    check "a run its shell started: stopped by Ctrl+C" says "stopped" z stop --time=20 $BB
    ended shell
    check "  and the shell goes on" has "shell-went-on" "$work\\shell.txt"
fi

# --- When Ctrl+C isn't sent, or does nothing --------------------------------------

in_term ignores "$zq run --sandbox=low $BB sh -c \"trap '' INT; while :; do sleep 1; done\""
if up $BB; then
    run=$(run_of $BB)
    timed took z stop --time=2 $BB
    check "an app that ignores Ctrl+C is killed after --time" says "killed $run ($BB) after 2 s" echo "$out"
    check "  not before" test "$took" -ge 2
    ended ignores
    check "  with exit code 1" test "$(code_of ignores)" = 1
fi

in_term other "cmd /d /c start /b ping -n 60 127.0.0.1 >nul & $zq run --sandbox=low $BB sleep 300"
if up $BB; then
    run=$(run_of $BB)
    check "another program on the run's console: stop kills it after --time" says "killed $run ($BB) after 2 s" z stop --time=2 $BB
    ended other
    check "  the run says what was in the way" has "didn't send Ctrl+C: PING.EXE" "$work\\other.txt"
fi

# `zigsaw stop` typed in the run's own terminal: no Ctrl+C, so the batch file
# that typed it isn't asked "Terminate batch job (Y/N)?" and goes on.
printf '@start /b %s run --sandbox=low %s sleep 300\r\n@ping -n 3 127.0.0.1 >nul\r\n@%s stop --time=2 %s\r\n@echo here-stop-exit=%%errorlevel%%\r\n' \
    "$zq" $BB "$zq" $BB >"$work\\here.cmd"
in_term here "cmd /d /c $work\\here.cmd"
ended here
check "stop in the run's own terminal sends no Ctrl+C" has "the \`zigsaw stop\` is on its console" "$work\\here.txt"
check "  kills it after --time, and the script goes on" has "here-stop-exit=0" "$work\\here.txt"
check "  unasked whether to end" lacks "Terminate batch job" "$work\\here.txt"

# --- kill ---------------------------------------------------------------------------

in_term kill "$zq run --sandbox=low --ephemeral $BB sleep 300"
if up $BB; then
    run=$(run_of $BB)
    timed took z kill $BB
    check "kill ends a run" says "killed $run ($BB)" echo "$out"
    check "  at once" test "$took" -lt 5
    ended kill
    check "  with exit code 1" test "$(code_of kill)" = 1
    check "  its zigsaw cleaned up: the --ephemeral data is gone" test "$(ls "$(cygpath -u "$ZIGSAW_HOME")/tmp" 2>/dev/null | grep -c '^run-')" = 0
    check "  and the record" test "$(records)" = 0
fi

# Several, by app id or run; no Ctrl+C needed, so no terminal.
"$zigsaw" run --sandbox=soft $BB sh -c "$(waits a)" </dev/null >/dev/null 2>&1 &
"$zigsaw" run --sandbox=low $BB sh -c "$(waits b)" </dev/null >/dev/null 2>&1 &
"$zigsaw" run --sandbox=soft $OTHER sh -c "$(waits c)" </dev/null >/dev/null 2>&1 &
sleep 1
up $OTHER
check "kill <app-id> ends every run of the app" test "$(z kill $BB | grep -ac "^killed [0-9]* ($BB)")" = 2
check "  and no other" says "$OTHER" z ps
other_run=$(run_of $OTHER)
check "kill <run> ends that run" says "killed $other_run ($OTHER)" z kill "$other_run"
wait
check "  none is left" says "nothing is running" z ps

# --- A run inside another ---------------------------------------------------------
#
# A soft run's app starts zigsaw, as a command of --share=commands does: the
# inner run is in the outer one's job, and ends first.

inner_env=(--env=ZIGSAW_HOME="$ZIGSAW_HOME" --env=ZIGSAW_GRANTS_KEY="$ZIGSAW_GRANTS_KEY" --env=ZIGSAW_USER_FOLDERS="$ZIGSAW_USER_FOLDERS")
"$zigsaw" run --sandbox=soft "${inner_env[@]}" $BB sh -c "'$zq' run --sandbox=soft $OTHER sh -c \"$(waits inner)\"" </dev/null >/dev/null 2>&1 &
if up $OTHER; then
    outer_run=$(run_of $BB)
    inner_run=$(run_of $OTHER)
    out=$(z kill "$outer_run")
    check "kill of a run ends the runs inside it" says "killed $inner_run ($OTHER) (in run $outer_run)" echo "$out"
    check "  and it" says "killed $outer_run ($BB)" echo "$out"
    check "  each zigsaw ended its own record" test "$(records)" = 0
fi
wait

# --- What's refused -----------------------------------------------------------------

check "stop needs a run or an app" refuses "usage:" z stop
check "kill too" refuses "usage:" z kill
check "nothing running by that name: says so" refuses "nothing running is no.such.app" z stop no.such.app
check "--time takes seconds" refuses "--time takes a number of seconds" z stop --time=soon $BB
check "kill has no --time" refuses "usage:" z kill --time=1 $BB

# --- Builds --------------------------------------------------------------------------

bb_digest=$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\refs\\$BB.json")
mkdir -p "$work\\built"
printf '{ "id": "%s", "version": "1", "command": "out.txt", "exports": {}, "sdk": { "busybox": "%s@%s" },\n  "modules": [{ "name": "waits", "sources": [],\n    "build": ["echo first", "sleep 300", "echo x > \\"$PREFIX/out.txt\\""] }] }\n' \
    "$BUILT" "$BB" "$bb_digest" >"$work\\built\\recipe.json"
in_term build "$zq build --rebuild $work\\built\\recipe.json"
if up $BUILT; then
    for i in $(seq 50); do z ps $BUILT 2>/dev/null | grep -aq "waits 2/3" && break; sleep 0.2; done
    run=$(run_of $BUILT)
    check "stop asks a build to end" says "stopped $run ($BUILT)" z stop --time=20 $BUILT
    ended build
    check "  it fails, saying why" has "stopped by \`zigsaw stop\` during build command 2" "$work\\build.txt"
    check "  and runs nothing more" lacks "[waits 3/3]" "$work\\build.txt"
fi

"$zigsaw" build --rebuild "$work\\built\\recipe.json" </dev/null >"$work\\build2.txt" 2>&1 &
if up $BUILT; then
    run=$(run_of $BUILT)
    check "kill ends a build" says "killed $run ($BUILT)" z kill $BUILT
    wait
    check "  its record goes with ps" says "nothing is running" z ps
    check "  none is left" test "$(records)" = 0
fi

z rm --delete-data $OTHER >/dev/null 2>&1
z rm --delete-data $BB >/dev/null 2>&1
z prune --downloads --volumes >/dev/null 2>&1
cd /
rm -rf "$(cygpath -u "$ZIGSAW_HOME")" "$(cygpath -u "$work")"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
