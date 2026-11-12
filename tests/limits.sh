#!/usr/bin/env bash
# End-to-end checks for what a run or a build may use (process.Limits):
# --memory and --cpus on `zigsaw run`, saved with `zigsaw override`, and on
# `zigsaw build`; in each sandbox, through a shim, and what zigsaw says when a
# limit is reached. A BusyBox app, and tests/jobprobe.zig, which says how many
# processors it counts and how much memory it gets.
#
#   tests/limits.sh [path\to\zigsaw.exe]
#
# Needs Git Bash, zig (for the probe), and network access (for the busybox
# download, unless SEED_DOWNLOADS has it). Always uses a temporary store (on
# TMPDIR's drive), and removes it, and the AppContainer profile it made,
# afterwards. Takes about half a minute.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
(cd "$(cygpath -u "$root")" && zig build jobprobe) || { echo "building the job probe failed"; exit 1; }
ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
# The record of what stores changed (src/ledger.zig): one of this run's own.
suite_key="Software\\ZigsawTest\\limits-$$-grants"
export ZIGSAW_GRANTS_KEY="$suite_key"
trap 'reg delete "HKCU\\$suite_key" /f >/dev/null 2>&1' EXIT
# Folders that stand in for yours: no run here may label the real ones.
mkdir -p "$work\\folders\\Documents"
export ZIGSAW_USER_FOLDERS="$work\\folders"
if [ -n "${SEED_DOWNLOADS:-}" ]; then
    mkdir -p "$ZIGSAW_HOME\\cache\\downloads"
    cp -l "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/" 2>/dev/null ||
        cp -n "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/"
fi

BB=net.frippery.busybox
BUILT=test.limits.built

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
skip() { printf 'skip  %s\n' "$1"; }

z() { "$zigsaw" "$@" </dev/null; }
manifest_of() { grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\refs\\$1.json"; }
says() { # <text> <command...>: the command succeeds, and says it
    local text=$1 out
    shift
    out=$("$@" 2>&1) || { echo "$out"; return 1; }
    grep -qF -- "$text" <<<"$out" || { echo "$out"; return 1; }
}
refuses() { # <text> <command...>: the command fails, and says why
    local text=$1 out
    shift
    out=$("$@" 2>&1) && { echo "succeeded: $out"; return 1; }
    grep -qF -- "$text" <<<"$out" || { echo "$out"; return 1; }
}
matches() { # <extended regex> <command...>: the command succeeds, and a line of what it says matches
    local pattern=$1 out
    shift
    out=$("$@" 2>&1) || { echo "$out"; return 1; }
    grep -qE -- "$pattern" <<<"$(tr -d '\r' <<<"$out")" || { echo "$out"; return 1; }
}
exits() { # <code> <command...>
    local want=$1 got
    shift
    "$@" >/dev/null 2>&1
    got=$?
    [ "$got" = "$want" ] || { echo "exit code $got"; return 1; }
}
silent_about() { # <text> <command...>: the command succeeds, and doesn't say it
    local text=$1 out
    shift
    out=$("$@" 2>&1) || { echo "$out"; return 1; }
    ! grep -qF -- "$text" <<<"$out" || { echo "$out"; return 1; }
}

# The probe, in a directory of its own that every sandbox's runs may read.
mkdir -p "$work\\probe" "$work\\cwd"
cp "$(cygpath -u "$root")/zig-out/test/zigsaw-jobprobe.exe" "$(cygpath -u "$work")/probe/"
probe=$(cygpath -m "$work\\probe\\zigsaw-jobprobe.exe")
# run <sandbox> <run options...> -- <sh script>: the app's sh, which may run
# the probe. The script never ends with a program: in an AppContainer,
# BusyBox's sh doesn't wait for the last command of `sh -c` (see
# acl.letChildrenQueryUs), and the run ends before it has done anything.
run() {
    local sb=$1 opts=()
    shift
    while [ "$1" != -- ]; do opts+=("$1"); shift; done
    shift
    z run --sandbox="$sb" --filesystem="$work\\probe:ro" "${opts[@]}" $BB sh -c "$1"'; exit $?'
}

# No run here has the repository as its working directory.
cd "$work\\cwd" || exit 1
"$zigsaw" build "$root/recipes/busybox.json" >/dev/null 2>&1 || { echo "building busybox failed"; exit 1; }

# How many processors this zigsaw has, and a number below it to ask for.
all=$("$probe" cpus | tr -d '\r' | sed 's/^affinity=\([0-9]*\) .*/\1/')
few=$((all > 2 ? 2 : 1))
limit=200MB

# --- Runs, in each sandbox ---------------------------------------------------

for sb in soft low appcontainer; do
    check "$sb: a run without limits has neither" says "affinity=$all " run $sb -- "'$probe' cpus && '$probe' alloc 300"
    check "$sb: --memory lets a run have less than it" says "allocated 100 MiB" run $sb --memory=$limit -- "'$probe' alloc 100"
    check "  and such a run hears nothing of it" silent_about "memory limit" run $sb --memory=$limit -- "'$probe' alloc 100"
    check "$sb: past it Windows refuses the run more, and zigsaw says which limit" refuses "reached its memory limit of $limit" run $sb --memory=$limit -- "'$probe' alloc 300"
    check "  what a process the app started has counts too" refuses "reached its memory limit of $limit" run $sb --memory=$limit -- "'$probe' alloc 120 '$probe' alloc 120"
    check "  the run's exit code is the app's" exits 7 run $sb --memory=$limit -- "'$probe' alloc 300; exit 7"
    if [ "$all" -gt 1 ]; then
        check "$sb: --cpus=$few gives a run that many processors" says "affinity=$few " run $sb --cpus=$few -- "'$probe' cpus"
        check "  as a share of the machine's processor time too, which Ninja counts by" matches 'rate=[0-9]+/10000' run $sb --cpus=$few -- "'$probe' cpus"
        check "  BusyBox's nproc counts them" says "$few" run $sb --cpus=$few -- 'test "$(nproc)" = '"$few"' && nproc'
        check "  and the variables say so to programs that don't ask Windows" says "vars=$few,$few" run $sb --cpus=$few -- 'echo vars=$NUMBER_OF_PROCESSORS,$CARGO_BUILD_JOBS'
        check "  a variable given with --env stays" says "vars=$few,7" run $sb --cpus=$few --env=CARGO_BUILD_JOBS=7 -- 'echo vars=$NUMBER_OF_PROCESSORS,$CARGO_BUILD_JOBS'
    else
        skip "$sb: --cpus (this machine gives zigsaw one processor)"
    fi
    check "$sb: --cpus with as many as zigsaw has, or more, limits nothing" says "affinity=$all system=" run $sb --cpus=9999 -- "'$probe' cpus"
    check "  and sets no variable" says "jobs=." run $sb --cpus=9999 -- 'echo jobs=$CARGO_BUILD_JOBS.'
done
check "both at once" says "allocated 100 MiB" run soft --memory=$limit --cpus=$few -- "'$probe' alloc 100"

# --- Saved with `zigsaw override` --------------------------------------------

z override --memory=$limit $BB >/dev/null 2>&1
check "override --memory is saved" says "--memory=$limit" z override --show $BB
check "  and holds every run" refuses "reached its memory limit of $limit" run low -- "'$probe' alloc 300"
check "  through the app's shim too" refuses "reached its memory limit of $limit" "$ZIGSAW_HOME\\bin\\busybox.exe" sh -c "'$probe' alloc 300"
check "  a run's own --memory goes over it" says "allocated 300 MiB" run low --memory=1GB -- "'$probe' alloc 300"
check "  and --memory=none takes it away" says "allocated 300 MiB" run low --memory=none -- "'$probe' alloc 300"
z override --global --cpus=$few >/dev/null 2>&1
check "override --global --cpus is saved, for every app" says "--cpus=$few" z override --show --global
if [ "$all" -gt 1 ]; then
    check "  and holds a run of one, with the app's own override" says "affinity=$few " run soft -- "'$probe' cpus && ! '$probe' alloc 300"
    check "  --cpus=all takes it away" says "affinity=$all " run soft --cpus=all -- "'$probe' cpus"
fi
z override --cpus=all $BB >/dev/null 2>&1
check "an app's --cpus=all is saved over the store's" says "--memory=$limit --cpus=all" z override --show $BB
check "  and its runs have every processor" says "affinity=$all " run soft -- "'$probe' cpus"
check "-v says what a run is held to" matches '^memory   1GB at most' z -v run --sandbox=soft --memory=1GB $BB true
check "  and when --cpus asks for no fewer than there are" matches "^cpus     all $all" z -v run --sandbox=soft --cpus=9999 $BB true
check "  and the most memory it had" matches '^peak     (6[4-9]|7[0-9]) MB' z -v run --sandbox=soft --memory=none --filesystem="$work\\probe:ro" $BB sh -c "'$probe' alloc 64"
z override --reset $BB >/dev/null 2>&1
z override --reset --global >/dev/null 2>&1
check "override --reset takes both away" says "allocated 300 MiB" run low -- "'$probe' cpus | grep -q 'affinity=$all ' && '$probe' alloc 300"

check "--memory=0 is refused: none says no limit" refuses "--memory expects a size" z run --memory=0 $BB true
check "--memory takes a size" refuses "--memory expects a size" z override --memory=lots $BB
check "--cpus=0 is refused: all says no limit" refuses "--cpus expects a number" z run --cpus=0 $BB true
check "--cpus takes a whole number" refuses "--cpus expects a number" z run --cpus=1.5 $BB true

# --- Builds --------------------------------------------------------------------
#
# Each of a build's commands, with all it starts, is held to the limits. They
# are no input of the build: --rebuild runs the commands again.

bb_digest=$(manifest_of $BB)
# recipe <dir> <module env, as JSON members> <build commands, as JSON strings>
recipe() {
    mkdir -p "$work\\$1"
    cp "$(cygpath -u "$work")/probe/zigsaw-jobprobe.exe" "$(cygpath -u "$work")/$1/"
    printf '{ "id": "%s", "version": "1", "command": "out.txt", "exports": {}, "sdk": { "busybox": "%s@%s" },\n  "modules": [{ "name": "m", "sources": [{ "path": "zigsaw-jobprobe.exe" }], "env": { %s },\n    "build": [%s, "echo x > \\"$PREFIX/out.txt\\""] }] }\n' \
        "$BUILT" "$BB" "$bb_digest" "$2" "$3" >"$work\\$1\\recipe.json"
}
recipe counts '' '"./zigsaw-jobprobe.exe cpus", "echo vars=$NUMBER_OF_PROCESSORS,$CARGO_BUILD_JOBS.", "./zigsaw-jobprobe.exe alloc 100"'
recipe jobs '"CARGO_BUILD_JOBS": "7"' '"echo vars=$NUMBER_OF_PROCESSORS,$CARGO_BUILD_JOBS."'
recipe greedy '' '"./zigsaw-jobprobe.exe alloc 300"'
build() { z build --rebuild "$@"; }

check "a build without limits has neither" says "affinity=$all " build "$work\\counts\\recipe.json"
if [ "$all" -gt 1 ]; then
    check "build --cpus=$few gives each command that many processors" says "affinity=$few " build --cpus=$few "$work\\counts\\recipe.json"
    check "  and the variables that say so" says "vars=$few,$few." build --cpus=$few "$work\\counts\\recipe.json"
    check "  a module's own variable stays" says "vars=$few,7." build --cpus=$few "$work\\jobs\\recipe.json"
else
    skip "build --cpus (this machine gives zigsaw one processor)"
fi
check "build --cpus with as many as zigsaw has sets no variable" says "vars=$all,." build --cpus=$all "$work\\counts\\recipe.json"
check "build --memory lets a command have less than it" says "allocated 100 MiB" build --memory=$limit "$work\\counts\\recipe.json"
check "  past it the command is refused more, and the build says which limit" refuses "reached the build's memory limit of $limit (--memory)" build --memory=$limit "$work\\greedy\\recipe.json"
check "  the build fails as the command does" refuses "build command 1 exited with code 1" build --memory=$limit "$work\\greedy\\recipe.json"
check "the same build without the limit goes through" says "allocated 300 MiB" build "$work\\greedy\\recipe.json"
check "build --memory takes a size" refuses "--memory expects a size" z build --memory=lots "$work\\counts\\recipe.json"

# The image a build used stays until prune --downloads, and only zigsaw can
# delete its protected deployment.
z rm --delete-data $BUILT >/dev/null 2>&1
z rm --delete-data $BB >/dev/null 2>&1
z prune --downloads --volumes >/dev/null 2>&1
cd /
rm -rf "$(cygpath -u "$ZIGSAW_HOME")" "$(cygpath -u "$work")"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
