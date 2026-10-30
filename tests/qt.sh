#!/usr/bin/env bash
# Qt end to end: an app built against Qt's SDK image (io.qt.Qt6.Sdk), with
# CMake and llvm-mingw's Clang, runs on Qt's runtime image (io.qt.Qt6),
# opens a window and paints it, in each sandbox; Qt finds its plugins and
# translations in the runtime's deployment (it's relocatable), has the SVG,
# WebP and TIFF image plugins and Schannel for TLS, and keeps an app's files
# in its data directory. A Qt Quick program of the same app draws a window of Controls
# with Direct3D 11 in each sandbox, with Qt's QML modules from the runtime,
# which has the Controls styles it should.
# The SDK's exports build a Qt program without a recipe (CMake, finding Qt
# through the SDK's CMAKE_PREFIX_PATH). The runtime's qml tool runs a QML
# file; its Designer and Linguist open their windows in each sandbox (its
# qt.conf points Qt at the runtime's plugins), and get the windowless shim
# and Start menu shortcuts (in a temporary folder). Flameshot
# (recipes/flameshot.json) runs in its tray in each sandbox (in an
# AppContainer, Qt's patched QLocalServer lets its single-instance check
# listen), and its `full` command saves a screenshot in the Pictures folder.
# Notes (recipes/notes.json) opens its window in each sandbox, loads its
# QML without errors, and keeps its database in its data directory.
#
# In CI (the Reproduce workflow's qt-suites job), it runs in a store of the
# published images (tests/seed-store.sh), which it installs again rather
# than building.
#
#   QT_HOME=path\to\store bash tests/qt.sh [path\to\zigsaw.exe]
#
# Building Qt's SDK takes over an hour, so this uses a store that has both
# Qt images (QT_HOME, or BUILD_HOME as tests/published.sh leaves it), and
# says so and stops if neither has them. It installs its app there, and
# removes it afterwards; it builds Flameshot and Notes there too unless the
# store has them (a few minutes), and then removes them. The apps open
# windows on the desktop for a moment.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
ZIGSAW_HOME=${QT_HOME:-${BUILD_HOME:-}}
if [ -z "$ZIGSAW_HOME" ] || [ ! -f "$ZIGSAW_HOME\\refs\\io.qt.Qt6.json" ] || [ ! -f "$ZIGSAW_HOME\\refs\\io.qt.Qt6.Sdk.json" ]; then
    echo "tests/qt.sh needs a store with io.qt.Qt6 and io.qt.Qt6.Sdk in QT_HOME or BUILD_HOME;"
    echo "build recipes\\qt6-sdk.json and recipes\\qt6.json into one first."
    exit 1
fi
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
APP=test.qt.hello
FLAMESHOT=org.flameshot.Flameshot
NOTES=io.github.nuttyartist.notes
# Start menu shortcuts go here rather than the user's Start menu.
links="$work\\links"
export ZIGSAW_SHORTCUTS_DIR="$links"
# The user's folders the apps may use, such as Pictures, are these, not
# yours, which low and AppContainer runs would label and grant.
for f in Documents Pictures; do mkdir -p "$work\\folders\\$f"; done
export ZIGSAW_USER_FOLDERS="$work\\folders"

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

z() { "$zigsaw" "$@"; }
manifest_of() { grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\refs\\$1.json"; }
# install_again <id> <recipe>: installs an app the store has again, as the
# store got it: from the build cache, if it built it, or the registry it was
# pulled from, so its shortcuts go to this test's folder. Builds the recipe
# if the store hasn't the app.
install_again() {
    local source=""
    [ -f "$ZIGSAW_HOME\\refs\\$1.json" ] && source=$(grep -o '"source": *"[^"]*"' "$ZIGSAW_HOME\\refs\\$1.json" | cut -d'"' -f4)
    case $source in
    "" | *.json) z build "$root\\recipes\\$2" ;;
    *) z pull --yes "$source" ;;
    esac
}

for f in hello.cpp CMakeLists.txt; do cp "$root\\tests\\qt\\$f" "$work\\"; done
cp -r "$root\\tests\\qt\\quick" "$work\\"
sed -e "s/@QT@/$(manifest_of io.qt.Qt6)/" -e "s/@QTSDK@/$(manifest_of io.qt.Qt6.Sdk)/" \
    "$root\\tests\\qt\\hello.json.in" >"$work\\hello.json"

check "an app builds against Qt's SDK image with CMake, finding Qt" z build "$work\\hello.json"
# Runs from the work directory: the app has the cwd permission.
cd "$work" || exit 1
painted() {
    local out
    out=$(timeout 120 "$zigsaw" run "$@" $APP 2>&1 | tr -d '\r')
    grep -q '^Qt 6\.12\.0$' <<<"$out" && grep -q '^painted a window with windows$' <<<"$out" || { echo "got: $out"; return 1; }
}
check "it runs on Qt's runtime: opens a window and paints it" painted
check "with --sandbox=soft" painted --sandbox=soft
check "with --sandbox=appcontainer" painted --sandbox=appcontainer
# say <label>: the line the app printed after the label, without a window.
say() { timeout 60 "$zigsaw" run $APP --no-window 2>&1 | tr -d '\r' | sed -n "s/^$1 //p"; }
# Qt finds its plugins next to Qt6Core.dll, in the runtime's deployment,
# though it was built for B:\prefix.
relocated() {
    local plugins
    plugins=$(say plugins)
    case $plugins in */deploy/*/plugins) ;; *) echo "plugins in $plugins"; return 1 ;; esac
    test -f "$plugins/platforms/qwindows.dll" || { echo "no qwindows.dll in $plugins"; return 1; }
}
check "Qt finds its plugins in the runtime's deployment" relocated
formats() {
    local f out
    out=$(say 'image formats')
    for f in png jpeg gif svg webp tiff ico; do grep -qw "$f" <<<"$out" || { echo "no $f in: $out"; return 1; }; done
}
check "it reads PNG, JPEG, GIF, SVG, WebP, TIFF and ICO images" formats
check "it has Schannel for TLS" sh -c "\"\$0\" run $APP --no-window 2>&1 | tr -d '\r' | grep -q '^tls backends .*schannel'" "$zigsaw"
check "qtbase's French catalogue translates a string" sh -c "\"\$0\" run $APP --no-window 2>&1 | tr -d '\r' | grep -q '^Cancel in French: Annuler$'" "$zigsaw"
# QStandardPaths finds AppData through the profile, which runs have in the
# app's data directory.
app_data() {
    local out
    out=$(say 'app data' | tr '/' '\\')
    case $out in "$ZIGSAW_HOME\\data\\$APP\\"*) ;; *) echo "app data in $out"; return 1 ;; esac
}
check "it keeps its files in the app's data directory" app_data

# Qt Quick: a window of Controls from the app's own QML module (compiled
# with qmlcachegen), drawn by the scene graph and read back, in each
# sandbox. Qt finds the Controls' QML modules in the runtime's deployment.
quick() {
    local out
    out=$(timeout 120 "$zigsaw" run "$@" --command=hello-quick $APP 2>&1 | tr -d '\r')
    grep -q '^drew a frame with Direct3D11, corner #3a7bd5$' <<<"$out" || { echo "got: $out"; return 1; }
}
check "a Qt Quick app draws its window of Controls with Direct3D 11" quick
check "with --sandbox=soft" quick --sandbox=soft
check "with --sandbox=appcontainer" quick --sandbox=appcontainer
quick_imports() {
    local qml
    qml=$(timeout 60 "$zigsaw" run --command=hello-quick $APP 2>&1 | tr -d '\r' | sed -n 's/^qml //p')
    case $qml in */deploy/*/qml) ;; *) echo "qml in $qml"; return 1 ;; esac
    test -f "$qml/QtQuick/Controls/qmldir" || { echo "no QtQuick/Controls in $qml"; return 1; }
}
check "Qt finds QML modules in the runtime's deployment" quick_imports
# The Controls styles Windows uses (Basic, and Fusion, FluentWinUI3 and
# Windows on it) are there, and those apps choose that Notes does (Material,
# Universal); the SDK leaves out Imagine and Qt Labs StyleKit.
styles() {
    local qml s
    qml=$(timeout 60 "$zigsaw" run --command=hello-quick $APP 2>&1 | tr -d '\r' | sed -n 's/^qml //p')
    for s in Basic Fusion FluentWinUI3 Windows Material Universal; do
        test -f "$qml/QtQuick/Controls/$s/qmldir" || { echo "no $s style in $qml"; return 1; }
    done
    for s in QtQuick/Controls/Imagine Qt/labs/StyleKit; do
        test ! -e "$qml/$s" || { echo "$qml/$s is there"; return 1; }
    done
}
check "it has the Controls styles for Windows, and Material and Universal, but not Imagine or StyleKit" styles
# The runtime's qml tool runs a QML file. Its console.log goes to stderr
# only when Qt is told to (it isn't a console program).
printf '%s\n' 'import QtQuick' 'Window {' '    visible: true' \
    '    Timer { interval: 200; running: true; onTriggered: { console.log("ran on " + Qt.platform.os); Qt.quit() } }' \
    '}' >"$work\\ran.qml"
check "the runtime's qml tool runs a QML file" sh -c "timeout 60 \"\$0\" run --env=QT_FORCE_STDERR_LOGGING=1 --command=qml io.qt.Qt6 ran.qml 2>&1 | tr -d '\r' | grep -q 'ran on windows'" "$zigsaw"

# Building without a recipe: the SDK's exports, from the store's bin, as
# cmake (with its ninja, llvm-mingw's c++ and windres); the program then
# runs on the runtime. The first app installed keeps a command's name: in a store that
# had CMake's own image first, the `cmake` shim runs that one, which has
# neither a compiler nor Qt (CI's qt-suites job seeded it so once), so then this
# runs the SDK's as its shim would. On failure, CMake's output is kept in
# LOG_DIR.
mkdir -p "$work\\loose" && cp "$work\\hello.cpp" "$work\\CMakeLists.txt" "$work\\loose\\"
bin="$ZIGSAW_HOME\\bin"
loose_cmake() {
    local cmake=("$bin\\cmake.exe")
    [ "$(sed -n 's/^app = //p' "$bin\\cmake.shim" | tr -d '\r')" = io.qt.Qt6.Sdk ] || cmake=("$zigsaw" run --command=cmake io.qt.Qt6.Sdk)
    (cd "$work\\loose" && "${cmake[@]}" -S . -B out -DCMAKE_BUILD_TYPE=Release && "${cmake[@]}" --build out) >"$work\\loose.log" 2>&1 || {
        [ -z "${LOG_DIR:-}" ] || cp "$work\\loose.log" "$LOG_DIR\\qt-loose-cmake.log"
        tail -5 "$work\\loose.log"
        return 1
    }
    local out
    out=$(cd "$work\\loose" && timeout 120 "$zigsaw" run --command="$work\\loose\\out\\hello-qt.exe" io.qt.Qt6 2>&1 | tr -d '\r')
    grep -q '^painted a window with windows$' <<<"$out" || { echo "got: $out"; return 1; }
}
check "the SDK's cmake builds a Qt program, which runs on the runtime" loose_cmake

# GUI programs get the shim that opens no console, and declared shortcuts.
# Installing the runtime again puts its shortcut in the test's folder.
install_again io.qt.Qt6 qt6.json >/dev/null 2>&1
shim_dir=$(dirname "$zigsaw")
shim_is() { cmp -s "$ZIGSAW_HOME\\bin\\$1.exe" "$shim_dir\\$2"; }
gui_shims() { shim_is designer zigsaw-shimw.exe && shim_is linguist zigsaw-shimw.exe && shim_is pixeltool zigsaw-shimw.exe && shim_is qtdiag zigsaw-shim.exe; }
check "Designer, Linguist and Pixeltool get the windowless shim, qtdiag the console one" gui_shims
check "Designer and Linguist get shortcuts" test -f "$links\\Qt Widgets Designer.lnk" -a -f "$links\\Qt Linguist.lnk"
# stays_up <seconds> <zigsaw run arguments...>: the app is still running
# when the time is up, rather than having crashed.
stays_up() {
    local seconds=$1
    shift
    timeout "$seconds" "$zigsaw" run "$@" >/dev/null 2>&1
    [ $? -eq 124 ]
}
# app_window <process> <title> <zigsaw run arguments...>: the program's
# main window comes up, rather than Qt's error box for a missing plugin,
# which would keep it running too.
app_window() {
    local process=$1 want=$2 title=""
    shift 2
    ("$zigsaw" run "$@" >/dev/null 2>&1 &)
    for _ in $(seq 30); do
        title=$(powershell -NoProfile -Command "(Get-Process $process -ErrorAction SilentlyContinue | Where-Object MainWindowTitle | Select-Object -First 1).MainWindowTitle" | tr -d '\r')
        [ -n "$title" ] && break
        sleep 1
    done
    powershell -NoProfile -Command "Get-Process $process -ErrorAction SilentlyContinue | Stop-Process -Force"
    sleep 1
    [ "$title" = "$want" ] || { echo "window: $title"; return 1; }
}
designer_window() { app_window designer "Qt Widgets Designer" "$@" io.qt.Qt6; }
linguist_window() { app_window linguist "Qt Linguist" "$@" --command=linguist io.qt.Qt6; }
check "Designer opens its window" designer_window
check "with --sandbox=soft" designer_window --sandbox=soft
check "with --sandbox=appcontainer" designer_window --sandbox=appcontainer
check "Linguist, on Qt Quick, opens its window" linguist_window
check "with --sandbox=soft" linguist_window --sandbox=soft
check "with --sandbox=appcontainer" linguist_window --sandbox=appcontainer
# Programs in the runtime's bin, beside Qt6Core.dll, would take bin for Qt's
# prefix without its qt.conf (Qt looks for lib\libQt6Core.a to tell), and
# find no platform plugin.
check "the runtime's qtdiag finds the windows platform plugin" sh -c "timeout 60 \"\$0\" run --command=qtdiag io.qt.Qt6 2>&1 | tr -d '\r' | grep -q '^Qt 6\\.12\\.0 .* on \"windows\"'" "$zigsaw"

# Flameshot, on the runtime. Built here unless the store has it, which takes
# a few minutes.
installed_flameshot=false
if [ ! -f "$ZIGSAW_HOME\\refs\\$FLAMESHOT.json" ]; then
    z build "$root\\recipes\\flameshot.json" >"$work\\flameshot.log" 2>&1 || echo "building $FLAMESHOT failed: $(tail -1 "$work\\flameshot.log")"
    installed_flameshot=true
else
    install_again $FLAMESHOT flameshot.json >/dev/null 2>&1
fi
check "Flameshot 14.0.0 is installed" sh -c "timeout 60 \"\$0\" run $FLAMESHOT --version 2>&1 | tr -d '\r' | grep -q 'Flameshot v14\\.0\\.0'" "$zigsaw"
check "it gets the windowless shim and a shortcut" sh -c "cmp -s '$ZIGSAW_HOME\\bin\\flameshot.exe' '$shim_dir\\zigsaw-shimw.exe' && test -f '$links\\Flameshot.lnk'"
check "it runs, in the tray" stays_up 15 $FLAMESHOT
check "with --sandbox=soft" stays_up 15 --sandbox=soft $FLAMESHOT
check "with --sandbox=appcontainer" stays_up 15 --sandbox=appcontainer $FLAMESHOT
# screenshot <zigsaw run arguments...>: `flameshot full` saves a PNG of the
# whole screen in Pictures, which the app may use, and exits.
pictures="$work\\folders\\Pictures"
screenshot() {
    rm -f "$pictures"/*.png
    timeout 60 "$zigsaw" run "$@" $FLAMESHOT full --path "$pictures" >"$work\\shot.log" 2>&1 || { tail -3 "$work\\shot.log"; return 1; }
    local png
    png=$(ls "$pictures"/*.png 2>/dev/null | head -1)
    [ -n "$png" ] || { echo "no PNG in Pictures: $(tail -1 "$work\\shot.log")"; return 1; }
    head -c 8 "$png" | od -A n -t x1 | grep -q '89 50 4e 47' || { echo "$png isn't a PNG"; return 1; }
}
check "its full command saves a screenshot in Pictures" screenshot
check "with --sandbox=soft" screenshot --sandbox=soft
check "with --sandbox=appcontainer" screenshot --sandbox=appcontainer

# Notes (recipes/notes.json), on the runtime's Qt Quick: its window in each
# sandbox, its QML (the kanban board, its settings) loading without errors,
# and its notes database in its data directory. Built here unless the store
# has it, which takes a minute or two.
installed_notes=false
if [ ! -f "$ZIGSAW_HOME\\refs\\$NOTES.json" ]; then
    z build "$root\\recipes\\notes.json" >"$work\\notes.log" 2>&1 || echo "building $NOTES failed: $(tail -1 "$work\\notes.log")"
    installed_notes=true
else
    install_again $NOTES notes.json >/dev/null 2>&1
fi
check "Notes gets the windowless shim and a shortcut" sh -c "cmp -s '$ZIGSAW_HOME\\bin\\notes.exe' '$shim_dir\\zigsaw-shimw.exe' && test -f '$links\\Notes.lnk'"
notes_window() { app_window Notes Notes "$@" $NOTES; }
check "Notes opens its window" notes_window
check "with --sandbox=soft" notes_window --sandbox=soft
check "with --sandbox=appcontainer" notes_window --sandbox=appcontainer
# Qt's messages go to stderr when it's told so; a QML error names its qrc:/
# file.
notes_qml() {
    local out
    out=$(timeout 15 "$zigsaw" run --env=QT_FORCE_STDERR_LOGGING=1 $NOTES 2>&1 | tr -d '\r')
    powershell -NoProfile -Command "Get-Process Notes -ErrorAction SilentlyContinue | Stop-Process -Force"
    grep -q '^Database: connection ok$' <<<"$out" && ! grep -q 'qrc:/' <<<"$out" || { echo "got: $(grep -m3 'qrc:/\|Database' <<<"$out")"; return 1; }
}
check "its QML loads without errors, and it opens its database" notes_qml
check "it keeps its notes in its data directory" test -f "$ZIGSAW_HOME\\data\\$NOTES\\home\\AppData\\Roaming\\Awesomeness\\notes.db"

cd "$root" || exit 1
$installed_notes && z rm --delete-data $NOTES >/dev/null 2>&1
$installed_flameshot && z rm --delete-data $FLAMESHOT >/dev/null 2>&1
z rm --delete-data $APP >/dev/null 2>&1
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
