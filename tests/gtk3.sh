#!/usr/bin/env bash
# GTK 3 end to end: GTK 3's images are an add-on to GTK 4's. An app built
# against GTK 3's SDK image (org.gtk.Gtk3.Sdk) and GTK 4's, with Meson and
# zig, runs on both runtimes (org.gtk.Gtk3 and org.gtk.Gtk4), opens a
# window and draws it in each sandbox, with GTK 3's settings schemas and the
# legacy icon theme from its runtime; GTK 3's demos (org.gtk.Gtk3demo) run,
# with the windowless shim and Start menu shortcuts (in a temporary folder).
# Gnumeric (recipes/gnumeric.json) converts a spreadsheet between CSV, Excel
# and OpenDocument with ssconvert in each sandbox, draws charts, writes
# into a folder of the user's it's granted, starts up with a file given with
# --file, and is registered for its kinds of file (in a scratch registry
# key). Meld (recipes/meld.json), Python on PyGObject's runtime, loads GTK
# 3, GtkSourceView and GTK 4 through their typelibs, and compares files and
# folders in each sandbox.
#
# Not in CI, like tests/gtk.sh: GTK's SDK takes a quarter of an hour to
# build, and Gnumeric 25 minutes.
#
#   GTK_HOME=path\to\store bash tests/gtk3.sh [path\to\zigsaw.exe]
#
# The store needs GTK 4's SDK and runtime (GTK_HOME, or BUILD_HOME as
# tests/published.sh leaves it); GTK 3's images, the demos, Gnumeric,
# PyGObject's images and Meld are built there unless it has them (5 minutes,
# and Gnumeric 25), and removed afterwards if they were. The apps open
# windows on the desktop for a moment.
set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
ZIGSAW_HOME=${GTK_HOME:-${BUILD_HOME:-}}
if [ -z "$ZIGSAW_HOME" ] || [ ! -f "$ZIGSAW_HOME\\refs\\org.gtk.Gtk4.json" ] || [ ! -f "$ZIGSAW_HOME\\refs\\org.gtk.Gtk4.Sdk.json" ]; then
    echo "tests/gtk3.sh needs a store with org.gtk.Gtk4 and org.gtk.Gtk4.Sdk in GTK_HOME or BUILD_HOME;"
    echo "build recipes\\gtk4-sdk.json and recipes\\gtk4.json into one first."
    exit 1
fi
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
APP=test.gtk.hello3
DEMO=org.gtk.Gtk3demo
GNUMERIC=org.gnome.Gnumeric
# Start menu shortcuts go here rather than the user's Start menu.
links="$work\\links"
export ZIGSAW_SHORTCUTS_DIR="$links"
# File associations go under this key of HKCU rather than Software\Classes.
classes="Software\\ZigsawTest\\gtk3-$$"
export ZIGSAW_CLASSES_KEY="$classes"
# The user's folders the apps may use, such as Documents, are these, not
# yours, which low and AppContainer runs would label and grant.
for f in Desktop Documents Downloads; do mkdir -p "$work\\folders\\$f"; done
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
# build_unless_installed <id> <recipe>: builds the recipe, which takes its
# image from the build cache if the store built it before; says whether it
# was installed before (for removing what this installed at the end).
installed_here=""
build_image() {
    [ -f "$ZIGSAW_HOME\\refs\\$1.json" ] || installed_here="$installed_here $1"
    z build "$root\\recipes\\$2" >"$work\\$2.log" 2>&1 || echo "building $2 failed: $(tail -1 "$work\\$2.log")"
}
build_image org.gtk.Gtk3.Sdk gtk3-sdk.json
build_image org.gtk.Gtk3 gtk3.json
build_image $DEMO gtk3demo.json

cp "$root\\tests\\gtk\\gtk3\\hello3.c" "$root\\tests\\gtk\\gtk3\\meson.build" "$work\\"
sed -e "s/@GTK@/$(manifest_of org.gtk.Gtk4)/" -e "s/@GTKSDK@/$(manifest_of org.gtk.Gtk4.Sdk)/" \
    -e "s/@GTK3@/$(manifest_of org.gtk.Gtk3)/" -e "s/@GTK3SDK@/$(manifest_of org.gtk.Gtk3.Sdk)/" \
    "$root\\tests\\gtk\\gtk3\\hello3.json.in" >"$work\\hello3.json"
check "an app builds against GTK 3's SDK image and GTK 4's, finding gtk+-3.0 with pkg-config" z build "$work\\hello3.json"
# Runs from the work directory: the app has the cwd permission.
cd "$work" || exit 1
drew() {
    local out
    out=$(timeout 60 "$zigsaw" run "$@" $APP 2>&1 | tr -d '\r')
    grep -q '^GTK 3\.24\.52$' <<<"$out" && grep -q '^ATK 2\.60\.7$' <<<"$out" &&
        grep -q '^FileChooser schema found$' <<<"$out" && grep -q '^icon document-open found$' <<<"$out" &&
        grep -q '^loaded it at 48x48$' <<<"$out" && grep -q '^drew a frame$' <<<"$out" || { echo "got: $(tr '\n' '|' <<<"$out")"; return 1; }
}
check "it runs on both runtimes, with GTK 3's schemas and legacy icons, and draws its window" drew
check "with --sandbox=low" drew --sandbox=low
check "with --sandbox=appcontainer" drew --sandbox=appcontainer
# GTK 4's runtime's variables, which GTK 3's apps have too.
check "GLib keeps settings in a key file in the app's data" sh -c "timeout 60 \"\$0\" run $APP 2>&1 | grep -q '^settings in GKeyfileSettingsBackend'" "$zigsaw"
runtime_dir="$ZIGSAW_HOME\\deploy\\$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of org.gtk.Gtk3 | cut -d: -f2)" | tail -1 | cut -d: -f2)"
runtime_files() {
    test -f "$runtime_dir\\bin\\libgtk-3-0.dll" -a -f "$runtime_dir\\bin\\libatk-1.0-0.dll" || return 1
    ! test -e "$runtime_dir\\include" && ! test -e "$runtime_dir\\lib\\pkgconfig" && ! test -e "$runtime_dir\\bin\\libglib-2.0-0.dll" || return 1
    ! ls "$runtime_dir\\lib" | grep -q -e '\.a$' -e '\.lib$'
}
check "GTK 3's runtime has GTK 3 and ATK only: no headers, libraries for linking, or GLib" runtime_files
check "and their typelibs" test -f "$runtime_dir\\lib\\girepository-1.0\\Gtk-3.0.typelib" -a -f "$runtime_dir\\lib\\girepository-1.0\\Gdk-3.0.typelib" -a -f "$runtime_dir\\lib\\girepository-1.0\\Atk-1.0.typelib"
check "it has GTK 3's translations" test -f "$runtime_dir\\share\\locale\\de\\LC_MESSAGES\\gtk30.mo"

# stays_up <seconds> <zigsaw run arguments...>: the app is still running
# when the time is up, rather than having crashed or failed a check; a
# critical warning stops it.
stays_up() {
    local seconds=$1
    shift
    timeout "$seconds" "$zigsaw" run --env=G_DEBUG=fatal-criticals "$@" >/dev/null 2>&1
    [ $? -eq 124 ]
}
shim_dir=$(dirname "$zigsaw")
shim_is() { cmp -s "$ZIGSAW_HOME\\bin\\$1.exe" "$shim_dir\\$2"; }
check "the demos get the windowless shim" sh -c "cmp -s '$ZIGSAW_HOME\\bin\\gtk3-demo.exe' '$shim_dir\\zigsaw-shimw.exe' && cmp -s '$ZIGSAW_HOME\\bin\\gtk3-widget-factory.exe' '$shim_dir\\zigsaw-shimw.exe'"
lnk_icon() { powershell -NoProfile -Command "(New-Object -ComObject WScript.Shell).CreateShortcut('$1').IconLocation" | tr -d '\r'; }
# is_ico <file> <images>: an icon with that many images, the first a
# 16-pixel PNG.
is_ico() {
    [ "$(od -A n -t u1 -N 8 "$1" | tr -s ' ' | sed 's/^ //')" = "0 0 1 0 $2 0 16 16" ] && tail -c +$((6 + 16 * $2 + 2)) "$1" | head -c 4 | grep -q PNG
}
demo_shortcuts() {
    local name ico
    for name in "GTK 3 Demo" "GTK 3 Widget Factory"; do
        ico=$(lnk_icon "$links\\$name.lnk")
        is_ico "${ico%,0}" 5 || { echo "$name: $ico"; return 1; }
    done
}
check "they get shortcuts, with icons made from their PNGs" demo_shortcuts
check "GTK 3's demo runs" stays_up 10 $DEMO
check "its widget factory runs, without critical warnings for want of a Desktop" stays_up 10 --command=gtk3-widget-factory $DEMO
check "with --sandbox=low" stays_up 10 --sandbox=low --command=gtk3-widget-factory $DEMO
check "with --sandbox=appcontainer" stays_up 10 --sandbox=appcontainer --command=gtk3-widget-factory $DEMO

# Gnumeric, on both runtimes. Built here unless the store has it, which
# takes about 25 minutes.
build_image $GNUMERIC gnumeric.json
gnumeric_dir="$ZIGSAW_HOME\\deploy\\$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of $GNUMERIC | cut -d: -f2)" | tail -1 | cut -d: -f2)"
check "Gnumeric 1.12.62 is installed" sh -c "timeout 60 \"\$0\" run --command=ssconvert $GNUMERIC --version | tr -d '\r' | grep -qx \"ssconvert version '1.12.62'\"" "$zigsaw"
check "it has its translations, goffice's and libgsf's" test -f "$gnumeric_dir\\share\\locale\\de\\LC_MESSAGES\\gnumeric-1.12.62.mo" -a -f "$gnumeric_dir\\share\\locale\\de\\LC_MESSAGES\\goffice-0.10.62.mo" -a -f "$gnumeric_dir\\share\\locale\\de\\LC_MESSAGES\\libgsf.mo"
# A CSV with a formula, to Excel, to OpenDocument and back, as ssconvert's
# plugins (Excel's, OpenDocument's, and the text importer) read and write
# them; the formula is computed.
printf 'item,count,double\nnails,21,=B2*2\n' >"$work\\sheet.csv"
round_trip() {
    rm -f "$work\\sheet.xlsx" "$work\\sheet.ods" "$work\\back.csv"
    local ss=(timeout 60 "$zigsaw" run --env=G_DEBUG=fatal-criticals "$@" --command=ssconvert $GNUMERIC)
    "${ss[@]}" sheet.csv sheet.xlsx >/dev/null 2>&1 && "${ss[@]}" sheet.xlsx sheet.ods >/dev/null 2>&1 &&
        "${ss[@]}" sheet.ods back.csv >/dev/null 2>&1 || return 1
    [ "$(tr -d '\r' <"$work\\back.csv" | tr '\n' '|')" = 'item,count,double|nails,21,42|' ] || { echo "got: $(cat "$work\\back.csv")"; return 1; }
}
check "ssconvert takes a spreadsheet from CSV to Excel to OpenDocument and back" round_trip
check "with --sandbox=low" round_trip --sandbox=low
check "with --sandbox=appcontainer" round_trip --sandbox=appcontainer
# A line chart and a pie chart, drawn by goffice's plot plugins, which
# ssconvert exports as PNGs.
cp "$root\\tests\\gtk\\gtk3\\charts.gnumeric" "$work\\"
charts() {
    rm -f "$work"\\chart.png.*
    timeout 60 "$zigsaw" run --env=G_DEBUG=fatal-criticals "$@" --command=ssconvert $GNUMERIC --export-graphs charts.gnumeric chart.png >/dev/null 2>&1 || return 1
    local n
    for n in 0 1; do
        head -c 8 "$work\\chart.png.$n" | od -A n -t x1 | tr -d ' \n' | grep -qx '89504e470d0a1a0a' || { echo "chart.png.$n isn't a PNG"; return 1; }
    done
}
check "it draws a spreadsheet's charts as PNGs" charts --sandbox=low
check "with --sandbox=appcontainer" charts --sandbox=appcontainer
# Gnumeric may use the user's Documents: here, the test's.
to_documents() {
    rm -f "$work\\folders\\Documents\\sheet.xlsx"
    timeout 60 "$zigsaw" run --sandbox=low --command=ssconvert $GNUMERIC sheet.csv "$work\\folders\\Documents\\sheet.xlsx" >/dev/null 2>&1 &&
        test -s "$work\\folders\\Documents\\sheet.xlsx"
}
check "at low integrity, it saves into the user's Documents, which it may use" to_documents
gnumeric_shortcut() {
    shim_is gnumeric zigsaw-shimw.exe || { echo "gnumeric.exe isn't the windowless shim"; return 1; }
    case $(lnk_icon "$links\\Gnumeric.lnk") in "$gnumeric_dir\\share\\icons\\gnumeric.ico,0") ;; *) echo "icon: $(lnk_icon "$links\\Gnumeric.lnk")"; return 1 ;; esac
    [ "$(od -A n -t u1 -N 4 "$gnumeric_dir\\share\\icons\\gnumeric.ico" | tr -s ' ' | sed 's/^ //')" = "0 0 1 0" ]
}
check "it gets the windowless shim and a shortcut, with Gnumeric's icon" gnumeric_shortcut
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
gnumeric_opens() { for ext in .gnumeric .xlsx .xls .ods .csv; do opens_with $GNUMERIC gnumeric $ext gnumeric.ico || return 1; done; }
check "it's registered to open .gnumeric, .xlsx, .xls, .ods and .csv files" gnumeric_opens
# A directory of documents that no run has been granted, unlike the work
# directory, which runs with the cwd permission are.
docs=$(cygpath -w "$(mktemp -d)")
cp "$work\\sheet.xlsx" "$docs\\sheet.xlsx"
check "Gnumeric opens a spreadsheet it's given with --file" stays_up 20 --command=gnumeric --file="$docs\\sheet.xlsx" $GNUMERIC
check "with --sandbox=low" stays_up 20 --sandbox=low --command=gnumeric --file="$docs\\sheet.xlsx" $GNUMERIC
check "with --sandbox=appcontainer" stays_up 20 --sandbox=appcontainer --command=gnumeric --file="$docs\\sheet.xlsx" $GNUMERIC
check "the documents' directory was granted to none of the apps" sh -c "! icacls '$docs' | grep -q -e 'Mandatory Label' -e 'S-1-15-'"

# Meld, a Python app: PyGObject's runtime runs it, with GTK 3 and GTK 4
# through their runtimes' typelibs. Built here unless the store has them
# (about 3 minutes).
MELD=org.gnome.Meld
build_image org.gnome.PyGObject.Sdk pygobject-sdk.json
build_image org.gnome.PyGObject pygobject.json
build_image $MELD meld.json
pygobject_dir="$ZIGSAW_HOME\\deploy\\$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of org.gnome.PyGObject | cut -d: -f2)" | tail -1 | cut -d: -f2)"
printf '%s\n' 'import gi' 'gi.require_version("Gtk", "3.0")' 'gi.require_version("GtkSource", "4")' \
    'from gi.repository import Gtk, GtkSource, Pango' \
    'print("GTK", Gtk.get_major_version(), Gtk.get_minor_version(), Gtk.get_micro_version())' \
    'print("GtkSourceView", GtkSource.LanguageManager.get_default().get_language("python3").get_name())' \
    'print("Pango", Pango.version_string())' >"$work\\gi3.py"
printf '%s\n' 'import gi, cairo' 'gi.require_version("Gtk", "4.0")' 'gi.require_version("Adw", "1")' \
    'from gi.repository import Gtk, Adw' \
    'print("GTK", Gtk.get_major_version(), Gtk.get_minor_version(), Gtk.get_micro_version())' \
    'print("libadwaita", Adw.get_major_version(), Adw.get_minor_version())' \
    'print("pycairo", cairo.version)' >"$work\\gi4.py"
# python_says <script> <expected, lines joined by |> <run options...>:
# what the script prints, without zigsaw's notes of what it granted and
# GLib's warnings (in an AppContainer, Pango's that DirectWrite can't open
# per-user fonts).
python_says() {
    local script=$1 want=$2 out
    shift 2
    out=$(timeout 60 "$zigsaw" run "$@" --command="$pygobject_dir\\python.exe" $MELD "$script" 2>&1 | tr -d '\r' |
        grep -v -e '^granted ' -e '^labelled ' -e '^\*\* (' -e '^$' | tr '\n' '|')
    [ "$out" = "$want|" ] || { echo "got: $out"; return 1; }
}
check "PyGObject loads GTK 3 and GtkSourceView 4 through their typelibs" python_says gi3.py 'GTK 3 24 52|GtkSourceView Python|Pango 1.58.2'
check "and GTK 4 and libadwaita, with pycairo" python_says gi4.py 'GTK 4 24 1|libadwaita 1 10|pycairo 1.29.2'
check "with --sandbox=low" python_says gi3.py 'GTK 3 24 52|GtkSourceView Python|Pango 1.58.2' --sandbox=low
check "with --sandbox=appcontainer" python_says gi3.py 'GTK 3 24 52|GtkSourceView Python|Pango 1.58.2' --sandbox=appcontainer
meld_dir="$ZIGSAW_HOME\\deploy\\$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of $MELD | cut -d: -f2)" | tail -1 | cut -d: -f2)"
# Meld's command is pythonw.exe, which shows nothing: python.exe runs it here.
check "Meld 3.24.1 is installed" sh -c "timeout 60 \"\$0\" run --command='$pygobject_dir\\python.exe' $MELD '$meld_dir\\bin\\meld' --version 2>&1 | tr -d '\r' | grep -qx 'meld 3.24.1'" "$zigsaw"
rm -f "$ZIGSAW_HOME\\data\\$MELD\\share\\meld.log"
printf 'one\ntwo\nthree\n' >"$work\\left.txt"
printf 'one\n2\nthree\nfour\n' >"$work\\right.txt"
mkdir -p "$work\\left" "$work\\right"
cp "$work\\left.txt" "$work\\left\\same.txt"; cp "$work\\left.txt" "$work\\right\\same.txt"
cp "$work\\left.txt" "$work\\left\\changed.txt"; cp "$work\\right.txt" "$work\\right\\changed.txt"
# meld_draws <what to compare...> -- <run options...>: Meld opens the
# comparison and saves a picture of its window, which its CI hook does
# after 3 s before quitting.
meld_draws() {
    local what=() opts=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do what+=("$1"); shift; done
    [ $# -gt 0 ] && shift
    opts=("$@")
    rm -f "$work\\meld.png"
    timeout 90 "$zigsaw" run --env=MELD_SCREENSHOT_AND_EXIT="$work\\meld.png" "${opts[@]}" $MELD "${what[@]}" >/dev/null 2>&1
    head -c 8 "$work\\meld.png" 2>/dev/null | od -A n -t x1 | tr -d ' \n' | grep -qx '89504e470d0a1a0a' || { echo "no picture"; return 1; }
    [ "$(wc -c <"$work\\meld.png")" -gt 20000 ] || { echo "a picture of $(wc -c <"$work\\meld.png") bytes"; return 1; }
}
check "Meld compares two files and draws its window" meld_draws left.txt right.txt
check "with --sandbox=low" meld_draws left.txt right.txt -- --sandbox=low
check "with --sandbox=appcontainer" meld_draws left.txt right.txt -- --sandbox=appcontainer
check "it compares two folders" meld_draws left right -- --sandbox=low
check "its log has no Python traceback" sh -c "! grep -q Traceback '$ZIGSAW_HOME\\data\\$MELD\\share\\meld.log'"
meld_shortcut() {
    shim_is meld zigsaw-shimw.exe || { echo "meld.exe isn't the windowless shim"; return 1; }
    case $(lnk_icon "$links\\Meld.lnk") in "$meld_dir\\share\\icons\\org.gnome.Meld.ico,0") ;; *) echo "icon: $(lnk_icon "$links\\Meld.lnk")"; return 1 ;; esac
}
check "it gets the windowless shim and a shortcut, with Meld's icon" meld_shortcut

cd "$root" || exit 1
# The scratch key, and the one above it unless another run has one in it.
reg delete "HKCU\\$classes" /f >/dev/null 2>&1
reg query 'HKCU\Software\ZigsawTest' 2>/dev/null | grep -q . || reg delete 'HKCU\Software\ZigsawTest' /f >/dev/null 2>&1
rm -rf "$docs"
for id in $installed_here; do z rm --delete-data "$id" >/dev/null 2>&1; done
z rm --delete-data $APP >/dev/null 2>&1
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
