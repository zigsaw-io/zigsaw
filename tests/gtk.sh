#!/usr/bin/env bash
# GTK end to end: an app built against GTK's SDK image (org.gtk.Gtk4.Sdk),
# with Meson and zig, runs on GTK's runtime image (org.gtk.Gtk4), opens a
# window, draws a frame and quits, in each sandbox; the runtime's own tools
# run too.
#
#   GTK_HOME=path\to\store bash tests/gtk.sh [path\to\zigsaw.exe]
#
# Building GTK's SDK takes about 15 minutes, so this uses a store that has
# both GTK images and the SDK images the app builds with (GTK_HOME, or
# BUILD_HOME as tests/published.sh leaves it), and says so and stops if
# neither has them. It installs its app there, and removes it afterwards.
# The app opens a small window on the desktop for a moment, three times.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
ZIGSAW_HOME=${GTK_HOME:-${BUILD_HOME:-}}
if [ -z "$ZIGSAW_HOME" ] || [ ! -f "$ZIGSAW_HOME\\refs\\org.gtk.Gtk4.json" ] || [ ! -f "$ZIGSAW_HOME\\refs\\org.gtk.Gtk4.Sdk.json" ]; then
    echo "tests/gtk.sh needs a store with org.gtk.Gtk4 and org.gtk.Gtk4.Sdk in GTK_HOME or BUILD_HOME;"
    echo "build recipes\\gtk4-sdk.json and recipes\\gtk4.json into one first."
    exit 1
fi
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
APP=test.gtk.hello

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

cp "$root\\tests\\gtk\\hello.c" "$root\\tests\\gtk\\meson.build" "$work\\"
sed -e "s/@GTK@/$(manifest_of org.gtk.Gtk4)/" -e "s/@GTKSDK@/$(manifest_of org.gtk.Gtk4.Sdk)/" \
    -e "s/@MESON@/$(manifest_of com.mesonbuild.meson)/" -e "s/@ZIG@/$(manifest_of org.ziglang.zig)/" \
    -e "s/@BUSYBOX@/$(manifest_of net.frippery.busybox)/" "$root\\tests\\gtk\\hello.json.in" >"$work\\hello.json"

check "an app builds against GTK's SDK image, finding gtk4 with pkg-config" z build "$work\\hello.json"
# Runs from the work directory: the runtime has the cwd permission.
cd "$work" || exit 1
drew() {
    local out
    out=$(timeout 120 "$zigsaw" run "$@" $APP 2>&1 | tr -d '\r')
    grep -q '^GTK 4\.24\.1$' <<<"$out" && grep -q '^drew a frame with Gsk' <<<"$out" || { echo "got: $out"; return 1; }
}
check "it runs on GTK's runtime: opens a window and draws a frame" drew
check "with --sandbox=low" drew --sandbox=low
check "with --sandbox=appcontainer" drew --sandbox=appcontainer
check "with GDK_DEBUG=dcomp, GTK draws with OpenGL" sh -c "timeout 120 \"\$0\" run --env=GDK_DEBUG=dcomp $APP 2>&1 | grep -q '^drew a frame with GskGLRenderer'" "$zigsaw"
settings() { timeout 60 "$zigsaw" run --command=gtk4-query-settings org.gtk.Gtk4 | grep -q 'gtk-theme-name: "Default"'; }
check "the runtime's gtk4-query-settings reads GTK's settings" settings
check "its gtk4-demo is GTK 4.24.1" sh -c "timeout 60 \"\$0\" run --command=gtk4-demo org.gtk.Gtk4 --version | grep -q 'gtk4-demo.exe 4.24.1'" "$zigsaw"
# The runtime's variables keep GLib's files and settings in the app's data
# directory, rather than the user's AppData (where GLib looks with
# SHGetKnownFolderPath) or the registry (GLib's default for settings).
xdg() {
    local out
    out=$(timeout 120 "$zigsaw" run $APP 2>&1 | tr -d '\r')
    grep -qF "config in $ZIGSAW_HOME\\data\\$APP\\config" <<<"$out" || { echo "got: $out"; return 1; }
    grep -q '^settings in GKeyfileSettingsBackend$' <<<"$out" || { echo "got: $out"; return 1; }
}
check "GLib keeps its files in the app's data directory, and settings in a key file there" xdg

cd "$root" || exit 1
z rm --delete-data $APP >/dev/null 2>&1
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
