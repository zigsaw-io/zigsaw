#!/usr/bin/env bash
# Java apps end to end, on OpenJDK's runtime image (org.openjdk.java):
# Apache PDFBox (recipes/pdfbox.json, built with Maven) makes a PDF from
# text, reads its text back and renders it, with its font cache in its data
# directory, and its debugger opens a PDF given with --file, keeping its
# settings with the app; PlantUML (recipes/plantuml.json, built with Gradle)
# draws a sequence and a class diagram with the dot inside its jar, and opens
# its window; Logisim-evolution (recipes/logisim-evolution.json, a bigger
# Gradle build) simulates a half adder from the command line and opens it,
# given with --file, in its window, keeping its recent files with the app.
# Each in every sandbox; their windowless shims, shortcuts (in a temporary
# folder) and PDFBox's .pdf and Logisim's .circ registrations (in a scratch
# registry key) too. Last, the registry: none of their keys stay in HKCU, and
# an HKCU\Software\JavaSoft\Prefs that was there stays.
#
#   JAVAAPPS_HOME=path\to\store bash tests/java.sh [path\to\zigsaw.exe]
#
# The store (JAVAAPPS_HOME, or BUILD_HOME as tests/published.sh leaves it,
# or a temporary one) gets the JDK, JRE, Maven and Gradle images and the
# three apps unless it has them (about 12 minutes in a new store, mostly
# Maven's and Gradle's downloads), and loses them afterwards if it didn't.
# The apps open windows on the desktop for a moment.
set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
temp_store=""
ZIGSAW_HOME=${JAVAAPPS_HOME:-${BUILD_HOME:-}}
if [ -z "$ZIGSAW_HOME" ]; then
    ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
    temp_store=$ZIGSAW_HOME
fi
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
PDFBOX=org.apache.pdfbox
PLANTUML=com.plantuml.PlantUML
LOGISIM=com.github.reds.LogisimEvolution
# Start menu shortcuts go here rather than the user's Start menu.
links="$work\\links"
export ZIGSAW_SHORTCUTS_DIR="$links"
# File associations go under this key of HKCU rather than Software\Classes.
classes="Software\\ZigsawTest\\java-$$"
export ZIGSAW_CLASSES_KEY="$classes"
# The user's folders the apps may use, such as Documents, are these, not
# yours, which low and AppContainer runs would label and grant.
for f in Desktop Documents Downloads; do mkdir -p "$work\\folders\\$f"; done
export ZIGSAW_USER_FOLDERS="$work\\folders"
(cd "$root" && zig build winwait) || { echo "building the window waiter failed"; exit 1; }
winwait="$root\\zig-out\\test\\zigsaw-winwait.exe"
had_prefs=false
reg query 'HKCU\Software\JavaSoft\Prefs' >/dev/null 2>&1 && had_prefs=true

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
# build_image <id> <recipe>: builds the recipe (from the build cache if the
# store built it before), noting whether this installed it.
installed_here=""
build_image() {
    [ -f "$ZIGSAW_HOME\\refs\\$1.json" ] || installed_here="$installed_here $1"
    z build "$root\\recipes\\$2" >"$work\\$2.log" 2>&1 || echo "building $2 failed: $(tail -1 "$work\\$2.log")"
}
build_image org.openjdk.java.Sdk java-sdk.json
build_image org.openjdk.java java.json
build_image org.apache.maven maven.json
build_image org.gradle.gradle gradle.json
build_image $PDFBOX pdfbox.json
build_image $PLANTUML plantuml.json
build_image $LOGISIM logisim-evolution.json
data() { echo "$ZIGSAW_HOME\\data\\$1"; }
# Runs from the work directory's sandbox folders, never the repository: the
# apps have the cwd permission, which low runs label and AppContainer runs
# grant. (A check's `cd` lasts only for that check.)
mkdir -p "$work\\soft" "$work\\low" "$work\\appcontainer"
cd "$work" || exit 1

# --- PDFBox ---------------------------------------------------------------------

# pdf_round_trip <sandbox>: a PDF made from text, and the text read back.
pdf_round_trip() {
    local out
    cd "$work\\$1" || return 1
    printf 'hello from zigsaw\nsecond line\n' >in.txt
    z run --sandbox=$1 $PDFBOX fromtext -i in.txt -o out.pdf >/dev/null 2>&1 || { echo "fromtext failed"; return 1; }
    out=$(z run --sandbox=$1 $PDFBOX export:text -console -i out.pdf 2>/dev/null | tr -d '\r' | grep -v '^The encoding parameter is ignored')
    [ "$out" = "hello from zigsaw
second line" ] || { echo "got: $out"; return 1; }
}
# renders <sandbox>: a PNG of the page; PDFBox's font cache, which it keeps in
# user.home, is in the app's data.
renders() {
    cd "$work\\$1" || return 1
    z run --sandbox=$1 $PDFBOX render -i out.pdf -format png -dpi 40 >/dev/null 2>&1 || { echo "render failed"; return 1; }
    [ "$(head -c 4 out-1.png | tail -c 3)" = "PNG" ] || { echo "no PNG"; return 1; }
    [ -f "$(data $PDFBOX)\\home\\.pdfbox.cache" ] || { echo "no font cache in its data's home"; return 1; }
}
for sb in soft low appcontainer; do
    check "PDFBox makes a PDF from text and reads the text back, under $sb" pdf_round_trip $sb
    check "  and renders it, its font cache in its data" renders $sb
done
# opens_window <directory> <title text|class:Name> <run options...>: run from
# the directory, the app's window comes up within 40 seconds and closes as its
# close button would.
opens_window() {
    local what=$2
    cd "$1" || return 1
    shift 2
    # Not through z: a backgrounded function is a subshell, whose pid isn't
    # zigsaw's.
    "$zigsaw" run "$@" >"$work\\run.log" 2>&1 &
    local runner=$! status i
    # Only windows of that run count (its Windows pid; $! is Git Bash's).
    "$winwait" "$(cat /proc/$runner/winpid)" "$what" 40 --close >/dev/null
    status=$?
    for i in $(seq 50); do
        kill -0 $runner 2>/dev/null || break
        sleep 0.2
    done
    if kill -0 $runner 2>/dev/null; then
        kill $runner
        wait $runner
        echo "no window ($what) closed (winwait $status); $(grep -v '^Picked' "$work\\run.log" | tail -1)"
        return 1
    fi
    wait $runner || { echo "zigsaw run failed: $(grep -v '^Picked' "$work\\run.log" | tail -1)"; return 1; }
    [ $status -eq 0 ] || { echo "winwait $status"; return 1; }
}
# A directory of documents that no run has been granted, unlike the work
# directory, which runs with the cwd permission are.
docs=$(cygpath -w "$(mktemp -d)")
cp "$work\\soft\\out.pdf" "$docs\\doc.pdf"
for sb in soft low appcontainer; do
    check "its debugger opens a PDF given with --file, under $sb" opens_window "$work\\$sb" "PDF Debugger - $docs\\doc.pdf" --sandbox=$sb --command=pdfbox-debugger --file="$docs\\doc.pdf" $PDFBOX
done
check "the documents' directory was granted to none of the runs" sh -c "! icacls '$docs' | grep -q -e 'Mandatory Label' -e 'S-1-15-'"
# Java keeps the debugger's settings in HKCU\Software\JavaSoft\Prefs; the app
# keeps its key with its data, so each run, in any sandbox, has the files the
# others opened.
recent_kept() {
    local out
    out=$(z run --command=reg $PDFBOX query 'HKCU\Software\JavaSoft\Prefs\org\apache\pdfbox\debugger\recent_files_' 2>&1 | tr -d '\r')
    [ "$(grep -c 'recent_files_[0-9]*_0 .*doc\.pdf' <<<"$out")" -ge 1 ] || { echo "got: $out"; return 1; }
    [ -f "$(data $PDFBOX)\\registry\\user.dat" ]
}
check "its settings, recent files among them, are kept in a hive in its data" recent_kept
shim_dir=$(dirname "$zigsaw")
shim_is() { cmp -s "$ZIGSAW_HOME\\bin\\$1.exe" "$shim_dir\\$2"; }
check "pdfbox gets the console shim, pdfbox-debugger the windowless one" sh -c "cmp -s '$ZIGSAW_HOME\\bin\\pdfbox.exe' '$shim_dir\\zigsaw-shim.exe' && cmp -s '$ZIGSAW_HOME\\bin\\pdfbox-debugger.exe' '$shim_dir\\zigsaw-shimw.exe'"
check "and a shortcut" test -f "$links\\PDFBox Debugger.lnk"
reg_value() {
    powershell -NoProfile -Command "(Get-ItemProperty -LiteralPath 'HKCU:\\$classes\\$1' -ErrorAction Stop).'(default)'" | tr -d '\r'
}
pdf_registered() {
    local prog="Zigsaw.$PDFBOX.pdf"
    [ "$(reg_value "$prog\\shell\\open\\command")" = "\"$ZIGSAW_HOME\\open\\$PDFBOX\\pdfbox-debugger.exe\" \"%1\"" ] || { echo "got: $(reg_value "$prog\\shell\\open\\command")"; return 1; }
    reg query "HKCU\\$classes\\.pdf\\OpenWithProgids" /v "$prog" >/dev/null 2>&1
}
check "it's registered to open .pdf files with its debugger" pdf_registered

# --- PlantUML ---------------------------------------------------------------------

# draws <sandbox>: a sequence diagram, and a class diagram, which PlantUML lays
# out with the dot it carries in its jar (unpacked into its data's TEMP).
draws() {
    cd "$work\\$1" || return 1
    printf '@startuml\nAlice -> Bob: hello\nBob --> Alice: from zigsaw\n@enduml\n' >seq.puml
    printf '@startuml\nclass Store\nclass App\nStore "1" *-- "many" App : deploys\n@enduml\n' >cls.puml
    rm -f seq.svg cls.svg
    z run --sandbox=$1 $PLANTUML -tsvg seq.puml cls.puml >"$work\\puml.log" 2>&1 || { echo "failed: $(grep -v '^Picked' "$work\\puml.log" | head -1)"; return 1; }
    texts() { grep -o '<text[^>]*>[^<]*</text>' "$1" | sed 's/<[^>]*>//g' | tr '\n' ' '; }
    [ "$(texts seq.svg)" = "Alice Bob Alice Bob hello from zigsaw " ] || { echo "seq.svg: $(texts seq.svg | cut -c1-80)"; return 1; }
    [ "$(texts cls.svg)" = "Store App deploys 1 many " ] || { echo "cls.svg: $(texts cls.svg | cut -c1-80)"; return 1; }
}
for sb in soft low appcontainer; do
    check "PlantUML draws a sequence and a class diagram as SVG, under $sb" draws $sb
done
version=$(grep -o '"version": *"[^"]*"' "$root\\recipes\\plantuml.json" | head -1 | cut -d'"' -f4)
check "its version names the release and its commit" sh -c "'$zigsaw' run $PLANTUML -version 2>/dev/null | tr -d '\r' | grep -q '^PlantUML version $version / [0-9a-f]\{7\} \[20'"
check "and the dot it found is its own" sh -c "'$zigsaw' run $PLANTUML -version 2>/dev/null | tr -d '\r' | grep -q '^Installation seems OK'"
for sb in soft low appcontainer; do
    check "its window comes up, under $sb" opens_window "$work\\$sb" class:SunAwtFrame --sandbox=$sb --command=plantuml-gui $PLANTUML
done
check "plantuml gets the console shim, plantuml-gui the windowless one, and a shortcut" sh -c "cmp -s '$ZIGSAW_HOME\\bin\\plantuml.exe' '$shim_dir\\zigsaw-shim.exe' && cmp -s '$ZIGSAW_HOME\\bin\\plantuml-gui.exe' '$shim_dir\\zigsaw-shimw.exe' && test -f '$links\\PlantUML.lnk'"

# --- Logisim-evolution ----------------------------------------------------------

# simulates <sandbox>: the truth table of tests/java/half-adder.circ (A XOR B
# and A AND B), from Logisim's command line, which runs headless.
simulates() {
    local out
    cd "$work\\$1" || return 1
    cp "$root\\tests\\java\\half-adder.circ" . || return 1
    out=$(z run --sandbox=$1 $LOGISIM --tty table half-adder.circ 2>/dev/null | tr -d '\r')
    [ "$out" = "A B S C
0 0 0 0
0 1 1 0
1 0 1 0
1 1 0 1" ] || { echo "got: $out"; return 1; }
}
for sb in soft low appcontainer; do
    check "Logisim-evolution simulates a half adder from its command line, under $sb" simulates $sb
done
check "its version names the release and the time of its tag's commit" sh -c "'$zigsaw' run $LOGISIM --version 2>/dev/null | tr -d '\r' | grep -q '^(Not built from Git repo) (2026-09-12T04:03:35+0000)'"
cp "$root\\tests\\java\\half-adder.circ" "$docs\\"
for sb in soft low appcontainer; do
    check "its window opens a circuit given with --file, under $sb" opens_window "$work\\$sb" "main of half-adder" --sandbox=$sb --command=logisim-gui --file="$docs\\half-adder.circ" $LOGISIM
done
logisim_recent_kept() {
    local out
    out=$(z run --command=reg $LOGISIM query 'HKCU\Software\JavaSoft\Prefs\com\cburch\logisim' 2>&1 | tr -d '\r')
    grep -q 'recent[0-9]* .*half-adder\.circ' <<<"$out" || { echo "got: $out"; return 1; }
    [ -f "$(data $LOGISIM)\\registry\\user.dat" ]
}
check "its recent files are kept in a hive in its data" logisim_recent_kept
check "logisim gets the console shim, logisim-gui the windowless one, and a shortcut" sh -c "cmp -s '$ZIGSAW_HOME\\bin\\logisim.exe' '$shim_dir\\zigsaw-shim.exe' && cmp -s '$ZIGSAW_HOME\\bin\\logisim-gui.exe' '$shim_dir\\zigsaw-shimw.exe' && test -f '$links\\Logisim-evolution.lnk'"
circ_registered() {
    local prog="Zigsaw.$LOGISIM.circ"
    [ "$(reg_value "$prog\\shell\\open\\command")" = "\"$ZIGSAW_HOME\\open\\$LOGISIM\\logisim-gui.exe\" \"%1\"" ] || { echo "got: $(reg_value "$prog\\shell\\open\\command")"; return 1; }
    reg query "HKCU\\$classes\\.circ\\OpenWithProgids" /v "$prog" >/dev/null 2>&1
}
check "it's registered to open .circ files" circ_registered

# --- The registry ------------------------------------------------------------------

check "HKCU has none of the apps' keys between their runs" sh -c "! reg query 'HKCU\\Software\\JavaSoft\\Prefs\\org\\apache\\pdfbox' >/dev/null 2>&1 && ! reg query 'HKCU\\Software\\JavaSoft\\Prefs\\net\\sourceforge\\plantuml' >/dev/null 2>&1 && ! reg query 'HKCU\\Software\\JavaSoft\\Prefs\\com\\cburch' >/dev/null 2>&1"
if $had_prefs; then
    check "and HKCU\\Software\\JavaSoft\\Prefs, which was there, still is" reg query 'HKCU\Software\JavaSoft\Prefs'
    # AppContainer runs could read it while they ran, to open their keys
    # below it.
    no_capability() {
        ! powershell -NoProfile -Command "(Get-Acl 'HKCU:\\Software\\JavaSoft\\Prefs').Access | ForEach-Object { \$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }" | grep -q '^S-1-15-3-'
    }
    check "  and no AppContainer may read it any more" no_capability
fi
check "no run labelled or granted the repository" sh -c "! icacls '$root' | grep -q -e 'Mandatory Label' -e 'S-1-15-'"

cd "$root" || exit 1
# The scratch key, and the one above it unless another run has one in it.
reg delete "HKCU\\$classes" /f >/dev/null 2>&1
reg query 'HKCU\Software\ZigsawTest' 2>/dev/null | grep -q . || reg delete 'HKCU\Software\ZigsawTest' /f >/dev/null 2>&1
rm -rf "$docs"
for id in $installed_here; do z rm --delete-data "$id" >/dev/null 2>&1; done
if [ -n "$temp_store" ]; then
    z prune --downloads --data >/dev/null 2>&1
    rm -rf "$temp_store"
fi
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
