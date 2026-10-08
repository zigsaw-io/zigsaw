#!/usr/bin/env bash
# GTK end to end: an app built against GTK's SDK image (org.gtk.Gtk4.Sdk),
# with Meson and zig, runs on GTK's runtime image (org.gtk.Gtk4), with
# libadwaita, opens a window, draws a frame and quits, in each sandbox; it
# gets HTTPS URLs with libsoup and loads an SVG with librsvg's loader; the
# runtime's own tools run too, its demos get the windowless shim and Start
# menu shortcuts (in a temporary folder), and GNOME Text Editor
# (recipes/gnome-text-editor.json) starts up in each sandbox.
#
# Not in CI: the SDK takes a quarter of an hour to build, and the runner has
# no GPU for the OpenGL check.
#
#   GTK_HOME=path\to\store bash tests/gtk.sh [path\to\zigsaw.exe]
#
# Building GTK's SDK takes about 15 minutes, so this uses a store that has
# both GTK images and the SDK images the app builds with (GTK_HOME, or
# BUILD_HOME as tests/published.sh leaves it), and says so and stops if
# neither has them. It installs its app there, and removes it afterwards;
# it builds Text Editor there too unless the store has it (a few minutes),
# and then removes it. The apps open windows on the desktop for a moment.

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
EDITOR=org.gnome.TextEditor
# Start menu shortcuts go here rather than the user's Start menu.
links="$work\\links"
export ZIGSAW_SHORTCUTS_DIR="$links"

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

cp "$root\\tests\\gtk\\hello.c" "$root\\tests\\gtk\\soup.c" "$root\\tests\\gtk\\svg.c" "$root\\tests\\gtk\\meson.build" "$work\\"
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
adwaita() { timeout 120 "$zigsaw" run $APP 2>&1 | tr -d '\r' | grep -q '^libadwaita 1\.10\.0$'; }
check "the runtime has libadwaita 1.10.0" adwaita
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

# libsoup, with GIO's TLS from glib-networking's OpenSSL module, which trusts
# Windows' root certificates. ghcr.io answers 401 to anonymous requests.
soup() {
    local out
    out=$(timeout 120 "$zigsaw" run "$@" --command=bin/soup-get.exe $APP https://ghcr.io/v2/ https://untrusted-root.badssl.com/ 2>&1 | tr -d '\r')
    grep -q '^libsoup 3\.8\.0$' <<<"$out" && grep -q '^tls backend GTlsBackendOpenssl$' <<<"$out" &&
        grep -qF 'GET https://ghcr.io/v2/: 401 over HTTP/2' <<<"$out" &&
        grep -qF 'GET https://untrusted-root.badssl.com/: error: Unacceptable TLS certificate' <<<"$out" || { echo "got: $out"; return 1; }
}
check "libsoup 3.8.0 gets an HTTPS URL over HTTP/2, trusting Windows' root certificates, and refuses an untrusted root" soup
check "with --sandbox=low" soup --sandbox=low
check "with --sandbox=appcontainer" soup --sandbox=appcontainer
psl() { timeout 60 "$zigsaw" run --command=bin/soup-get.exe $APP 2>&1 | tr -d '\r' | grep -q '^base domain of www\.example\.co\.uk is example\.co\.uk$'; }
check "libsoup knows the Public Suffix List (libpsl)" psl
# An SVG through GdkPixbuf, as GtkBuilder loads images: librsvg's loader.
printf '%s\n' '<svg xmlns="http://www.w3.org/2000/svg" width="48" height="32"><rect width="48" height="32" fill="teal"/></svg>' >"$work\\t.svg"
check "GdkPixbuf loads an SVG with librsvg's loader" sh -c "timeout 60 \"\$0\" run --command=bin/svg-size.exe $APP t.svg | grep -q '^loaded 48x32'" "$zigsaw"
# The SDK's rsvg-convert, a Rust program GNU ld links: all its imports bound
# (tests/imports.zig), it makes a PNG of the SVG.
sdk_manifest="$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of org.gtk.Gtk4.Sdk | cut -d: -f2)"
sdk="$ZIGSAW_HOME\\deploy\\$(grep -o 'sha256:[0-9a-f]*' "$sdk_manifest" | tail -1 | cut -d: -f2)"
rsvg_convert() {
    (cd "$root" && zig build imports) >/dev/null || return 1
    "$root\\zig-out\\test\\zigsaw-imports.exe" "$sdk\\bin\\rsvg-convert.exe" || return 1
    # Piped: given a file as stdin, rsvg-convert reads only its first two
    # bytes, run by zigsaw or not.
    cat "$work\\t.svg" | timeout 60 "$zigsaw" run --command=bin/rsvg-convert.exe org.gtk.Gtk4.Sdk | head -c 8 | od -A n -t x1 | tr -d ' \n' | grep -qx '89504e470d0a1a0a'
}
check "the SDK's rsvg-convert binds all its imports and converts an SVG to PNG" rsvg_convert
# The runtime keeps GIO's modules and GdkPixbuf's loaders from the SDK's lib
# directory, and none of its libraries for linking.
runtime_manifest="$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of org.gtk.Gtk4 | cut -d: -f2)"
runtime="$ZIGSAW_HOME\\deploy\\$(grep -o 'sha256:[0-9a-f]*' "$runtime_manifest" | tail -1 | cut -d: -f2)"
runtime_lib() {
    test -f "$runtime\\lib\\gio\\modules\\libgioopenssl.dll" && test -f "$runtime\\lib\\gdk-pixbuf-2.0\\2.10.0\\loaders\\pixbufloader_svg.dll" || return 1
    [ -z "$(find "$(cygpath -u "$runtime")" -name '*.a' -o -name '*.pc' -o -name '*.h' | head -1)" ]
}
check "the runtime has GIO's modules and GdkPixbuf's loaders, and no headers or libraries for linking" runtime_lib

# GUI programs get the shim that opens no console, and declared shortcuts.
# Installing the runtime again (from the build cache) puts its shortcuts in
# the test's folder.
z build "$root\\recipes\\gtk4.json" >/dev/null 2>&1
shim_dir=$(dirname "$zigsaw")
shim_is() { cmp -s "$ZIGSAW_HOME\\bin\\$1.exe" "$shim_dir\\$2"; }
gui_shims() { shim_is gtk4-demo zigsaw-shimw.exe && shim_is adwaita-1-demo zigsaw-shimw.exe && shim_is gtk4-query-settings zigsaw-shim.exe; }
check "the demos get the windowless shim, gtk4-query-settings the console one" gui_shims
check "the runtime's demos get shortcuts" test -f "$links\\GTK Demo.lnk" -a -f "$links\\Adwaita Demo.lnk"
# stays_up <seconds> <zigsaw run arguments...>: the app is still running
# when the time is up, rather than having crashed or failed a check.
stays_up() {
    local seconds=$1
    shift
    timeout "$seconds" "$zigsaw" run --env=G_DEBUG=fatal-criticals "$@" >/dev/null 2>&1
    [ $? -eq 124 ]
}
check "the Adwaita demo runs" stays_up 15 --command=adwaita-1-demo org.gtk.Gtk4
# It aborted at startup without an SVG loader (iteration 11).
check "GTK's widget factory runs" stays_up 15 --command=gtk4-widget-factory org.gtk.Gtk4
check "it gets the windowless shim and a shortcut" sh -c "cmp -s '$ZIGSAW_HOME\\bin\\gtk4-widget-factory.exe' '$shim_dir\\zigsaw-shimw.exe' && test -f '$links\\GTK Widget Factory.lnk'"

# GNOME Text Editor, on the runtime. Built here unless the store has it,
# which takes a few minutes.
installed_editor=false
if [ ! -f "$ZIGSAW_HOME\\refs\\$EDITOR.json" ]; then
    z build "$root\\recipes\\gnome-text-editor.json" >"$work\\editor.log" 2>&1 || echo "building $EDITOR failed: $(tail -1 "$work\\editor.log")"
    installed_editor=true
else
    z build "$root\\recipes\\gnome-text-editor.json" >/dev/null 2>&1
fi
editor_version() { timeout 60 "$zigsaw" run $EDITOR --version | tr -d '\r' | grep -q '^Text Editor 51\.0 '; }
check "Text Editor 51.0 is installed" editor_version
check "it gets the windowless shim and a shortcut" sh -c "cmp -s '$ZIGSAW_HOME\\bin\\gnome-text-editor.exe' '$shim_dir\\zigsaw-shimw.exe' && test -f '$links\\Text Editor.lnk'"
check "it runs" stays_up 15 $EDITOR --standalone
check "with --sandbox=low" stays_up 15 --sandbox=low $EDITOR --standalone
check "with --sandbox=appcontainer" stays_up 15 --sandbox=appcontainer $EDITOR --standalone

cd "$root" || exit 1
$installed_editor && z rm --delete-data $EDITOR >/dev/null 2>&1
z rm --delete-data $APP >/dev/null 2>&1
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
