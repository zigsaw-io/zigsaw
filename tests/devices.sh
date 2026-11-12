#!/usr/bin/env bash
# Device permissions end to end (src/oci.zig's Device, docs/findings.md), with
# tests/devprobe.zig as the app, in a store of its own. One app's recipe has
# the camera, another's has no device. In an AppContainer, a run holds
# Windows' capability for each of its devices and for no other, which the
# probe reads from its own token: so these rows need no camera. --device,
# --nodevice, overrides and --global change the list. The run's relay never
# holds a device. Under low a note says that Windows opens the camera for no
# program there, and under soft, when you changed the list, that it isn't
# enforced. Installing says what the app may use. A recipe naming a device zigsaw
# doesn't know is refused.
#
#   bash tests/devices.sh [path\to\zigsaw.exe]
#
# With DEVICES_REAL=1 it also opens the camera where there is one, from the
# app under each sandbox, AND THE CAMERA'S LIGHT COMES ON: with the device a
# frame comes, without it or at low integrity none does. Last, the probe's
# report of what each sandbox reaches on this machine, without the camera and
# microphone rows unless DEVICES_REAL=1. With LOG_DIR set, the report is also
# left there.
#
# Needs Git Bash and zig (for the probe). Takes about half a minute.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
work=$(cygpath -w "$(mktemp -d)")
ZIGSAW_HOME="$work\\store"
export ZIGSAW_HOME
suite_key="Software\\ZigsawTest\\devices-$$-grants"
export ZIGSAW_GRANTS_KEY="$suite_key"
mkdir -p "$work\\folders\\Documents"
export ZIGSAW_USER_FOLDERS="$work\\folders"
APP=test.devices
PLAIN=test.devices.plain

failures=0
check() {
    local label=$1
    shift
    local out
    if out=$("$@" 2>&1); then
        printf 'ok    %s\n' "$label"
    else
        printf 'FAIL  %s\n      %s\n' "$label" "$(grep -v '^\s*$' <<<"$out" | tail -2 | tr '\n' ' ' | cut -c1-160)"
        failures=$((failures + 1))
    fi
}
z() { timeout 120 "$zigsaw" "$@"; }

(cd "$(cygpath -u "$root")" && zig build devprobe) || { echo "building the device probe failed"; exit 1; }
probe_dir="$work\\devprobe"
mkdir -p "$probe_dir" && cp "$root\\zig-out\\test\\zigsaw-devprobe.exe" "$probe_dir\\"
probe="$probe_dir\\zigsaw-devprobe.exe"
# The capability a run with the camera holds: the SID of the camera's device
# class, not the one Windows derives from the name "webcam".
camera_sid=$("$probe" sids | tr -d '\r' | awk '$1 == "camera" { print $4 }')
webcam_name_sid=$("$probe" sids | tr -d '\r' | awk '$1 == "camera" { print $3 }')
[ -n "$camera_sid" ] || { echo "the probe names no capability for the camera"; exit 1; }
# Apps run from a directory of the suite's own.
mkdir -p "$work\\cwd" && cd "$(cygpath -u "$work\\cwd")" || exit 1

recipe() {
    printf '{ "id": "%s", "version": "1", "command": "zigsaw-devprobe.exe", "args": ["token"],%s\n  "modules": [{ "name": "probe", "sources": [{ "path": "zigsaw-devprobe.exe" }] }] }\n' \
        "$1" "$2" >"$probe_dir\\$1.json"
}
recipe $APP '
  "permissions": { "devices": ["camera"] },'
recipe $PLAIN ''
built_app=$(z build "$probe_dir\\$APP.json" 2>&1) || { echo "$built_app"; exit 1; }
built_plain=$(z build "$probe_dir\\$PLAIN.json" 2>&1) || { echo "$built_plain"; exit 1; }

AC=--sandbox=appcontainer
# token <run options...> <app>: the probe's lines about its own token, and
# zigsaw's notes.
token() { z run "$@" 2>&1 | tr -d '\r'; }
# holds <how many capabilities> <camera: yes|no> <run options...> <app>
holds() {
    local count=$1 camera=$2 out
    shift 2
    out=$(token "$@")
    grep -q '^# integrity low, in an AppContainer$' <<<"$out" || { echo "not in an AppContainer: $out"; return 1; }
    [ "$(grep -c '^capability ' <<<"$out")" = "$count" ] || { echo "not $count capabilities: $out"; return 1; }
    if [ "$camera" = yes ]; then
        grep -qx "capability $camera_sid" <<<"$out" || { echo "no camera capability: $out"; return 1; }
    else
        ! grep -qx "capability $camera_sid" <<<"$out" || { echo "a camera capability: $out"; return 1; }
    fi
    ! grep -qx "capability $webcam_name_sid" <<<"$out" || { echo "the capability by name, which opens nothing: $out"; return 1; }
}

# --- In an AppContainer ------------------------------------------------------

check "an app with the camera holds its capability, and its own" holds 2 yes $AC $APP
check "an app with no device holds only its own" holds 1 no $AC $PLAIN
check "with the network too: the camera's, its own and the network's two" holds 4 yes $AC --share=network $APP

# --- Changing the list -------------------------------------------------------

check "--device=camera gives an app the camera" holds 2 yes $AC --device=camera $PLAIN
check "--nodevice=camera takes the app's away" holds 1 no $AC --nodevice=camera $APP
check "--device of what it has changes nothing" holds 2 yes $AC --device=Camera $APP
overrides() {
    local ok=0
    z override --device=camera $PLAIN >/dev/null || return 1
    holds 2 yes $AC $PLAIN || ok=1
    # The command line takes it away again.
    holds 1 no $AC --nodevice=camera $PLAIN || ok=1
    z override --reset $PLAIN >/dev/null
    z override --global --nodevice=camera >/dev/null || return 1
    holds 1 no $AC $APP || ok=1
    # The app's own override over the store-wide one.
    z override --device=camera $APP >/dev/null || return 1
    holds 2 yes $AC $APP || ok=1
    z override --reset $APP >/dev/null
    z override --global --reset >/dev/null
    holds 2 yes $AC $APP || ok=1
    return $ok
}
check "an override saves it, --global too, under the app's and the command line" overrides
saved() {
    z override --device=camera --env=A=1 $PLAIN >/dev/null || return 1
    grep -q '"devices"' "$ZIGSAW_HOME\\overrides\\$PLAIN.json" || { echo "not saved"; return 1; }
    z override --reset $PLAIN >/dev/null
    # Without one, the file is as a zigsaw before devices wrote it.
    z override --env=A=1 $PLAIN >/dev/null || return 1
    ! grep -q device "$ZIGSAW_HOME\\overrides\\$PLAIN.json" || { echo "a device in an override without one"; return 1; }
    z override --reset $PLAIN >/dev/null
}
check "an override without a device is saved without the word" saved
unknown_option() {
    local out
    out=$(z run $AC --device=microphone $PLAIN 2>&1) && { echo "ran"; return 1; }
    grep -q "takes a device zigsaw knows, which is only camera" <<<"$out" || { echo "got: $out"; return 1; }
}
check "--device takes only a device zigsaw knows" unknown_option

# --- The relay ---------------------------------------------------------------

relay() {
    # A list of hosts has the run start its relay, the proxy.
    timeout 60 "$zigsaw" run $AC --allow-host=127.0.0.1:9 --command=zigsaw-devprobe.exe $APP wait 5000 >/dev/null 2>&1 &
    local run=$! out
    sleep 2
    out=$("$probe" tokens "$ZIGSAW_HOME" | tr -d '\r')
    wait $run
    local app relay
    app=$(awk '/^# process /{ on = ($3 == "zigsaw-devprobe.exe") } on' <<<"$out")
    # The store's copy of the relay has its hash in its name.
    relay=$(awk '/^# process /{ on = ($3 ~ /^zigsaw-relay/) } on' <<<"$out")
    grep -qx "capability $camera_sid" <<<"$app" || { echo "the app holds no camera: $out"; return 1; }
    grep -q 'in an AppContainer' <<<"$relay" || { echo "no relay in a container: $out"; return 1; }
    [ "$(grep -c '^capability ' <<<"$relay")" = 1 ] || { echo "the relay holds more than the app's own: $relay"; return 1; }
}
check "the run's relay holds no device" relay

# --- Low and soft ------------------------------------------------------------

noted() {
    local pattern=$1 out
    shift
    out=$(token "$@")
    grep -q "$pattern" <<<"$out" || { echo "got: $out"; return 1; }
}
quiet() {
    local out
    out=$(token "$@")
    ! grep -q '^note: ' <<<"$out" || { echo "got: $out"; return 1; }
}
check "under low: a note that Windows opens the camera for no program there" \
    noted "gets no camera under the low sandbox" --sandbox=low $APP
check "under low: an app with no device runs without a note" quiet --sandbox=low $PLAIN
check "under low: with the camera taken away, no note" quiet --sandbox=low --nodevice=camera $APP
check "under soft: a list you changed gets a note that it isn't enforced" \
    noted "devices aren't enforced under the soft sandbox" --sandbox=soft --nodevice=camera $APP
check "under soft: the app's own list runs without a note" quiet --sandbox=soft $APP
check "in an AppContainer: no note" quiet $AC $APP

# --- What the app may use, in words ------------------------------------------

permits() {
    grep -q 'permits  your camera' <<<"$built_app" || { echo "got: $built_app"; return 1; }
    ! grep -q camera <<<"$built_plain" || { echo "a camera for the app without one: $built_plain"; return 1; }
}
check "installing says the app may use your camera" permits

# --- Recipes -----------------------------------------------------------------

refused() {
    local name=$1 devices=$2 pattern=$3 out
    recipe "$name" '
  "permissions": { "devices": '"$devices"' },'
    out=$(z build "$probe_dir\\$name.json" 2>&1) && { echo "built"; return 1; }
    grep -q "$pattern" <<<"$out" || { echo "got: $out"; return 1; }
}
check "a recipe with a device zigsaw doesn't know is refused" \
    refused test.devices.unknown '["camera", "microphone"]' "device \"microphone\" isn't one zigsaw knows"
check "a recipe with an empty list is refused" refused test.devices.empty '[]' "devices must name at least one device"
check "a recipe that lists a device twice is refused" refused test.devices.twice '["camera", "camera"]' "listed twice"

# --- A real camera -----------------------------------------------------------

# camera <outcome pattern> <run options...> <app>: the probe's camera check,
# as the app.
camera() {
    local pattern=$1 out
    shift
    out=$(z run "${@:1:$#-1}" --command=zigsaw-devprobe.exe "${@: -1}" check camera 2>&1 | tr -d '\r')
    grep -qE "^camera $pattern" <<<"$out" || { echo "got: $out"; return 1; }
}
if [ "${DEVICES_REAL:-}" = 1 ]; then
    if "$probe" check camera 2>/dev/null | grep -q '^camera ok'; then
        check "real: with the camera, a frame comes in an AppContainer" camera 'ok \(a frame' $AC $APP
        check "real: --device=camera gives an app without it a frame" camera 'ok \(a frame' $AC --device=camera $PLAIN
        check "real: without the camera, none does" camera 'denied' $AC $PLAIN
        check "real: --nodevice=camera takes it away" camera 'denied' $AC --nodevice=camera $APP
        check "real: at low integrity Windows opens no camera, device or not" camera 'denied' --sandbox=low $APP
        check "real: under soft a frame comes, device or not" camera 'ok \(a frame' --sandbox=soft $PLAIN
    else
        echo "skip  real: this machine has no camera that opens"
    fi
fi

# --- The probe's report ------------------------------------------------------

echo "The probe's report (tests/devprobe.zig):"
if [ "${DEVICES_REAL:-}" = 1 ]; then
    report=$("$probe" report 2>&1 | tr -d '\r')
else
    report=$("$probe" report location bluetooth hid usb serial speakers gpu printer smartcard 2>&1 | tr -d '\r')
fi
sed 's/^/  /' <<<"$report"
if [ -n "${LOG_DIR:-}" ]; then echo "$report" >"$LOG_DIR\\devprobe.txt"; fi

cd / || true
z rm --delete-data $APP >/dev/null 2>&1
z rm --delete-data $PLAIN >/dev/null 2>&1
reg delete "HKCU\\$suite_key" /f >/dev/null 2>&1
rm -rf "$work"
echo "$failures check(s) failed."
[ $failures = 0 ]
