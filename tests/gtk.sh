#!/usr/bin/env bash
# GTK end to end: an app built against GTK's SDK image (org.gtk.Gtk4.Sdk),
# with Meson and zig, runs on GTK's runtime image (org.gtk.Gtk4), with
# libadwaita, opens a window, draws a frame and quits, in each sandbox; it
# gets HTTPS URLs with libsoup, loads an SVG with librsvg's loader, draws
# text in a font file with pangocairo and checks spelling with enchant; the
# runtime's own tools run too (Pango's and GIO's among them), its demos get
# the windowless shim and Start menu shortcuts (in a temporary folder); the
# SDK's exports build GTK programs without a recipe, and GNOME Text Editor
# (recipes/gnome-text-editor.json) starts up in each sandbox. Images that
# extend the runtime's extension point, its French and Vietnamese
# dictionaries and an icon, join its runs once installed. Gaphor
# (recipes/gaphor.json), a Python app on the runtime and PyGObject's, passes
# its own self-test in each sandbox. The runtime
# speaks the language LANGUAGE names; the SDK has gettext's tools and a
# windres. Rnote (recipes/rnote.json), a Rust app, converts a Xournal++
# document with its command-line program and starts up in each sandbox.
# The apps' shortcuts have icons made from their SVGs; Text Editor and Rnote
# are registered for their kinds of file (in a scratch registry key) and open
# one given with --file in each sandbox. Pinta (recipes/no-publish/pinta.json),
# a C# app, runs on the runtime and .NET's, and opens an image given with
# --file in each sandbox. GTK built with MSVC (recipes/gtk4-msvc.json) runs
# its demos, if the store has it.
#
# In CI (the Reproduce workflow's gtk-suites job), it runs in a store of the
# published images (tests/seed-store.sh), which it installs again rather
# than building; the runner has no GPU, so the OpenGL check is a known gap
# there.
#
#   GTK_HOME=path\to\store bash tests/gtk.sh [path\to\zigsaw.exe]
#
# Building GTK's SDK takes about 15 minutes, so this uses a store that has
# both GTK images and the SDK images the app builds with (GTK_HOME, or
# BUILD_HOME as tests/published.sh leaves it), and says so and stops if
# neither has them. It installs its app there, and removes it afterwards;
# it builds Text Editor there too unless the store has it (a few minutes),
# and then removes it, as it does Rnote, Pinta and .NET's images. The apps
# open windows on the desktop for a moment.

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
RNOTE=com.github.flxzt.rnote
# Start menu shortcuts go here rather than the user's Start menu.
links="$work\\links"
export ZIGSAW_SHORTCUTS_DIR="$links"
# File associations go under this key of HKCU rather than Software\Classes.
classes="Software\\ZigsawTest\\gtk-$$"
export ZIGSAW_CLASSES_KEY="$classes"
# The user's folders the apps may use, such as Documents, are these, not
# yours, which low and AppContainer runs would label and grant.
for f in Desktop Documents Downloads Pictures; do mkdir -p "$work\\folders\\$f"; done
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
# pulled from (as the Reproduce workflow's store pulls the published
# images), so its shortcuts and file associations go to this test's folder
# and registry key. Builds the recipe if the store hasn't the app.
install_again() {
    local source=""
    [ -f "$ZIGSAW_HOME\\refs\\$1.json" ] && source=$(grep -o '"source": *"[^"]*"' "$ZIGSAW_HOME\\refs\\$1.json" | cut -d'"' -f4)
    case $source in
    "" | *.json) z build "$root\\recipes\\$2" ;;
    *) z pull --yes "$source" ;;
    esac
}

for f in hello.c soup.c svg.c spell.c font.c icon.c meson.build; do cp "$root\\tests\\gtk\\$f" "$work\\"; done
sed -e "s/@GTK@/$(manifest_of org.gtk.Gtk4)/" -e "s/@GTKSDK@/$(manifest_of org.gtk.Gtk4.Sdk)/" \
    "$root\\tests\\gtk\\hello.json.in" >"$work\\hello.json"

check "an app builds against GTK's SDK image, finding gtk4 with pkg-config" z build "$work\\hello.json"
# Runs from the work directory: the runtime has the cwd permission.
cd "$work" || exit 1
drew() {
    local out
    out=$(timeout 120 "$zigsaw" run "$@" $APP 2>&1 | tr -d '\r')
    grep -q '^GTK 4\.24\.1$' <<<"$out" && grep -q '^drew a frame with Gsk' <<<"$out" || { echo "got: $out"; return 1; }
}
check "it runs on GTK's runtime: opens a window and draws a frame" drew
check "with --sandbox=soft" drew --sandbox=soft
check "with --sandbox=appcontainer" drew --sandbox=appcontainer
adwaita() { timeout 120 "$zigsaw" run $APP 2>&1 | tr -d '\r' | grep -q '^libadwaita 1\.10\.0$'; }
check "the runtime has libadwaita 1.10.0" adwaita
# A machine without a GPU, as a CI runner, has only Windows' basic display
# adapter, and GTK falls back to cairo: a known gap there.
gl_frame() { timeout 120 "$zigsaw" run --env=GDK_DEBUG=dcomp $APP 2>&1 | tr -d '\r' | grep -q '^drew a frame with GskGLRenderer'; }
gpus=$(powershell -NoProfile -Command "(Get-CimInstance Win32_VideoController).Name" | tr -d '\r' | grep -v -i -e '^$' -e 'basic display' -e 'basic render' -e 'hyper-v')
if [ -n "$gpus" ] || gl_frame; then
    check "with GDK_DEBUG=dcomp, GTK draws with OpenGL" gl_frame
else
    printf 'gap   %s  (known gap: no GPU)\n' "with GDK_DEBUG=dcomp, GTK draws with OpenGL"
fi
settings() {
    local out rc
    out=$(timeout 60 "$zigsaw" run --command=gtk4-query-settings org.gtk.Gtk4 2>&1)
    rc=$?
    grep -q 'gtk-theme-name: "Default"' <<<"$out" || { echo "exit status $rc, $(wc -l <<<"$out") lines: $(tr -d '\r' <<<"$out" | tail -3)"; return 1; }
}
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
# Windows' root certificates. ghcr.io answers 401 to anonymous requests. The
# untrusted root is a certificate made for the run, which Git Bash's openssl
# serves on the loopback (an AppContainer run with the network reaches it
# while its container is exempt), or SOUP_UNTRUSTED's URL; a host there that
# drops the connection before TLS says anything gets the run tried once more.
soup_server=
if [ -n "${SOUP_UNTRUSTED:-}" ]; then
    untrusted=$SOUP_UNTRUSTED
else
    soup_port=$((46000 + RANDOM % 900))
    untrusted="https://127.0.0.1:$soup_port/"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work\\untrusted.key" -out "$work\\untrusted.crt" -days 1 \
        -subj "/CN=zigsaw tests gtk.sh $RANDOM$RANDOM" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1 || echo "making the untrusted certificate failed"
    openssl s_server -accept 127.0.0.1:$soup_port -cert "$work\\untrusted.crt" -key "$work\\untrusted.key" -www -quiet </dev/null >"$work\\untrusted.out" 2>&1 &
    soup_server=$!
fi
soup() {
    local out try
    for try in 1 2; do
        out=$(timeout 120 "$zigsaw" run "$@" --command=bin/soup-get.exe $APP https://ghcr.io/v2/ "$untrusted" 2>&1 | tr -d '\r')
        grep -qE "^GET $untrusted: error: (Error receiving data|Error sending data|Could not connect|Connection terminated unexpectedly|Socket I/O timed out|Error resolving)" <<<"$out" || break
        [ $try = 1 ] && echo "a network error on $untrusted; once more" >&2
    done
    grep -q '^libsoup 3\.8\.0$' <<<"$out" && grep -q '^tls backend GTlsBackendOpenssl$' <<<"$out" &&
        grep -qF 'GET https://ghcr.io/v2/: 401 over HTTP/2' <<<"$out" &&
        grep -qF "GET $untrusted: error: Unacceptable TLS certificate" <<<"$out" || { echo "got: $out"; return 1; }
}
check "libsoup 3.8.0 gets an HTTPS URL over HTTP/2, trusting Windows' root certificates, and refuses an untrusted root" soup
check "with --sandbox=soft" soup --sandbox=soft
check "with --sandbox=appcontainer" soup --sandbox=appcontainer
[ -z "$soup_server" ] || { kill "$soup_server" 2>/dev/null; wait "$soup_server" 2>/dev/null; }
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

# Text: HarfBuzz with DirectWrite, so Pango takes a font file without
# warning, and draws with it through pangocairo; Pango's tools from the
# runtime's exports.
font_file() {
    local out
    out=$(timeout 60 "$zigsaw" run "$@" --command=bin/font-file.exe $APP 'C:\Windows\Fonts\consola.ttf' Consolas 2>&1 | tr -d '\r')
    grep -q '^drew [1-9][0-9]*x[1-9][0-9]* with Consolas$' <<<"$out" && ! grep -q 'HarfBuzz does not have' <<<"$out" || { echo "got: $out"; return 1; }
}
check "Pango adds a font file without warning, and pangocairo draws with it" font_file --env=G_DEBUG=fatal-warnings
check "with --sandbox=soft" font_file --env=G_DEBUG=fatal-warnings --sandbox=soft
# (DirectWrite warns there about fonts installed for the user only.)
check "with --sandbox=appcontainer, without Pango's warning" font_file --sandbox=appcontainer
printf 'Hello, zigsaw \xd8\xa7\xd9\x84\xd8\xb9\xd8\xb1\xd8\xa8\xd9\x8a\xd8\xa9\n' >"$work\\text.txt"
pango_view() {
    rm -f "$work\\text.png"
    timeout 60 "$zigsaw" run "$@" --command=pango-view org.gtk.Gtk4 -q --font='Segoe UI 20' -o text.png text.txt &&
        head -c 8 "$work\\text.png" | od -A n -t x1 | tr -d ' \n' | grep -qx '89504e470d0a1a0a'
}
check "the runtime's pango-view draws text to a PNG" pango_view
check "with --sandbox=soft" pango_view --sandbox=soft
check "with --sandbox=appcontainer" pango_view --sandbox=appcontainer
check "pango-list lists Windows' fonts" sh -c "timeout 60 \"\$0\" run --command=pango-list org.gtk.Gtk4 | tr -d '\r' | grep -q '^Segoe UI *$'" "$zigsaw"
check "the runtime's gio runs" sh -c "timeout 60 \"\$0\" run --command=gio org.gtk.Gtk4 version | grep -q '^2\\.90\\.'" "$zigsaw"
# Translations, through GNU gettext's libintl: in the language LANGUAGE
# names, or Windows' own without it.
check "the runtime speaks German with LANGUAGE=de (gio's help)" sh -c "timeout 60 \"\$0\" run --env=LANGUAGE=de --command=gio org.gtk.Gtk4 help 2>&1 | tr -d '\r' | grep -q '^Aufruf:'" "$zigsaw"
# An emoji followed by U+FE0F asks Pango for a color font, which Pango's
# Windows font map couldn't match to any font before GTK's SDK patched it
# (GTK's emoji chooser showed nothing).
printf '\xe2\x9d\xa4\xef\xb8\x8f \xf0\x9f\x98\x80\n' >"$work\\emoji.txt"
color_emoji() {
    local out
    out=$(timeout 60 "$zigsaw" run --command=pango-view org.gtk.Gtk4 -q --font='Segoe UI 20' -o emoji.png emoji.txt 2>&1 | tr -d '\r')
    ! grep -q -e 'fallbacks failed' -e "couldn't load font" <<<"$out" && test -s "$work\\emoji.png" || { echo "got: $out"; return 1; }
}
check "Pango finds a color font for emoji" color_emoji

# Spelling: enchant in the runtime, with Windows' own spell checker
# (WinSpell) first and hunspell with the runtime's en_US dictionary after.
spell() {
    local out
    out=$(timeout 60 "$zigsaw" run "$@" --command=bin/spell.exe $APP en_US 2>&1 | tr -d '\r')
    grep -q '^provider hunspell$' <<<"$out" && grep -q '^provider winspell$' <<<"$out" &&
        grep -q '^hunspell en_US: the ok, teh misspelled, suggests the$' <<<"$out" || { echo "got: $out"; return 1; }
    # Windows has en-US on this machine and on CI's.
    grep -q '^winspell en_US: the ok, teh misspelled, suggests the$' <<<"$out" && grep -q '^default en_US: winspell$' <<<"$out" || { echo "got: $out"; return 1; }
}
check "enchant checks spelling with WinSpell and with hunspell's en_US" spell
check "with --sandbox=soft" spell --sandbox=soft
check "with --sandbox=appcontainer" spell --sandbox=appcontainer
hunspell_only() {
    local out
    out=$(timeout 60 "$zigsaw" run --command=bin/spell.exe $APP xx_YY 2>&1 | tr -d '\r')
    grep -q '^hunspell xx_YY: no dictionary$' <<<"$out" && grep -q '^winspell xx_YY: no dictionary$' <<<"$out" || { echo "got: $(tr '\n' '|' <<<"$out")"; return 1; }
}
check "a language neither has has no dictionary (en_ZZ would fall back to English)" hunspell_only

# The runtime's extension point (org.gtk.Gtk4): an image that extends it adds
# its share directory to XDG_DATA_DIRS in every run of an app on the
# runtime, once installed, after the runtime's own. The dictionaries
# (recipes/gtk4-hunspell-*.json) are such images, built here unless the
# store has them (seconds), and removed afterwards; and so is an icon.
installed_dicts=false
if [ ! -f "$ZIGSAW_HOME\\refs\\org.gtk.Gtk4.Hunspell.fr_FR.json" ] || [ ! -f "$ZIGSAW_HOME\\refs\\org.gtk.Gtk4.Hunspell.vi_VN.json" ]; then
    installed_dicts=true
fi
for lang in fr vi; do
    z build "$root\\recipes\\gtk4-hunspell-$lang.json" >"$work\\dict-$lang.log" 2>&1 || echo "building the $lang dictionary failed: $(tail -1 "$work\\dict-$lang.log")"
done
dictionaries() {
    local out
    out=$(timeout 60 "$zigsaw" run "$@" --command=bin/spell.exe $APP fr_FR 2>&1 | tr -d '\r')
    # Grammalecte's is fr, for every fr_*: "the" isn't French.
    grep -q '^default fr: hunspell$' <<<"$out" && grep -q '^hunspell fr_FR: the misspelled, teh misspelled' <<<"$out" || { echo "got: $(tr '\n' '|' <<<"$out")"; return 1; }
    out=$(timeout 60 "$zigsaw" run "$@" --command=bin/spell.exe $APP vi_VN 2>&1 | tr -d '\r')
    grep -q '^default vi_VN: hunspell$' <<<"$out" && grep -q '^hunspell vi_VN: the ok, teh misspelled' <<<"$out" || { echo "got: $(tr '\n' '|' <<<"$out")"; return 1; }
    # The runtime's own en_US stays.
    timeout 60 "$zigsaw" run "$@" --command=bin/spell.exe $APP en_US 2>&1 | tr -d '\r' | grep -q '^hunspell en_US: the ok, teh misspelled, suggests the$'
}
check "installed, the French and Vietnamese dictionaries join the runtime's runs, with its English" dictionaries
check "with --sandbox=soft" dictionaries --sandbox=soft
check "with --sandbox=appcontainer" dictionaries --sandbox=appcontainer
no_french() {
    local out
    out=$(timeout 60 "$zigsaw" run --noextension=org.gtk.Gtk4.Hunspell.fr_FR --command=bin/spell.exe $APP fr_FR 2>&1 | tr -d '\r')
    grep -q '^hunspell fr_FR: no dictionary$' <<<"$out" || { echo "got: $(tr '\n' '|' <<<"$out")"; return 1; }
}
check "--noextension leaves one out" no_french
# The SVG from GdkPixbuf's check above, as an app's icon.
mkdir -p "$work\\icons" && cp "$work\\t.svg" "$work\\icons\\t.svg"
sed -e "s/@BUSYBOX@/$(manifest_of net.frippery.busybox)/" "$root\\tests\\gtk\\icons.json.in" >"$work\\icons\\icons.json"
z build "$work\\icons\\icons.json" >"$work\\icons.log" 2>&1 || echo "building test.gtk.icons failed: $(tail -1 "$work\\icons.log")"
# Once, under AppContainer on Server 2025, it printed nothing; a failure
# shows the run's exit status too.
icon() {
    local out code
    out=$(timeout 60 "$zigsaw" run "$@" --command=bin/icon.exe $APP test-gtk-icon document-open-symbolic 2>&1 | tr -d '\r'; exit "${PIPESTATUS[0]}")
    code=$?
    [ "$code" = 0 ] && grep -q '^icon test-gtk-icon found$' <<<"$out" && grep -q '^icon document-open-symbolic found$' <<<"$out" || { echo "got (exit $code): $(tr '\n' '|' <<<"$out")"; return 1; }
}
check "an icon an extension has is in GTK's icon theme, beside the runtime's" icon
check "with --sandbox=soft" icon --sandbox=soft
check "with --sandbox=appcontainer" icon --sandbox=appcontainer
z rm --delete-data test.gtk.icons >/dev/null 2>&1
check "removed, it isn't" sh -c "timeout 60 \"\$0\" run --command=bin/icon.exe $APP test-gtk-icon 2>&1 | tr -d '\r' | grep -q '^icon test-gtk-icon missing$'" "$zigsaw"

# Building without a recipe: the SDK's exports, from the store's bin, as
# cc, pkg-config and meson; the program then runs on the runtime.
mkdir -p "$work\\loose" && for f in hello.c soup.c svg.c spell.c font.c icon.c meson.build; do cp "$work\\$f" "$work\\loose\\"; done
bin="$ZIGSAW_HOME\\bin"
loose_cc() {
    (cd "$work\\loose" && "$bin\\cc.exe" hello.c -o hello.exe $("$bin\\pkg-config.exe" --cflags --libs gtk4 libadwaita-1 | tr -d '\r')) || return 1
    local out
    out=$(cd "$work\\loose" && timeout 120 "$zigsaw" run --command="$work\\loose\\hello.exe" org.gtk.Gtk4 2>&1 | tr -d '\r')
    grep -q '^GTK 4\.24\.1$' <<<"$out" && grep -q '^drew a frame with Gsk' <<<"$out" || { echo "got: $out"; return 1; }
}
check "the SDK's cc and pkg-config build a GTK program, which runs on the runtime" loose_cc
# A text view removed while it has the focus, as a page of Text Editor is
# when a file opens in its place: GTK 4.24.1's input method for Windows went
# on reading its memory, and the app crashed (patched in the SDK's recipe).
cp "$root\\tests\\gtk\\ime.c" "$work\\loose\\"
ime_survives() {
    (cd "$work\\loose" && "$bin\\cc.exe" ime.c -o ime.exe $("$bin\\pkg-config.exe" --cflags --libs gtk4 | tr -d '\r')) || return 1
    local out
    out=$(cd "$work\\loose" && timeout 60 "$zigsaw" run --command="$work\\loose\\ime.exe" org.gtk.Gtk4 2>&1 | tr -d '\r')
    grep -q '^the view has the focus: yes$' <<<"$out" && grep -q '^still here$' <<<"$out" || { echo "got: $(tr '\n' '|' <<<"$out")"; return 1; }
}
check "GTK's input method lets go of a text view removed while it has the focus" ime_survives
# (Through `run` rather than the meson shim, which Meson's own app has when
# it was installed first.)
sdk_meson() { "$zigsaw" run --command=meson org.gtk.Gtk4.Sdk "$@"; }
loose_meson() {
    (cd "$work\\loose" && sdk_meson setup out >/dev/null && sdk_meson compile -C out >/dev/null) || {
        (cd "$work\\loose" && sdk_meson compile -C out 2>&1 | tail -3); return 1; }
    local out
    out=$(cd "$work\\loose" && timeout 120 "$zigsaw" run --command="$work\\loose\\out\\spell.exe" org.gtk.Gtk4 en_US 2>&1 | tr -d '\r')
    grep -q '^hunspell en_US: the ok, teh misspelled, suggests the$' <<<"$out" || { echo "got: $out"; return 1; }
}
check "the SDK's meson sets up and compiles a project, with the aliases of the SDK's runtimes" loose_meson
# gettext's tools and windres, for translations and Windows resources (as
# Rust's winresource crate runs it).
loose_msgfmt() {
    printf '%s\n' 'msgid ""' 'msgstr "Content-Type: text/plain; charset=UTF-8\n"' '' 'msgid "Hello"' 'msgstr "Hallo"' >"$work\\loose\\de.po"
    (cd "$work\\loose" && "$bin\\msgfmt.exe" -o de.mo de.po) || return 1
    head -c 4 "$work\\loose\\de.mo" | od -A n -t x1 | tr -d ' \n' | grep -qx 'de120495'
}
check "the SDK's msgfmt compiles a translation" loose_msgfmt
loose_windres() {
    printf '%s\n' '1 VERSIONINFO' 'FILEVERSION 1,2,3,4' 'BEGIN' 'BLOCK "StringFileInfo"' 'BEGIN' 'BLOCK "040904b0"' 'BEGIN' 'VALUE "FileDescription", "zigsaw windres"' 'END' 'END' 'BLOCK "VarFileInfo"' 'BEGIN' 'VALUE "Translation", 0x409, 1200' 'END' 'END' >"$work\\loose\\version.rc"
    printf 'int main(void) { return 0; }\n' >"$work\\loose\\nothing.c"
    (cd "$work\\loose" && "$bin\\windres.exe" "-I$work\\loose" --target pe-x86-64 version.rc version.o && "$bin\\cc.exe" -s nothing.c version.o -o versioned.exe) || return 1
    # Its version strings are UTF-16 in the executable.
    powershell -NoProfile -Command "[Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes('$work\\loose\\versioned.exe')).Contains('zigsaw windres')" | tr -d '\r' | grep -qx 'True'
}
check "the SDK's windres compiles a resource script that cc links" loose_windres
check "a relative --command says how to name a program of yours" sh -c "\"\$0\" run --command=loose\\\\hello.exe org.gtk.Gtk4 2>&1 | grep -qF 'give its absolute path'" "$zigsaw"

# GUI programs get the shim that opens no console, and declared shortcuts.
# Installing the runtime again puts its shortcuts in the test's folder.
install_again org.gtk.Gtk4 gtk4.json >/dev/null 2>&1
shim_dir=$(dirname "$zigsaw")
shim_is() { cmp -s "$ZIGSAW_HOME\\bin\\$1.exe" "$shim_dir\\$2"; }
gui_shims() { shim_is gtk4-demo zigsaw-shimw.exe && shim_is adwaita-1-demo zigsaw-shimw.exe && shim_is gtk4-query-settings zigsaw-shim.exe; }
check "the demos get the windowless shim, gtk4-query-settings the console one" gui_shims
check "the runtime's demos get shortcuts" test -f "$links\\GTK Demo.lnk" -a -f "$links\\Adwaita Demo.lnk"
# Their icons are SVGs, which a shortcut can't show: the runtime's recipe
# makes an .ico of each (recipes/gtk4-sdk/svg2ico.sh).
lnk_icon() { powershell -NoProfile -Command "(New-Object -ComObject WScript.Shell).CreateShortcut('$1').IconLocation" | tr -d '\r'; }
# is_ico <file>: an icon with six images, the first a 16-pixel PNG.
is_ico() {
    [ "$(od -A n -t u1 -N 8 "$1" | tr -s ' ' | sed 's/^ //')" = "0 0 1 0 6 0 16 16" ] && tail -c +103 "$1" | head -c 4 | grep -q PNG
}
# has_icon <shortcut name> <icon's name>: the shortcut shows that .ico of
# share\icons, in whichever image has it.
has_icon() {
    local ico
    ico=$(lnk_icon "$links\\$1.lnk")
    case $ico in *"\\share\\icons\\$2.ico,0") ;; *) echo "$1: $ico"; return 1 ;; esac
    is_ico "${ico%,0}" || { echo "${ico%,0} isn't an icon"; return 1; }
}
demo_icons() { has_icon "GTK Demo" org.gtk.Demo4 && has_icon "GTK Widget Factory" org.gtk.WidgetFactory4 && has_icon "Adwaita Demo" org.gnome.Adwaita1.Demo; }
check "with icons made from the demos' SVGs" demo_icons
# reg_value <key under the classes>: the key's default value.
reg_value() {
    powershell -NoProfile -Command "(Get-ItemProperty -LiteralPath 'HKCU:\\$classes\\$1' -ErrorAction Stop).'(default)'" | tr -d '\r'
}
# opens_with <app id> <export> <extension> <icon's file name>: the extension
# is registered for the app, to open with the export's shim in open\.
opens_with() {
    local prog="Zigsaw.$1.${3#.}"
    [ "$(reg_value "$prog\\shell\\open\\command")" = "\"$ZIGSAW_HOME\\open\\$1\\$2.exe\" \"%1\"" ] || { echo "$3: $(reg_value "$prog\\shell\\open\\command")"; return 1; }
    case $(reg_value "$prog\\DefaultIcon") in *"\\$4,0") ;; *) echo "$3: icon $(reg_value "$prog\\DefaultIcon")"; return 1 ;; esac
    reg query "HKCU\\$classes\\$3\\OpenWithProgids" /v "$prog" >/dev/null 2>&1
}
# A directory of documents that no run has been granted, unlike the work
# directory, which runs with the cwd permission are.
docs=$(cygpath -w "$(mktemp -d)")
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
    install_again $EDITOR gnome-text-editor.json >/dev/null 2>&1
fi
editor_version() { timeout 60 "$zigsaw" run $EDITOR --version | tr -d '\r' | grep -q '^Text Editor 51\.0 '; }
check "Text Editor 51.0 is installed" editor_version
check "it gets the windowless shim and a shortcut" sh -c "cmp -s '$ZIGSAW_HOME\\bin\\gnome-text-editor.exe' '$shim_dir\\zigsaw-shimw.exe' && test -f '$links\\Text Editor.lnk'"
check "it runs" stays_up 15 $EDITOR --standalone
check "with --sandbox=soft" stays_up 15 --sandbox=soft $EDITOR --standalone
check "with --sandbox=appcontainer" stays_up 15 --sandbox=appcontainer $EDITOR --standalone
check "its shortcut has an icon made from its SVG" has_icon "Text Editor" org.gnome.TextEditor
editor_opens() { for ext in .txt .md .log; do opens_with $EDITOR gnome-text-editor $ext org.gnome.TextEditor.ico || return 1; done; }
check "it's registered to open .txt, .md and .log files" editor_opens
# As the shim of those does: the file granted, and nothing around it.
echo "a note" >"$docs\\note.txt"
check "it opens a file it's given with --file" stays_up 15 --command=gnome-text-editor --file="$docs\\note.txt" $EDITOR --standalone
check "with --sandbox=soft" stays_up 15 --sandbox=soft --command=gnome-text-editor --file="$docs\\note.txt" $EDITOR --standalone
check "with --sandbox=appcontainer" stays_up 15 --sandbox=appcontainer --command=gnome-text-editor --file="$docs\\note.txt" $EDITOR --standalone

# Gaphor (recipes/gaphor.json), a Python app on the runtime and PyGObject's,
# with libadwaita and GtkSourceView 5, its packages from PyPI through a
# pinned vendor step, and Graphviz's dot for its auto layout. Built here
# unless the store has it (a few minutes).
GAPHOR=org.gaphor.Gaphor
installed_gaphor=false
if [ ! -f "$ZIGSAW_HOME\\refs\\$GAPHOR.json" ]; then
    z build "$root\\recipes\\gaphor.json" >"$work\\gaphor.log" 2>&1 || echo "building $GAPHOR failed: $(tail -1 "$work\\gaphor.log")"
    installed_gaphor=true
else
    install_again $GAPHOR gaphor.json >/dev/null 2>&1
fi
# Gaphor's pythonw shows nothing: its console python.exe, from PyGObject's
# runtime, runs it for these.
pygobject_dir="$ZIGSAW_HOME\\deploy\\$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of org.gnome.PyGObject | cut -d: -f2)" | tail -1 | cut -d: -f2)"
gaphor_version() {
    local out
    out=$(timeout 60 "$zigsaw" run --command="$pygobject_dir\\python.exe" $GAPHOR -m gaphor --version 2>&1 | tr -d '\r')
    # And it finds its settings' schema, which it looks for in the first place only.
    grep -qx 'Gaphor 3\.3\.2' <<<"$out" && ! grep -q 'schema not found' <<<"$out" || { echo "got: $(tr '\n' '|' <<<"$out")"; return 1; }
}
check "Gaphor 3.3.2 is installed, and finds its settings" gaphor_version
# Its self-test, which its own Windows build runs: GTK, libadwaita and
# GtkSourceView's versions, both schemas, a window with a new model, and an
# auto layout through dot. On Windows it writes its log to the cwd.
gaphor_self_test() {
    rm -f "$work\\gaphor-self-test.txt"
    timeout 90 "$zigsaw" run "$@" --command="$pygobject_dir\\python.exe" $GAPHOR -m gaphor self-test >/dev/null 2>&1 || { echo "exit $?: $(tr -d '\r' <"$work\\gaphor-self-test.txt" 2>/dev/null | grep -e failed -e Error | tail -2 | tr '\n' '|')"; return 1; }
    [ "$(tr -d '\r' <"$work\\gaphor-self-test.txt" | grep -c 'selftest INFO test_[a-z_]*: passed$')" = 4 ] || { echo "got: $(tr -d '\r' <"$work\\gaphor-self-test.txt" | grep 'test_' | tr '\n' '|')"; return 1; }
}
check "its self-test passes, auto layout through Graphviz's dot included" gaphor_self_test
check "with --sandbox=soft" gaphor_self_test --sandbox=soft
# Python's tempfile makes its directories with mode 0o700, which an
# AppContainer couldn't write in until PyGObject's sitecustomize.py.
check "with --sandbox=appcontainer" gaphor_self_test --sandbox=appcontainer
check "it gets the windowless shim and a shortcut" sh -c "cmp -s '$ZIGSAW_HOME\\bin\\gaphor.exe' '$shim_dir\\zigsaw-shimw.exe' && test -f '$links\\Gaphor.lnk'"
check "its shortcut has an icon made from its SVG" has_icon "Gaphor" org.gaphor.Gaphor
check "it's registered to open .gaphor files" opens_with $GAPHOR gaphor .gaphor org.gaphor.Gaphor.ico
check "it runs" stays_up 20 $GAPHOR

# Rnote (recipes/rnote.json), a Rust GTK app, on the runtime. Built here
# unless the store has it, which takes about 20 minutes.
installed_rnote=false
if [ ! -f "$ZIGSAW_HOME\\refs\\$RNOTE.json" ]; then
    z build "$root\\recipes\\rnote.json" >"$work\\rnote.log" 2>&1 || echo "building $RNOTE failed: $(tail -1 "$work\\rnote.log")"
    installed_rnote=true
else
    install_again $RNOTE rnote.json >/dev/null 2>&1
fi
rnote_manifest="$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of $RNOTE | cut -d: -f2)"
rnote_dir="$ZIGSAW_HOME\\deploy\\$(grep -o 'sha256:[0-9a-f]*' "$rnote_manifest" | tail -1 | cut -d: -f2)"
rnote_imports() {
    timeout 60 "$zigsaw" run --command=rnote-cli $RNOTE --version | tr -d '\r' | grep -qx 'rnote-cli 0\.14\.2' || return 1
    (cd "$root" && zig build imports) >/dev/null || return 1
    "$root\\zig-out\\test\\zigsaw-imports.exe" "$rnote_dir\\bin\\rnote.exe" "$rnote_dir\\bin\\rnote-cli.exe"
}
check "Rnote 0.14.2 is installed, and its programs bind all their imports" rnote_imports
check "it gets the windowless shim and a shortcut" sh -c "cmp -s '$ZIGSAW_HOME\\bin\\rnote.exe' '$shim_dir\\zigsaw-shimw.exe' && test -f '$links\\Rnote.lnk'"
check "it has its translations" test -f "$rnote_dir\\share\\locale\\de\\LC_MESSAGES\\rnote.mo"
# rnote-cli imports a Xournal++ document and exports it as a PDF, with
# Virgil, one of Rnote's own fonts, which it adds to Pango itself (there's
# no fontconfig to find them), and Segoe UI, from Windows.
sh "$root\\tests\\gtk\\notes-xopp.sh" 2 >"$work\\notes.xopp"
rnote_cli() {
    rm -f "$work\\notes.rnote" "$work\\notes.pdf"
    timeout 60 "$zigsaw" run "$@" --command=rnote-cli $RNOTE create notes.rnote >/dev/null 2>&1 &&
        timeout 60 "$zigsaw" run "$@" --command=rnote-cli $RNOTE import notes.rnote -i notes.xopp >/dev/null 2>&1 &&
        timeout 60 "$zigsaw" run "$@" --command=rnote-cli $RNOTE export doc --output-file notes.pdf --on-conflict overwrite notes.rnote >/dev/null 2>&1 || return 1
    grep -a -q '/BaseFont /[A-Z]*+Virgil3YOFF' "$work\\notes.pdf" && grep -a -q '/BaseFont /[A-Z]*+SegoeUI' "$work\\notes.pdf"
}
check "rnote-cli turns a Xournal++ document into a PDF, with text in Rnote's own font" rnote_cli
check "with --sandbox=soft" rnote_cli --sandbox=soft
check "with --sandbox=appcontainer" rnote_cli --sandbox=appcontainer
# Each page drawn on one of rayon's threads, text through cairo's DirectWrite
# backend, whose thread safety cairo 1.18.6 fixed (Rnote's own Windows build
# pins a cairo without DirectWrite for it).
sh "$root\\tests\\gtk\\notes-xopp.sh" 40 >"$work\\many.xopp"
rnote_pages() {
    rm -rf "$work\\pages" "$work\\many.rnote" && mkdir "$work\\pages" || return 1
    timeout 60 "$zigsaw" run --command=rnote-cli $RNOTE create many.rnote >/dev/null 2>&1 &&
        timeout 60 "$zigsaw" run --command=rnote-cli $RNOTE import many.rnote -i many.xopp >/dev/null 2>&1 || return 1
    local i
    for i in 1 2 3; do
        timeout 120 "$zigsaw" run --command=rnote-cli $RNOTE export doc-pages -o pages -f png --on-conflict overwrite many.rnote >/dev/null 2>&1 || return 1
        [ "$(ls "$work\\pages" | wc -l)" -eq 40 ] || return 1
    done
}
check "it draws 40 pages of text on rayon's threads, three times over" rnote_pages
check "Rnote runs" stays_up 15 $RNOTE
check "with --sandbox=soft" stays_up 15 --sandbox=soft $RNOTE
check "with --sandbox=appcontainer" stays_up 15 --sandbox=appcontainer $RNOTE
rnote_opens() { opens_with $RNOTE rnote .rnote rnote.exe && opens_with $RNOTE rnote .xopp rnote.exe; }
check "it's registered to open .rnote and .xopp files, which show its icon" rnote_opens
cp "$work\\notes.rnote" "$docs\\notes.rnote"
check "it opens a document it's given with --file" stays_up 20 --command=rnote --file="$docs\\notes.rnote" $RNOTE
check "with --sandbox=soft" stays_up 20 --sandbox=soft --command=rnote --file="$docs\\notes.rnote" $RNOTE
check "with --sandbox=appcontainer" stays_up 20 --sandbox=appcontainer --command=rnote --file="$docs\\notes.rnote" $RNOTE

# Pinta (recipes/no-publish/pinta.json), a C# app, on the runtime and .NET's,
# built with .NET's SDK image. Microsoft's licence doesn't let the .NET images
# be published, so they're built here from Microsoft's download unless the
# store has them (300 MB, about a minute), and Pinta too (about a minute).
PINTA=com.github.PintaProject.Pinta
installed_dotnet=false installed_pinta=false
[ -f "$ZIGSAW_HOME\\refs\\com.microsoft.dotnet.Sdk.json" ] || installed_dotnet=true
[ -f "$ZIGSAW_HOME\\refs\\$PINTA.json" ] || installed_pinta=true
for r in dotnet-sdk dotnet pinta; do
    z build "$root\\recipes\\no-publish\\$r.json" >"$work\\$r.log" 2>&1 || echo "building $r.json failed: $(tail -1 "$work\\$r.log")"
done
pinta_dir="$ZIGSAW_HOME\\deploy\\$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of $PINTA | cut -d: -f2)" | tail -1 | cut -d: -f2)"
check "Pinta 3.1.2 is installed" sh -c "timeout 60 \"\$0\" run $PINTA --version | tr -d '\r' | grep -qx '3\\.1\\.2'" "$zigsaw"
check "it gets the windowless shim and a shortcut" sh -c "cmp -s '$ZIGSAW_HOME\\bin\\pinta.exe' '$shim_dir\\zigsaw-shimw.exe' && test -f '$links\\Pinta.lnk'"
# Its icon is in its executable, the apphost the .NET SDK makes for it, which
# takes the project's icon.
exe_icons() {
    powershell -NoProfile -Command "Add-Type -Namespace Z -Name I -MemberDefinition '[DllImport(\"shell32.dll\", CharSet = CharSet.Unicode)] public static extern uint ExtractIconEx(string f, int i, IntPtr[] l, IntPtr[] s, uint n);'; [Z.I]::ExtractIconEx('$1', -1, \$null, \$null, 0)" | tr -d '\r'
}
pinta_icon() {
    local ico
    ico=$(lnk_icon "$links\\Pinta.lnk")
    [ "$ico" = "$pinta_dir\\bin\\Pinta.exe,0" ] || { echo "Pinta: $ico"; return 1; }
    [ "$(exe_icons "$pinta_dir\\bin\\Pinta.exe")" -ge 1 ] || { echo "no icon in Pinta.exe"; return 1; }
}
check "its shortcut shows the icon in its executable" pinta_icon
# Pinta looks for its icons and translations in the share directory next to
# its bin, as its own Windows build lays them out.
check "it has its icons and translations in share" test -f "$pinta_dir\\share\\locale\\de\\LC_MESSAGES\\pinta.mo" -a -f "$pinta_dir\\share\\icons\\hicolor\\scalable\\actions\\tool-paintbrush-symbolic.svg"
check "Pinta runs" stays_up 15 $PINTA
check "with --sandbox=soft" stays_up 15 --sandbox=soft $PINTA
check "with --sandbox=appcontainer" stays_up 15 --sandbox=appcontainer $PINTA
pinta_opens() { for ext in .ora .png .jpg .jpeg .bmp .tif .tiff; do opens_with $PINTA pinta $ext Pinta.exe || return 1; done; }
check "it's registered to open .ora, .png, .jpg, .jpeg, .bmp, .tif and .tiff files" pinta_opens
# A 4x4 PNG.
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR42mM4EaABRwzEcQASUhQB/GAXigAAAABJRU5ErkJggg==' | base64 -d >"$docs\\picture.png"
check "it opens an image it's given with --file" stays_up 20 --command=pinta --file="$docs\\picture.png" $PINTA
check "with --sandbox=soft" stays_up 20 --sandbox=soft --command=pinta --file="$docs\\picture.png" $PINTA
check "with --sandbox=appcontainer" stays_up 20 --sandbox=appcontainer --command=pinta --file="$docs\\picture.png" $PINTA
check "the documents' directory was granted to none of the apps" sh -c "! icacls '$docs' | grep -q -e 'Mandatory Label' -e 'S-1-15-'"

# GTK built with the machine's MSVC (recipes/gtk4-msvc.json), if the store
# has it: it isn't published, and needs Visual Studio to build.
MSVC=org.gtk.Gtk4.Msvc
if [ -f "$ZIGSAW_HOME\\refs\\$MSVC.json" ]; then
    msvc_dir="$ZIGSAW_HOME\\deploy\\$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of $MSVC | cut -d: -f2)" | tail -1 | cut -d: -f2)"
    check "GTK built with MSVC: its gtk4-demo is GTK 4.24.1" sh -c "timeout 60 \"\$0\" run $MSVC --version | grep -q 'gtk4-demo.exe 4.24.1'" "$zigsaw"
    msvc_self_contained() {
        test -f "$msvc_dir\\bin\\vcruntime140.dll" || { echo "no vcruntime140.dll"; return 1; }
        (cd "$root" && zig build imports) >/dev/null || return 1
        "$root\\zig-out\\test\\zigsaw-imports.exe" "$msvc_dir\\bin\\gtk4-demo.exe" "$msvc_dir\\bin\\adwaita-1-demo.exe"
    }
    check "it has the Visual C++ runtime with it, and its demos bind all their imports" msvc_self_contained
    check "its demo runs" stays_up 15 $MSVC
    check "with --sandbox=soft" stays_up 15 --sandbox=soft $MSVC
    check "with --sandbox=appcontainer" stays_up 15 --sandbox=appcontainer $MSVC
    check "its Adwaita demo runs" stays_up 15 --command=adwaita-1-demo-msvc $MSVC
else
    echo "skip  GTK built with MSVC: $MSVC isn't in the store (recipes\\gtk4-msvc.json builds it, with Visual Studio)"
fi

cd "$root" || exit 1
# The scratch key, and the one above it unless another run has one in it.
reg delete "HKCU\\$classes" /f >/dev/null 2>&1
reg query 'HKCU\Software\ZigsawTest' 2>/dev/null | grep -q . || reg delete 'HKCU\Software\ZigsawTest' /f >/dev/null 2>&1
rm -rf "$docs"
$installed_pinta && z rm --delete-data $PINTA >/dev/null 2>&1
$installed_dotnet && { z rm --delete-data com.microsoft.dotnet >/dev/null 2>&1; z rm --delete-data com.microsoft.dotnet.Sdk >/dev/null 2>&1; }
$installed_rnote && z rm --delete-data $RNOTE >/dev/null 2>&1
$installed_editor && z rm --delete-data $EDITOR >/dev/null 2>&1
$installed_gaphor && z rm --delete-data $GAPHOR >/dev/null 2>&1
$installed_dicts && { z rm --delete-data org.gtk.Gtk4.Hunspell.fr_FR >/dev/null 2>&1; z rm --delete-data org.gtk.Gtk4.Hunspell.vi_VN >/dev/null 2>&1; }
z rm --delete-data $APP >/dev/null 2>&1
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
