#!/usr/bin/env bash
# End-to-end checks for detached runs, their logs, and a project's apps run
# together (src/detach.zig, src/logs.zig, src/up.zig): `run -d` in each
# sandbox, its log, stop and kill; `zigsaw logs` and when logs go; `up -d`,
# which builds what's missing, waits for services and leaves what's up, and
# `down`; `up` in a terminal, stopped by Ctrl+C; pinned apps from a
# registry; and what's refused.
#
#   tests/up.sh [path\to\zigsaw.exe]
#
# A foreground `up` runs in a pseudoconsole of its own, through the console
# test driver (tests/ctrlc.zig, `term`), which presses Ctrl+C there, so it
# never reaches this script's console. Needs Git Bash and network access (for
# the busybox download, unless SEED_DOWNLOADS has it, and to pull BusyBox's
# published image from ghcr.io). Always uses temporary stores (on TMPDIR's
# drive), and removes them afterwards. Takes about a minute.

set -u
export MSYS_NO_PATHCONV=1
trap '' INT

cd "$(dirname "$0")/.." || exit 1
root=$(cygpath -w "$(pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
zig build ctrlc-driver netprobe || { echo "building the test programs failed"; exit 1; }
term="$root\\zig-out\\test\\zigsaw-ctrlc.exe"
ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
export ZIGSAW_HOME
store2=$(cygpath -w "$(mktemp -d)")
work=$(cygpath -w "$(mktemp -d)")
suite_key="Software\\ZigsawTest\\up-$$-grants"
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
OTHER=test.up.other
DB=test.up.db
WEB=test.up.web
proj="$work\\proj"
logs_dir="$ZIGSAW_HOME\\logs"
# Whatever happens, nothing here is left running.
trap '"$zigsaw" kill --now $BB $OTHER $DB $WEB >/dev/null 2>&1; ZIGSAW_HOME="$store2" "$zigsaw" kill --now $BB >/dev/null 2>&1; wait; reg delete "HKCU\\$suite_key" /f >/dev/null 2>&1' EXIT

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
has() { # <text> <file>: the file says it
    grep -aqF -- "$1" "$2" || { tr -c '[:print:]\n' ' ' <"$2" | tail -c 300; return 1; }
}
lacks() { # <text> <command...>: the command succeeds, and doesn't say it
    local text=$1 out
    shift
    out=$("$@" 2>&1) || { echo "$out"; return 1; }
    ! grep -aqF -- "$text" <<<"$out" || { echo "it says: $text"; return 1; }
}
before() { # <first> <second> <command...>: the command says both, in that order
    local first=$1 second=$2 out a b
    shift 2
    out=$("$@" 2>&1)
    a=$(grep -anF -- "$first" <<<"$out" | head -1 | cut -d: -f1)
    b=$(grep -anF -- "$second" <<<"$out" | head -1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || { echo "$out"; return 1; }
}
log_of() { echo "$logs_dir\\$1.$2.log"; } # <id> <run>
number() { grep -ax '[0-9][0-9]*' <<<"$1"; }
# eventually <seconds> <command...>: the command succeeds within that time
eventually() {
    local n=$(($1 * 5))
    shift
    local i
    for i in $(seq "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 0.2; done
    "$@"
}
gone() { ! "$zigsaw" ps "$1" 2>/dev/null </dev/null | grep -aq "^$1 "; } # <run>
records() { ls "$(cygpath -u "$ZIGSAW_HOME")/running" 2>/dev/null | grep -c '\.json$'; }
zq=$(cygpath -m "$zigsaw")
# in_term <name> <command line> [<text>...]: in a terminal of its own, which
# presses Ctrl+C once each text shows; its output in <name>.txt.
in_term() {
    local name=$1 line=$2
    shift 2
    "$term" term "$line" "$@" >"$work\\$name.txt" 2>&1
    echo $? >"$work\\$name.code"
}

cd "$work" || exit 1
"$zigsaw" build "$root/recipes/busybox.json" >/dev/null 2>&1 || { echo "building busybox failed"; exit 1; }
sed "s/\"net.frippery.busybox\"/\"$OTHER\"/" "$root/recipes/busybox.json" >"$work\\other.json"
"$zigsaw" build "$work\\other.json" >/dev/null 2>&1 || { echo "building the second app failed"; exit 1; }
bb_digest=$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\refs\\$BB.json" | head -1)
bb_version=$(grep -o '"version": *"[^"]*"' "$ZIGSAW_HOME\\refs\\$BB.json" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')

# --- run --detach, in each sandbox ---------------------------------------------------

for sb in soft low appcontainer; do
    out=$(z run -d --sandbox=$sb $BB sh -c "echo out-$sb; echo err-$sb >&2; sleep 300; exit \$?" 2>&1)
    run=$(number "$out")
    check "$sb: run -d prints the run's number" test -n "$run"
    [ -n "$run" ] || continue
    check "  and returns while it goes on: ps lists it" says "$run" z ps $BB
    check "  its log has the app's output" eventually 10 has "out-$sb" "$(log_of $BB "$run")"
    check "  its stderr too" has "err-$sb" "$(log_of $BB "$run")"
    check "  and says what the run is" has "zigsaw: $BB $bb_version, run $run, started" "$(log_of $BB "$run")"
    check "stop asks it to end, and it does" says "stopped $run ($BB)" z kill --time=20 "$run"
    check "  by Ctrl+C, to the console it has with no window" has "asked to stop: sent Ctrl+C to its console" "$(log_of $BB "$run")"
    check "  its zigsaw goes on, and says how the run ended" has "zigsaw: $BB ended with exit code" "$(log_of $BB "$run")"
done
check "the runs' zigsaws cleaned up: no record is left" test "$(records)" = 0

run=$(number "$(z run -d $BB sleep 300 2>/dev/null)")
if [ -n "$run" ]; then
    check "kill ends a detached run" says "killed $run ($BB)" z kill --now "$run"
    check "  its zigsaw says so in the log" eventually 10 has "ended with exit code 1" "$(log_of $BB "$run")"
fi
check "run -d: an app that isn't installed fails at once" refuses "no.such.app is not installed" z run -d no.such.app
check "  as a wrong option does" refuses "--sandbox must be soft, low or appcontainer" z run -d --sandbox=wrong $BB
out=$(z run -d --sandbox=low --device=camera $BB sleep 300 2>&1)
check "  what it says before the run starts reaches this terminal" says "gets no camera under the low sandbox" echo "$out"
run=$(number "$out")
[ -n "$run" ] && z kill --now "$run" >/dev/null 2>&1

# --- zigsaw logs ------------------------------------------------------------------------

run=$(number "$(z run -d $BB sh -c "echo first; sleep 2; echo second; exit 0" 2>/dev/null)")
if [ -n "$run" ]; then
    check "logs -f follows a run's log until it ends" says "second" z logs -f "$run"
    check "  with the line its zigsaw ends it with" says "$BB ended with exit code 0" z logs "$run"
    check "logs of an app: its run that started last" says "first" z logs $BB
    check "logs --tail=1: only the last line" lacks "first" z logs --tail=1 $BB
    check "  which is the end line" says "ended with exit code 0" z logs --tail=1 $BB
fi
first=$run
run=$(number "$(z run -d $BB sh -c "echo third; sleep 300; exit \$?" 2>/dev/null)")
if [ -n "$run" ]; then
    check "a new detached run of the app deletes the ended one's log" test ! -f "$(log_of $BB "$first")"
    second=$(number "$(z run -d $BB sh -c "echo fourth; sleep 300; exit \$?" 2>/dev/null)")
    check "  but not one still written" test -f "$(log_of $BB "$run")"
    check "an app with two detached runs going: name one" refuses "has 2 detached runs going" z logs $BB
    check "  by its number" says "third" z logs "$run"
    z kill --now $BB >/dev/null 2>&1
fi
"$zigsaw" run $OTHER sleep 300 </dev/null >/dev/null 2>&1 &
check "logs of a run that isn't detached: refused" eventually 10 refuses "isn't detached" z logs $OTHER
z kill --now $OTHER >/dev/null 2>&1
wait
check "logs of an app with no log: refused" refuses "$DB has no log" z logs $DB
check "logs of a run that never was: refused" refuses "no run 4 is going" z logs 4
run=$(number "$(z run -d $OTHER sh -c "echo other-out; exit 0" 2>/dev/null)")
eventually 10 gone "$run"
check "rm deletes the app's logs" test -f "$(log_of $OTHER "$run")"
z uninstall $OTHER >/dev/null 2>&1
check "  (gone)" test ! -f "$(log_of $OTHER "$run")"
printf 'x\n' >"$logs_dir\\test.up.gone.123.log"
z uninstall --unused >/dev/null 2>&1
check "prune deletes those of apps that aren't installed" test ! -f "$logs_dir\\test.up.gone.123.log"

# --- up -d and down ----------------------------------------------------------------------

mkdir -p "$proj\\db" "$proj\\web" "$work\\hold"
cp "$root\\zig-out\\test\\zigsaw-netprobe.exe" "$proj\\db\\"
port=$((47000 + RANDOM % 900))
cat >"$proj\\db\\zigsaw.json" <<EOF
{ "id": "$DB", "version": "1", "command": "zigsaw-netprobe.exe", "args": ["serve", "\${listen:db}"],
  "permissions": { "services": [{ "name": "db", "port": $port }] },
  "modules": [{ "name": "probe", "sources": [{ "path": "zigsaw-netprobe.exe" }] }] }
EOF
echo web >"$proj\\web\\web.txt"
cat >"$proj\\web\\zigsaw.json" <<EOF
{ "id": "$WEB", "version": "1", "command": "\${bb}/busybox.exe", "runtimes": { "bb": "$BB@$bb_digest" }, "exports": {},
  "modules": [{ "name": "web", "sources": [{ "path": "web.txt" }] }] }
EOF
# project <web's script> [<more of run's entries>]: the project's zigsaw.json.
project() {
    printf '{ "apps": ["db", "web"],\n  "run": ["%s", { "app": "%s", "args": ["sh", "-c", "%s"] }%s] }\n' \
        "$DB" "$WEB" "$1" "${2:-}" >"$proj\\zigsaw.json"
}
project 'echo web-ready in mode $MODE; sleep 300; exit $?'
cd "$proj" || exit 1
out=$(z up -d 2>&1)
check "up -d builds the project's apps that aren't installed from it" says "building 2 apps: $DB, $WEB" echo "$out"
check "  starts each, in turn" says "started $WEB, as run" echo "$out"
check "  the next once a service answers" before "$DB's db answers on port $port" "started $WEB" echo "$out"
check "  and returns: both are up" says "$WEB" z ps $DB $WEB
db_run=$(z ps $DB 2>/dev/null | tr -d '\r' | awk 'NR == 2 { print $1 }')
web_run=$(z ps $WEB 2>/dev/null | tr -d '\r' | awk 'NR == 2 { print $1 }')
check "  each records the project" has "zigsaw.json" "$ZIGSAW_HOME\\running\\$web_run.json"
check "up -d again leaves what's up as it is" says "$WEB is up already, as run $web_run" z up -d
check "  and builds nothing" lacks "building" z up -d
check "logs in the project: each app's lines after its name" says "web | web-ready" z logs
check "  in the order \"run\" lists them" before "db  | " "web | " z logs
project 'echo web-ready in mode $MODE; sleep 300; exit $?' ', { "app": "'$OTHER'" }'
check "an app neither the project's nor installed: refused" refuses "$OTHER: it isn't installed, and isn't one of the project's apps" z up -d
cat >"$proj\\zigsaw.json" <<EOF
{ "apps": ["db", "web"], "run": ["$DB", { "app": "$WEB", "env": ["MODE=prod"], "args": ["sh", "-c", "echo web-ready in mode \$MODE; sleep 300; exit \$?"] }] }
EOF
out=$(z up -d 2>&1)
check "a changed entry starts its app again" says "starting $WEB again, as its entry in \"run\" changed" echo "$out"
check "  and leaves the others" says "$DB is up already, as run $db_run" echo "$out"
check "  with the new options" eventually 10 says "in mode prod" z logs $WEB
printf '{ "apps": ["db", "web"], "run": ["%s"] }\n' "$DB" >"$proj\\zigsaw.json"
check "an app no longer listed stays up, and up says so" says "though \"run\" no longer lists it" z up -d
project 'echo web-ready in mode $MODE; sleep 300; exit $?'
out=$(z down 2>&1)
check "down stops the project's runs" says "stopped $db_run ($DB)" echo "$out"
check "  the last started first" before "($WEB)" "($DB)" echo "$out"
check "  and nothing of it is left" test "$(records)" = 0
check "down with nothing up says so" says "nothing of $proj\\zigsaw.json is running" z down

# A service that doesn't come up: what started goes again.
printf '{ "apps": ["db", "web"],\n  "run": [{ "app": "%s", "args": ["sh", "-c", "sleep 300; exit $?"] }, { "app": "%s", "args": ["no-such-mode"] }] }\n' \
    "$WEB" "$DB" >"$proj\\zigsaw.json"
out=$(z up -d 2>&1)
check "an app that ends before its service answers fails up" says "$DB's run" echo "$out"
check "  which says so" says "ended" echo "$out"
check "  with the end of its log" says "  | " echo "$out"
check "  and stops what it started" says "stopping what this \`up\` started" echo "$out"
check "  so nothing is left" eventually 10 test "$(records)" = 0

# What's refused before anything starts.
refused() { # <message> <zigsaw.json>
    printf '%s\n' "$2" >"$proj\\zigsaw.json"
    refuses "$1" z up -d
}
check "a run option's value is checked as run checks it" refused "--sandbox must be soft, low or appcontainer" \
    '{ "apps": ["db", "web"], "run": [{ "app": "'$WEB'", "sandbox": "wrong" }] }'
check "  and its entry named" refused "the \"run\" entry of $WEB" \
    '{ "apps": ["db", "web"], "run": [{ "app": "'$WEB'", "sandbox": "wrong" }] }'
check "something that isn't a run option" refused "\"volumes\" isn't one of \`zigsaw run\`'s options" \
    '{ "apps": ["db", "web"], "run": [{ "app": "'$WEB'", "volumes": ["a:."] }] }'
check "an app from a registry that isn't pinned" refused "is pinned to its image's digest" \
    '{ "apps": ["db", "web"], "run": ["'$BB:$bb_version'"] }'
check "an app listed twice" refused "lists $WEB twice" \
    '{ "apps": ["db", "web"], "run": ["'$WEB'", "'$WEB'"] }'
check "a project with no \"run\"" refused "lists no apps to \"run\"" \
    '{ "apps": ["db", "web"] }'

# --- up in a terminal ---------------------------------------------------------------------

project 'echo web-ready; sleep 300; exit $?'
start=$SECONDS
in_term once "$zq up" web-ready
took=$((SECONDS - start))
check "up follows the apps' logs, each line after its app's name" has "web | web-ready" "$work\\once.txt"
check "  db's too" has "db  | listening on 127.0.0.1:$port" "$work\\once.txt"
check "Ctrl+C stops them" has "stopping $proj\\zigsaw.json's apps" "$work\\once.txt"
check "  last started first" before "($WEB)" "($DB)" cat "$work\\once.txt"
check "  and up ends once they have, with exit code 0" test "$(cat "$work\\once.code")" = 0
check "  soon" test "$took" -lt 30
check "  nothing is left" eventually 10 test "$(records)" = 0
project "trap '' INT; echo web-ready; while :; do sleep 1; done"
start=$SECONDS
in_term twice "$zq up" web-ready again
took=$((SECONDS - start))
check "a second Ctrl+C ends what hasn't stopped" has "killed" "$work\\twice.txt"
check "  at once, not after --time" test "$took" -lt 10
check "  nothing is left" eventually 10 test "$(records)" = 0

# --- Apps from a registry -----------------------------------------------------------------

pin="$work\\pin"
mkdir -p "$pin"
printf '{ "run": [{ "app": "%s:%s@%s", "args": ["sleep", "300"] }] }\n' "$BB" "$bb_version" "$bb_digest" >"$pin\\zigsaw.json"
cd "$pin" || exit 1
check "a zigsaw.json with only \"run\" is a project: build has nothing to do" says "lists no \"apps\" to build" z build
out=$(z up -d 2>&1)
check "an app pinned at the digest installed isn't installed again" lacks "installed first" echo "$out"
check "  and starts" says "started $BB" echo "$out"
check "  down stops it" says "($BB)" z down
out=$(ZIGSAW_HOME="$store2" z up -d --yes 2>&1)
check "one the store doesn't have is installed first, from its registry" says "$BB isn't installed as \"run\" pins it, so it's installed first" echo "$out"
check "  and starts" says "started $BB" echo "$out"
check "  down stops it" says "($BB)" env ZIGSAW_HOME="$store2" "$zigsaw" down

cd "$work" || exit 1
ZIGSAW_HOME="$store2" z uninstall --delete-data $BB >/dev/null 2>&1
ZIGSAW_HOME="$store2" z uninstall --unused --downloads --volumes >/dev/null 2>&1
z uninstall --delete-data $DB >/dev/null 2>&1
z uninstall --delete-data $WEB >/dev/null 2>&1
z uninstall --delete-data $BB >/dev/null 2>&1
z uninstall --unused --downloads --volumes >/dev/null 2>&1
cd /
rm -rf "$(cygpath -u "$ZIGSAW_HOME")" "$(cygpath -u "$store2")" "$(cygpath -u "$work")"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
