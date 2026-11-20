#!/usr/bin/env bash
# End-to-end checks for `zigsaw doctor` (src/doctor.zig): a store that isn't
# there yet, a fresh one, then one broken in many ways at once, each named at
# its level with what fixes it, and that fix doing so; the build drive taken,
# a copy of zigsaw missing a program, labelled low, with an upgrade's
# leftovers; daily checks for a deleted store and for a missing program; and
# the network: a registry that answers, refuses or hangs, a proxy it goes
# through, and the release. Through it all, doctor changes nothing.
#
#   tests/doctor.sh [path\to\zigsaw.exe]
#
# Needs Git Bash, `zig build netprobe` (done here), and network access (for
# the busybox download unless SEED_DOWNLOADS has it, and for ghcr.io and
# GitHub's release). Labels folders low, so TMPDIR must be on NTFS. Always
# uses a temporary store and folders, removes them, and the registry keys and
# scheduled tasks it made, afterwards. Leaves B: alone if something has it.
# Takes about half a minute.

set -u
export MSYS_NO_PATHCONV=1
trap '' INT

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
(cd "$(cygpath -u "$root")" && zig build netprobe) || { echo "building the network probe failed"; exit 1; }
netprobe="$root\\zig-out\\test\\zigsaw-netprobe.exe"
ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
# What stores changed (src/ledger.zig), file associations and the daily
# check's task: this run's own.
suite_key="Software\\ZigsawTest\\doctor-$$-grants"
export ZIGSAW_GRANTS_KEY="$suite_key"
classes_key="Software\\ZigsawTest\\doctor-$$-classes"
export ZIGSAW_CLASSES_KEY="$classes_key"
task_base="ZigsawTest-doctor-$$"
export ZIGSAW_TASK_NAME="$task_base"
export ZIGSAW_SHORTCUTS_DIR="$work\\links"
# Folders that stand in for yours: no run here may label the real ones.
mkdir -p "$work\\folders\\Documents"
export ZIGSAW_USER_FOLDERS="$work\\folders"
if [ -n "${SEED_DOWNLOADS:-}" ]; then
    mkdir -p "$ZIGSAW_HOME\\cache\\downloads"
    cp -l "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/" 2>/dev/null ||
        cp -n "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/"
fi

BB=net.frippery.busybox
APP=test.doctor.app
BROKEN=test.doctor.broken
# The version the three of them have, BusyBox's.
V=$(sed -n 's/.*"version": "\(.*\)".*/\1/p' "$(cygpath -u "$root")/recipes/busybox.json")
# A key an app keeps, as a run that didn't end left it in HKCU (src/hkcu.zig).
kept_key="Software\\ZigsawTest\\doctor-$$-kept"
record_key="HKCU\\Software\\zigsaw\\keys\\Software/ZigsawTest/doctor-$$-kept"
mapped_b=0
servers=()
cleanup() {
    for pid in "${servers[@]}"; do kill "$pid" 2>/dev/null; done
    [ "$mapped_b" = 1 ] && subst B: /D >/dev/null 2>&1
    for t in $(schtasks /query /fo csv /nh 2>/dev/null | tr -d '\r' | grep -o "\"\\\\$task_base[^\"]*\"" | tr -d '"' | tr ' ' '@'); do
        schtasks /delete /tn "${t//@/ }" /f >/dev/null 2>&1
    done
    reg delete "$record_key" /f >/dev/null 2>&1
    reg delete "HKCU\\$kept_key" /f >/dev/null 2>&1
    reg delete "HKCU\\$suite_key" /f >/dev/null 2>&1
    reg delete "HKCU\\$classes_key" /f >/dev/null 2>&1
}
trap cleanup EXIT

failures=0
check() { # Its own variable, as the checks read doctor's $out.
    local label=$1
    shift
    local said_
    if said_=$("$@" 2>&1); then
        printf 'ok    %s\n' "$label"
    else
        printf 'FAIL  %s\n      %s\n' "$label" "$(grep -av '^\s*$' <<<"$said_" | tail -1 | cut -c1-110)"
        failures=$((failures + 1))
    fi
}

z() { "$zigsaw" "$@" </dev/null; }
# doc [args]: doctor, with what it said in $out and its exit code in $code.
out=""
code=0
doc() {
    out=$("$zigsaw" doctor "$@" </dev/null 2>&1)
    code=$?
    out=$(tr -d '\r' <<<"$out")
}
finds() { # <level> <text>: the last doctor said it, at that level
    grep -E "^  $1 +" <<<"$out" | grep -qF -- "$2" || { echo "no $1 line with: $2"; echo "$out" | tail -5; return 1; }
}
said() { # <text>: anywhere in what the last doctor said
    grep -qF -- "$1" <<<"$out" || { echo "doesn't say: $1"; echo "$out" | tail -5; return 1; }
}
not_said() {
    ! grep -qF -- "$1" <<<"$out" || { echo "says: $1"; grep -F -- "$1" <<<"$out"; return 1; }
}
exited() { test "$code" = "$1" || { echo "exit code $code, not $1"; return 1; }; }
# What doctor must leave as it was: the store, the records outside it.
state() {
    find "$(cygpath -u "$ZIGSAW_HOME")" -printf '%P|%y|%s|%T@\n' 2>/dev/null | sort
    reg query "HKCU\\$suite_key" /s 2>&1
    reg query "HKCU\\Software\\zigsaw" /s 2>&1
    reg query "HKCU\\$kept_key" /s 2>&1
    find "$(cygpath -u "$work")/links" -mindepth 1 -printf '%P|%s|%T@\n' 2>&1 | sort
}
unchanged() { # <file of state before>
    state >"$work\\state-after"
    diff "$1" "$work\\state-after" >/dev/null || { diff "$1" "$work\\state-after" | head -5; return 1; }
}

cd "$work" || exit 1

# --- A store that isn't there yet -----------------------------------------------

none="$work\\none\\deeper"
out=$(ZIGSAW_HOME="$none" "$zigsaw" doctor --offline </dev/null 2>&1)
code=$?
out=$(tr -d '\r' <<<"$out")
check "a store that isn't there yet: doctor says so" finds note "it isn't there yet"
check "  exits 0" exited 0
check "  and makes nothing" test ! -e "$(cygpath -u "$work")/none"
long="$work\\a name with spaces\\$(printf 'x%.0s' $(seq 100))"
out=$(ZIGSAW_HOME="$long" "$zigsaw" doctor --offline </dev/null 2>&1 | tr -d '\r')
check "a store's path too long for Rust builds" finds warning "Rust builds fail past about 100"
check "  and one with a space" finds note "has a space"

# --- A fresh store --------------------------------------------------------------

z build "$root\\recipes\\busybox.json" >/dev/null 2>&1 || { echo "building busybox failed"; exit 1; }
recipe() { # <id> <file>: a BusyBox app with two commands and a shortcut
    sed -e "s/\"$BB\"/\"$1\"/" \
        -e "s/\"command\": \"busybox.exe\",/&\n  \"exports\": { \"$3-bb\": { \"command\": \"busybox.exe\" }, \"$3-bb2\": { \"command\": \"busybox.exe\" } },\n  \"shortcuts\": { \"$3 BB\": { \"command\": \"$3-bb\" } },/" \
        "$root\\recipes\\busybox.json" >"$2"
}
recipe $APP "$work\\app.json" doctor
recipe $BROKEN "$work\\broken.json" broken
z build "$work\\app.json" >/dev/null 2>&1 || { echo "building $APP failed"; exit 1; }
z build "$work\\broken.json" >/dev/null 2>&1 || { echo "building $BROKEN failed"; exit 1; }
# A run, which makes its data and its runs' lock.
z run --command=doctor-bb $APP true >/dev/null 2>&1

doc --offline
check "a fresh store: exits 0" exited 0
check "  its apps are all there" finds ok "3 apps: their images, files and commands are there"
check "  nothing left behind" finds ok "nothing: no run, build, upgrade or deleted store"
check "  the test variables are named" finds warning "ZIGSAW_USER_FOLDERS=$work\\folders, as tests set it"
check "  its folders are yours" finds ok "its folders and apps' files are yours"
check "  the network isn't asked" said "Network: not checked (--offline)"
doc --offline $APP
check "one app at length" said "$APP $V, from $work\\app.json"
check "  its commands" finds ok "its commands: doctor-bb, doctor-bb2"
check "  its files" finds ok "its files are unpacked"
doc --offline test.other.id
check "an app that isn't installed" finds note "test.other.id isn't installed"

out=$(ZIGSAW_UPGRADE_FROM="$work" ZIGSAW_UPGRADE_KEY="$work\\key.pub" "$zigsaw" doctor --offline </dev/null 2>&1 | tr -d '\r')
check "a release key from the environment is a warning" finds warning "releases signed with that key are trusted too"
out=$(ZIGSAW_REGSITRY=x "$zigsaw" doctor --offline </dev/null 2>&1 | tr -d '\r')
check "a ZIGSAW_ variable zigsaw doesn't read" finds warning "ZIGSAW_REGSITRY isn't a variable zigsaw reads"
out=$(ZIGSAW_REGISTRY='not a registry' "$zigsaw" doctor --offline </dev/null 2>&1)
code=$?
out=$(tr -d '\r' <<<"$out")
check "a ZIGSAW_REGISTRY that isn't one is a problem" finds problem "ZIGSAW_REGISTRY=not a registry isn't a registry"
check "  and doctor exits 1" exited 1
out=$(ZIGSAW_ID=$APP "$zigsaw" doctor --offline </dev/null 2>&1 | tr -d '\r')
check "inside a run" finds note "started inside a run of $APP"

# Every ZIGSAW_ variable zigsaw reads is one doctor knows.
missing=$(grep -ohE '"ZIGSAW_[A-Z0-9_]+"' $(ls "$(cygpath -u "$root")"/src/*.zig | grep -v doctor.zig) | sort -u |
    grep -v '"ZIGSAW_TEST_' | while read -r name; do grep -qF ".name = $name" "$(cygpath -u "$root")/src/doctor.zig" || echo "$name"; done)
check "every ZIGSAW_ variable zigsaw reads is in doctor's list" test -z "$missing"

# --- One store, broken in many ways ---------------------------------------------

home_u=$(cygpath -u "$ZIGSAW_HOME")
# A run whose zigsaw is gone: a record with no lock.
printf '{"kind":"run","id":"%s","pid":4000000,"started":1}' "$APP" >"$home_u/running/4000000.json"
# Commands: one names a zigsaw that isn't there, one another store; a shim that isn't a copy.
sed -i "s|^zigsaw = .*|zigsaw = C:\\\\nowhere\\\\zigsaw.exe|" "$home_u/bin/doctor-bb.shim"
sed -i "s|^home = .*|home = $(sed 's/\\/\\\\/g' <<<"$work")\\\\other-store|" "$home_u/bin/doctor-bb2.shim"
printf 'x' >>"$home_u/bin/busybox.exe"
# A grant nothing stands behind, a label no record explains, and one a deleted store left.
mkdir -p "$work\\granted" "$work\\orphaned"
icacls "$work\\granted" /setintegritylevel low >/dev/null
icacls "$work\\orphaned" /setintegritylevel low >/dev/null
icacls "$work\\folders\\Documents" /setintegritylevel low >/dev/null
printf 'low %s\n' "$work\\granted" >>"$home_u/grants/$APP.txt"
reg add "HKCU\\$suite_key" /v "$work\\deleted-store|test.gone|low $work\\orphaned" /t REG_SZ /d "" /f >/dev/null
# A key a run that didn't end left in HKCU.
reg add "HKCU\\$kept_key" /v setting /d "the app's" /f >/dev/null
reg add "$record_key" /v Data /d "$ZIGSAW_HOME\\volumes\\$APP" /f >/dev/null
reg add "$record_key" /v App /d "$APP" /f >/dev/null
reg add "$record_key" /v Aside /d no /f >/dev/null
reg add "$record_key" /v State /d "in place" /f >/dev/null
# Data an older zigsaw kept, an import and a rollback that stopped.
mkdir -p "$home_u/data/test.doctor.old" "$home_u/volumes/$APP/.zigsaw-import-1" "$home_u/snapshots/.swap-$APP"
echo old >"$home_u/data/test.doctor.old/f"
# An image without its config, overrides that can't be read, a recipe moved away.
broken_manifest=$(grep -o 'sha256:[0-9a-f]*' "$home_u/refs/$BROKEN.json" | cut -d: -f2)
broken_config=$(sed -n '/"config"/,/}/s/.*"digest": *"sha256:\([0-9a-f]*\)".*/\1/p' "$home_u/blobs/sha256/$broken_manifest")
mv "$home_u/blobs/sha256/$broken_config" "$work\\config-aside"
echo '{ not json' >"$home_u/overrides/$BB.json"
mv "$work\\app.json" "$work\\app-moved.json"
# A program of the same name as a command, before the store's bin on PATH.
mkdir -p "$work\\early"
cp "$(cygpath -u "$zigsaw")" "$work\\early\\doctor-bb.exe"

state >"$work\\state-before"
out=$(PATH="$(cygpath -u "$work\\early"):$home_u/bin:$PATH" "$zigsaw" doctor --offline </dev/null 2>&1)
code=$?
out=$(tr -d '\r' <<<"$out")
check "a broken store: doctor exits 1" exited 1
check "  and changes nothing" unchanged "$work\\state-before"
check "  a run that didn't end" finds warning "run 4000000 of $APP ended without cleaning up"
check "    which ps clears" said "\`zigsaw ps\` clears its record"
check "  a command naming a zigsaw that isn't there" finds problem "its command doctor-bb runs C:\\nowhere\\zigsaw.exe, which isn't there"
check "  a command of another store" finds problem "its command doctor-bb2 runs it from another store"
check "  a shim that isn't a copy" finds warning "its command busybox isn't a copy of"
check "  a program before the store's bin on PATH" finds warning "doctor-bb runs $work\\early\\doctor-bb.exe, which comes before"
check "  a grant nothing stands behind" finds warning "$APP's runs were given this, which nothing stands behind now: low label on $work\\granted"
check "  a deleted store's grant" finds warning "$work\\deleted-store, a store since deleted, left this for test.gone: low label on $work\\orphaned"
check "  a label no record explains" finds warning "$work\\folders\\Documents is labelled low, which no record explains"
check "    which grants --take-back removes" said "\`zigsaw permission-remove $work\\folders\\Documents\` removes it"
check "  a key left in HKCU" finds warning "HKCU\\$kept_key is still where a run of $APP that didn't end left it"
check "  data waiting to move" finds note "the data of 1 app waits in $ZIGSAW_HOME\\data"
check "  an import that didn't finish" finds note "an import into volume $APP that didn't finish"
check "  a rollback that stopped" finds warning "a rollback of $APP stopped halfway"
check "  an image without its config" finds problem "$BROKEN $V: its config, blob sha256:${broken_config:0:12}, is missing"
check "    which rm and build put right" said "\`zigsaw uninstall $BROKEN\`, then \`zigsaw build $work\\broken.json\`, installs it again"
check "  overrides that can't be read" finds problem "$BB $V: its overrides can't be read"
check "  a recipe moved away" finds note "it was built from $work\\app.json, which isn't there now"

# --- What doctor says fixes it, does --------------------------------------------

mv "$work\\config-aside" "$home_u/blobs/sha256/$broken_config"
rm "$home_u/overrides/$BB.json"
mv "$work\\app-moved.json" "$work\\app.json"
z ps >/dev/null 2>&1
z repair >/dev/null 2>&1
z permission-remove "$work\\folders\\Documents" >/dev/null 2>&1
z run --command=doctor-bb $APP true >/dev/null 2>&1
rm -rf "$home_u/volumes/$APP/.zigsaw-import-1"
doc --offline
check "after the fixes doctor named: nothing is left behind" finds ok "nothing: no run, build, upgrade or deleted store"
check "  the apps are all there" finds ok "3 apps: their images, files and commands are there"
check "  the label is taken back" bash -c "! icacls '$work\\granted' | grep -qa 'Mandatory Label'"
check "  the deleted store's too" bash -c "! icacls '$work\\orphaned' | grep -qa 'Mandatory Label'"
check "  the key is back in the app's data" bash -c "! reg query '$record_key' >/dev/null 2>&1 && ! reg query 'HKCU\\$kept_key' >/dev/null 2>&1"
check "  the data moved" test ! -e "$home_u/data"
check "  exits 0" exited 0

# --- The build drive --------------------------------------------------------------

b_now=$(subst | tr -d '\r' | grep '^B:' | sed 's/^B:\\: => //')
if [ -n "$b_now" ] && grep -q '\\zigsaw-build-[^\\]*$' <<<"$b_now"; then
    # A build that was killed left it, as tests/stop.sh's does: the next build
    # replaces it, and this one leaves it.
    doc --offline
    check "B: left by a build" finds note "B: is $b_now, a zigsaw build's"
    echo "skip  B: taken by something else: a build's mapping is there"
elif [ -e /b ] || [ -n "$b_now" ]; then
    echo "skip  B: is someone else's here"
else
    mkdir -p "$work\\bdrive" "$work\\zigsaw-build-0123"
    subst B: "$work\\bdrive" && mapped_b=1
    doc --offline
    check "B: taken by something else" finds warning "B: is $work\\bdrive, which zigsaw builds need"
    check "  which subst frees" said "\`subst B: /d\` frees it"
    subst B: /D && mapped_b=0
    subst B: "$work\\zigsaw-build-0123" && mapped_b=1
    doc --offline
    check "B: left by a build" finds note "B: is $work\\zigsaw-build-0123, a zigsaw build's"
    subst B: /D && mapped_b=0
fi

# --- A copy of zigsaw: an upgrade's leftovers, a program missing, labelled low ----

copy="$work\\zs"
mkdir -p "$copy"
cp "$(cygpath -u "$(dirname "$zigsaw")")"/zigsaw*.exe "$copy/"
touch "$copy\\zigsaw.exe.old-1234abcd"
rm "$copy\\zigsaw-relay.exe"
out=$("$copy\\zigsaw.exe" doctor --offline </dev/null 2>&1)
code=$?
out=$(tr -d '\r' <<<"$out")
check "an upgrade's leftovers beside zigsaw" finds note "earlier upgrades left zigsaw.exe.old-1234abcd beside zigsaw"
check "a program missing beside zigsaw" finds problem "zigsaw-relay.exe isn't beside zigsaw, so appcontainer runs can't serve their ports"
check "  exits 1" exited 1
check "a zigsaw outside its store's bin" finds note "it isn't in its store's bin"
cp "$(cygpath -u "$(dirname "$zigsaw")")/zigsaw-relay.exe" "$copy/"
icacls "$copy\\zigsaw.exe" /setintegritylevel low >/dev/null
state >"$work\\state-before"
out=$("$copy\\zigsaw.exe" doctor --offline </dev/null 2>&1)
code=$?
out=$(tr -d '\r' <<<"$out")
check "a zigsaw labelled low: it runs at low integrity" finds problem "zigsaw runs at low integrity"
check "  its file is labelled low" finds problem "this zigsaw's file is labelled low integrity"
check "  doctor finishes" said "problem"
check "  and changes nothing" unchanged "$work\\state-before"
icacls "$copy\\zigsaw.exe" /setintegritylevel medium >/dev/null

# --- Daily checks ------------------------------------------------------------------

other="$work\\other-store"
ZIGSAW_HOME="$other" "$copy\\zigsaw.exe" updates on >/dev/null 2>&1
rm -rf "$(cygpath -u "$other")"
"$copy\\zigsaw.exe" updates on >/dev/null 2>&1
rm "$copy\\zigsaw-notify.exe"
doc --offline
check "a daily check for a store since deleted" finds warning "is for $other, a store since deleted"
check "a daily check starting a program that isn't there" finds problem "the daily check starts $copy\\zigsaw-notify.exe, which isn't there"
check "  which updates on points here" said "\`zigsaw updates on\` points it at this zigsaw"
z updates on >/dev/null 2>&1
z repair >/dev/null 2>&1
doc --offline
check "  after updates on and repair, neither" not_said "a store since deleted"
check "    nor the other" not_said "which isn't there: it checks for nothing"
z updates off >/dev/null 2>&1

# --- A shortcut whose command is gone ----------------------------------------------

rm "$home_u/bin/doctor-bb.exe" "$home_u/bin/doctor-bb.shim"
doc --offline
check "a shortcut whose command is gone" finds warning "the shortcut \"doctor BB\" runs a command no app has now"
check "  and the command without its shim" finds warning "its command doctor-bb has no shim"
z repair >/dev/null 2>&1
doc --offline
check "  repair puts both back" finds ok "3 apps: their images, files and commands are there"

# --- The network ------------------------------------------------------------------

p1=$((47100 + $$ % 400))
p2=$((p1 + 1))
p3=$((p1 + 2))
"$netprobe" serve-http $p1 >/dev/null 2>&1 &
servers+=($!)
"$netprobe" silent $p2 >/dev/null 2>&1 &
servers+=($!)
sleep 1
version=$(z version | tr -d '\r' | awk '{ print $2 }')
mkdir -p "$work\\release"
printf '%s\n' "$version" >"$work\\release\\VERSION"
net() { # <NAME=value...>: doctor, with them set, and how long it took
    SECONDS=0
    out=$(for a in "$@"; do export "${a?}"; done; "$zigsaw" doctor </dev/null 2>&1)
    code=$?
    took=$SECONDS
    out=$(tr -d '\r' <<<"$out")
}
net ZIGSAW_REGISTRY=127.0.0.1:$p1 ZIGSAW_UPGRADE_FROM="$work\\release"
check "a registry that answers" finds ok "127.0.0.1:$p1 answers"
check "  a release no newer than this zigsaw" finds ok "the latest release is $version, this one"
check "  exits 0" exited 0
printf '999.0.0\n' >"$work\\release\\VERSION"
net ZIGSAW_REGISTRY=127.0.0.1:$p1 ZIGSAW_UPGRADE_FROM="$work\\release"
check "a newer release" finds note "zigsaw 999.0.0 is out; this is $version"
net ZIGSAW_REGISTRY=127.0.0.1:$p1 ZIGSAW_UPGRADE_FROM="http://127.0.0.1:$p1"
check "a release whose VERSION isn't one" finds warning "isn't a version"
net ZIGSAW_REGISTRY=127.0.0.1:$p3 ZIGSAW_UPGRADE_FROM="$work\\release"
check "a registry that refuses" finds problem "127.0.0.1:$p3 refused the connection"
check "  exits 1" exited 1
net ZIGSAW_REGISTRY=127.0.0.1:$p2 ZIGSAW_UPGRADE_FROM="$work\\release"
check "a registry that never answers" finds problem "127.0.0.1:$p2 didn't answer in 5 s"
check "  and doctor doesn't wait for it past then" test "$took" -le 12
net ZIGSAW_REGISTRY=127.0.0.1:$p1 ZIGSAW_UPGRADE_FROM="$work\\release" HTTP_PROXY=http://127.0.0.1:$p2 NO_PROXY=127.0.0.1
check "a local registry through a proxy, NO_PROXY or not" finds warning "127.0.0.1:$p1 is on this machine, but zigsaw asks the proxy"
check "  NO_PROXY, which zigsaw doesn't read" finds warning "NO_PROXY is 127.0.0.1, which zigsaw doesn't read"
check "  the proxy, which never answers" finds problem "didn't answer in 5 s (through the proxy http://127.0.0.1:$p2)"
doc --offline
check "--offline asks nothing" not_said "answers"
SECONDS=0
"$zigsaw" doctor </dev/null 2>&1 | head -2 >/dev/null
check "doctor | head ends" test $SECONDS -le 12
doc
check "ghcr.io answers" finds ok "ghcr.io answers"
check "  and GitHub's release" said "the latest release is"
for pid in "${servers[@]}"; do kill "$pid" 2>/dev/null; done
servers=()

z uninstall --delete-data $APP >/dev/null 2>&1
z uninstall --delete-data $BROKEN >/dev/null 2>&1
z uninstall --delete-data $BB >/dev/null 2>&1
z uninstall --unused --downloads --volumes >/dev/null 2>&1
cd /
rm -rf "$(cygpath -u "$ZIGSAW_HOME")" "$(cygpath -u "$work")"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
