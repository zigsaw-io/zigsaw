#!/usr/bin/env bash
# End-to-end checks for `zigsaw exec` (src/exec.zig): a command started in a
# run that's going, in each sandbox, with the run's variables, working
# directory, data and grants; its own `ps` row; stop, kill, the run ending,
# its zigsaw ending, --detach; and what's refused.
#
#   tests/exec.sh [path\to\zigsaw.exe]
#
# A command to be stopped by Ctrl+C runs in a pseudoconsole of its own,
# through the console test driver (tests/ctrlc.zig, `term`), so Ctrl+C never
# reaches this script's console. Needs Git Bash and network access (for the
# busybox download, unless SEED_DOWNLOADS has it). Always uses a temporary
# store (on TMPDIR's drive), and removes it, and the AppContainer profiles it
# made, afterwards. Takes about a minute.

set -u
export MSYS_NO_PATHCONV=1
trap '' INT

cd "$(dirname "$0")/.." || exit 1
root=$(cygpath -w "$(pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
zig build ctrlc-driver || { echo "building the test driver failed"; exit 1; }
term="$root\\zig-out\\test\\zigsaw-ctrlc.exe"
ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
suite_key="Software\\ZigsawTest\\exec-$$-grants"
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
# The paths runs and their commands see, in BusyBox's sh: forward slashes.
w=$(cygpath -m "$work")
hold="$w/hold"
granted="$w/granted"
mkdir -p "$work\\hold" "$work\\granted" "$work\\outside"
echo "not yours" >"$work\\outside\\secret.txt"
# Whatever happens, nothing here is left running.
trap 'touch "$work\\hold\\all.stop" 2>/dev/null; "$zigsaw" kill $BB >/dev/null 2>&1; wait; reg delete "HKCU\\$suite_key" /f >/dev/null 2>&1' EXIT

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
refuses() { # <text> <command...>: the command fails, and says why
    local text=$1 out
    shift
    out=$("$@" 2>&1) && { echo "succeeded: $out"; return 1; }
    grep -aqF -- "$text" <<<"$out" || { echo "$out"; return 1; }
}
exits() { # <code> <command...>: the command ends with that code
    local want=$1 out code
    shift
    out=$("$@" 2>&1)
    code=$?
    [ "$code" = "$want" ] || { echo "exit $code, not $want: $out"; return 1; }
}
has() { # <text> <file>: the file says it
    grep -aqF -- "$1" "$2" || { tr -c '[:print:]\n' ' ' <"$2" | tail -c 300; return 1; }
}
lacks() { # <text> <command...>: the command succeeds, and doesn't say it
    local text=$1 out
    shift
    out=$("$@" 2>&1) || { echo "$out"; return 1; }
    ! grep -aqF -- "$text" <<<"$out" || { echo "it says: $text"; return 1; }
}

# A script that marks <name>.started, then waits for <name>.stop, or for
# all.stop. Every hold has a name of its own: no marker is ever deleted.
waits() { echo "touch '$hold/$1.started'; while [ ! -f '$hold/$1.stop' ] && [ ! -f '$hold/all.stop' ]; do sleep 0.2; done"; }
started() { # <name>: waits up to 15 s for the hold to start
    local i
    for i in $(seq 75); do [ -f "$work\\hold\\$1.started" ] && return 0; sleep 0.2; done
    printf 'FAIL  %s started, for the checks that need it\n' "$1"
    failures=$((failures + 1))
    return 1
}
release() { touch "$work\\hold\\$1.stop"; }
# The RUN column of the first line ps lists for <filter>, and an exec's.
run_of() { z ps "$1" 2>/dev/null | tr -d '\r' | awk 'NR == 2 { print $1 }'; }
exec_of() { z ps 2>/dev/null | tr -d '\r' | awk '/\(exec in run/ { print $1; exit }'; }
procs_of() { z ps "$1" 2>/dev/null | tr -d '\r' | awk -v r="$1" '$1 == r { print $5 }'; }
records() { ls "$(cygpath -u "$ZIGSAW_HOME")/running" 2>/dev/null | grep -c '\.json$'; }
declare -A termed
in_term() { # <name> <command line>: in a terminal of its own, in the background
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
# hold_run <name> <run options...>: a run of BusyBox that waits, in the
# background, granted the holds' folder for its markers and its execs'; its
# RUN in $run once it's started. One that doesn't start is let go.
hold_run() {
    local name=$1
    shift
    run=
    "$zigsaw" run --filesystem="$hold" "$@" $BB sh -c "$(waits "$name")" </dev/null >"$work\\$name.txt" 2>&1 &
    if started "$name"; then run=$(run_of $BB); else release "$name"; wait; fi
}

cd "$work" || exit 1
"$zigsaw" build "$root/recipes/busybox.json" >/dev/null 2>&1 || { echo "building busybox failed"; exit 1; }
zq=$(cygpath -m "$zigsaw")

# --- In each sandbox ---------------------------------------------------------------

# Soft keeps the caller's integrity level, including on elevated CI runners.
caller_level=$("$SYSTEMROOT/System32/whoami.exe" /groups | grep -o 'S-1-16-[0-9]*')
[ -n "$caller_level" ] || { echo "reading the caller's integrity level failed"; exit 1; }
for sb in soft low appcontainer; do
    hold_run "run-$sb" --sandbox=$sb --env=RUNVAR=from-run --filesystem="$granted"
    [ -n "$run" ] || continue
    check "$sb: exec runs a command in the run, with its variables and --env's" \
        says "RUNVAR=from-run EXTRA=x" z exec --env=EXTRA=x $BB busybox sh -c 'echo "RUNVAR=$RUNVAR EXTRA=$EXTRA"'
    check "  in its working directory, its home" says "/volumes/$BB/home" z exec $BB busybox pwd
    check "  its exit code is exec's" exits 3 z exec $BB busybox sh -c 'exit 3'
    case $sb in
        soft) level=$caller_level ;;
        *) level="S-1-16-4096" ;;
    esac
    check "  at the run's integrity level" says "$level" z exec $BB cmd /c "whoami /groups"
    check "  it writes where the run may" z exec $BB busybox sh -c "echo $sb > '$granted/$sb.txt'"
    if [ $sb != soft ]; then
        check "  and nowhere else" refuses "" z exec $BB busybox sh -c "echo x > '$w/outside/$sb.txt'"
    fi
    if [ $sb = appcontainer ]; then
        check "  it reads nothing the run wasn't granted" refuses "" z exec $BB busybox cat "$w/outside/secret.txt"
        check "  System32's programs run" exits 4 z exec $BB cmd /c "exit 4"
    fi
    release "run-$sb"
    wait
done

# --- What the run writes down for exec ---------------------------------------------

hold_run spec --sandbox=low --env=SECRET=hush
if [ -n "$run" ]; then
    spec="$ZIGSAW_HOME\\running\\$run.spec"
    check "the run writes down how it starts programs" test -f "$spec"
    check "  labelled so that nothing below medium reads it" says "Medium Mandatory Level:(NW,NR)" icacls "$spec"
    check "  a low run can't read it" refuses "Permission denied" z run --sandbox=low $BB cat "$(cygpath -m "$spec")"
    release spec
    wait
    check "  it goes with the run" test ! -f "$spec"
fi

# --- How a command is found ----------------------------------------------------------

hold_run find --sandbox=soft --filesystem="$granted"
if [ -n "$run" ]; then
    printf '@echo batch got %%1\r\n@exit /b %%2\r\n' >"$work\\granted\\hi.cmd"
    check "a batch file by its path runs through cmd.exe" says "batch got there" z exec $BB "$work\\granted\\hi.cmd" there 0
    check "  its exit code too" exits 6 z exec $BB "$work\\granted\\hi.cmd" there 6
    check "an export, with its arguments" says "busybox-export" z exec $BB busybox echo busybox-export
    check "a command that isn't there is refused" refuses "is not an export of $BB" z exec $BB no-such-command
    check "a path in the app that isn't there is refused" refuses "is not a file in the app" z exec $BB sub/none.exe
    release find
    wait
fi

# --- ps, stop and kill -----------------------------------------------------------------

hold_run ps --sandbox=low
if [ -n "$run" ]; then
    before=$(procs_of "$run")
    in_term ex "$zq exec $BB busybox sleep 300"
    for i in $(seq 75); do [ -n "$(exec_of)" ] && break; sleep 0.2; done
    ex=$(exec_of)
    check "ps lists the exec in its run" says "(exec in run $run)" z ps
    check "  the run's job has its command too" test "$(procs_of "$run")" -gt "$before"
    check "  ps --processes names it under the run" says "-> exec $ex" z ps --processes "$run"
    check "stop asks the exec alone" says "stopped $ex ($BB)" z stop --time=20 "$ex"
    ended ex
    check "  by Ctrl+C, in its own terminal" test "$(code_of ex)" = 130
    check "  and the run goes on" says "$run" z ps $BB

    "$zigsaw" exec $BB busybox sh -c "$(waits ex2)" </dev/null >/dev/null 2>&1 &
    exec_bg=$!
    started ex2 && ex=$(exec_of)
    check "kill ends the exec" says "killed $ex ($BB)" z kill "$ex"
    wait $exec_bg
    check "  and the run goes on" says "$run" z ps $BB

    "$zigsaw" exec $BB busybox sh -c "$(waits ex3)" </dev/null >/dev/null 2>&1 &
    started ex3 && ex=$(exec_of)
    out=$(z kill "$run")
    check "kill of the run ends its exec first" says "killed $ex ($BB) (in run $run)" echo "$out"
    check "  and the run" says "killed $run ($BB)" echo "$out"
    wait
    check "  no record is left" test "$(records)" = 0
fi

# --- How an exec ends ---------------------------------------------------------------

hold_run ends --sandbox=low
if [ -n "$run" ]; then
    "$zigsaw" exec $BB busybox sh -c "$(waits ends-exec)" </dev/null >"$work\\ends-exec.txt" 2>&1 &
    exec_bg=$!
    started ends-exec
    release ends
    wait $exec_bg
    code=$?
    check "the run ending ends the exec" test "$code" = 1
    check "  which says so" has "run $run ended, and with it this command" "$work\\ends-exec.txt"
    wait
fi

# --- --detach -----------------------------------------------------------------------

hold_run detach --sandbox=low
if [ -n "$run" ]; then
    out=$(z exec -d $BB busybox sh -c "echo detached-out; $(waits detached)")
    check "--detach prints the exec's PID" test -n "$(grep -ax '[0-9][0-9]*' <<<"$out")"
    check "  and returns once it started" started detached
    check "  ps lists it in the run" says "$out" z ps
    check "  its output goes nowhere" lacks "detached-out" echo "$out"
    taskkill /F /PID "$out" >/dev/null 2>&1
    sleep 1
    check "the exec's zigsaw ending ends its command" lacks "detached.started" z ps --processes "$run"
    check "--detach refuses what it can't start, at once" refuses "is not an export of $BB" z exec -d $BB no-such-command
    release detach
    wait
fi

# An --ephemeral run's data is the exec's too.
"$zigsaw" run --sandbox=low --ephemeral --filesystem="$hold" $BB sh -c "echo eph > here.txt; $(waits eph)" </dev/null >/dev/null 2>&1 &
if started eph; then
    check "exec sees an --ephemeral run's data" says "eph" z exec $BB busybox cat here.txt
    release eph
    wait
fi

# --- What's refused ------------------------------------------------------------------

check "exec needs a run and a command" refuses "usage:" z exec $BB
check "  and knows its options" refuses "unknown exec option --nope" z exec --nope $BB busybox true
check "nothing running by that name: says so" refuses "nothing running is $BB" z exec $BB busybox true
"$zigsaw" run --sandbox=soft $BB sh -c "$(waits two-a)" </dev/null >/dev/null 2>&1 &
"$zigsaw" run --sandbox=soft $BB sh -c "$(waits two-b)" </dev/null >/dev/null 2>&1 &
if started two-a && started two-b; then
    check "an app with two runs going: name one" refuses "$BB has 2 runs going" z exec $BB busybox true
    run=$(run_of $BB)
    check "  by its PID, which works" says "by-pid" z exec "$run" busybox echo by-pid
    "$zigsaw" exec "$run" busybox sh -c "$(waits two-exec)" </dev/null >/dev/null 2>&1 &
    started two-exec && ex=$(exec_of)
    check "an exec's PID is refused" refuses "name the run instead" z exec "$ex" busybox true
    rm -f "$ZIGSAW_HOME\\running\\$run.spec"
    check "a run with no spec can't be joined" refuses "can't be joined" z exec "$run" busybox true
    touch "$work\\hold\\all.stop"
    wait
fi
check "  none is left" says "nothing is running" z ps

z rm --delete-data $BB >/dev/null 2>&1
z prune --downloads --volumes >/dev/null 2>&1
cd /
rm -rf "$(cygpath -u "$ZIGSAW_HOME")" "$(cygpath -u "$work")"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
