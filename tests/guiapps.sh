#!/usr/bin/env bash
# Prebuilt Windows GUI apps through the three sandboxes: 7-Zip, Notepad++,
# SumatraPDF and VLC, as their recipes package them from upstream's
# archives. Each opens a file given with --file and shows it in its window's
# title, which is closed as its close button would, so the app saves its
# settings; those must be in its data directory, not the real AppData or
# registry. VLC also decodes a clip without a window. And each gets the GUI
# shim, a Start menu shortcut and its file associations (in a temporary
# folder and a scratch registry key), and the user's folders it may use
# linked into its home: fake ones (ZIGSAW_USER_FOLDERS), so that no run
# labels or grants yours. tests/hostprobe.zig, made an app, shows where a
# desktop program finds Documents.
#
#   tests/guiapps.sh [path\to\zigsaw.exe]
#
# Like tests/matrix.sh, each row states the intended result per sandbox:
# "ok", "fails", or "gap" for "ok is intended, but zigsaw doesn't manage it
# yet" (see the README's known gaps and docs/findings.md); a gap is reported
# and doesn't fail the suite, so only changes do.
#
# Needs Git Bash; opens windows on the desktop for a moment; not run in CI.
# Uses the store in GUIAPPS_HOME, or BUILD_HOME as tests/published.sh leaves
# it, and builds the apps that store lacks (seconds each, from the downloads
# there); without either, a temporary store, which downloads about 100 MB
# unless SEED_DOWNLOADS has the files. Apps it installed are removed again.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
own_store=false
ZIGSAW_HOME=${GUIAPPS_HOME:-${BUILD_HOME:-}}
if [ -z "$ZIGSAW_HOME" ]; then
    ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
    own_store=true
fi
export ZIGSAW_HOME
if [ -n "${SEED_DOWNLOADS:-}" ]; then
    mkdir -p "$ZIGSAW_HOME\\cache\\downloads"
    cp -l "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/" 2>/dev/null ||
        cp -n "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/"
fi
work=$(cygpath -w "$(mktemp -d)")
# Documents no run is granted, unlike the work directory, which runs with the
# cwd permission are.
docs=$(cygpath -w "$(mktemp -d)")
export ZIGSAW_SHORTCUTS_DIR="$work\\links"
classes="Software\\ZigsawTest\\guiapps-$$"
export ZIGSAW_CLASSES_KEY="$classes"
folders="$work\\folders"
for f in Desktop Documents Downloads Music Pictures Videos; do mkdir -p "$folders\\$f"; done
export ZIGSAW_USER_FOLDERS="$folders"

SEVENZIP=org.7_zip.7zip
NPP=org.notepad_plus_plus.NotepadPlusPlus
SUMATRA=org.sumatrapdfreader.SumatraPDF
VLC=org.videolan.VLC
HOSTPROBE=test.hostprobe

(cd "$root" && zig build winwait hostprobe) || { echo "building the window waiter and the probe failed"; exit 1; }
winwait="$root\\zig-out\\test\\zigsaw-winwait.exe"

installed=()
for recipe in recipes\\7zip recipes\\notepad-plus-plus recipes\\sumatrapdf recipes\\vlc tests\\hostprobe\\app; do
    id=$(grep -o '"id": *"[^"]*"' "$root\\$recipe.json" | cut -d'"' -f4)
    [ -f "$ZIGSAW_HOME\\refs\\$id.json" ] || installed+=("$id")
    "$zigsaw" build "$root\\$recipe.json" >"$work\\build.log" 2>&1 || { echo "building $recipe failed: $(tail -1 "$work\\build.log")"; exit 1; }
done

failures=0
gaps=0
pass() { printf 'ok    %s\n' "$1"; }
fail() {
    printf 'FAIL  %s\n' "$1"
    [ -n "${2:-}" ] && printf '      %s\n' "$2"
    failures=$((failures + 1))
}
check() {
    local label=$1
    shift
    local out
    if out=$("$@" 2>&1); then pass "$label"; else fail "$label" "$(grep -v '^\s*$' <<<"$out" | tail -1 | cut -c1-110)"; fi
}
# row <label> <soft> <appcontainer> <low> <check> [args]: runs the check with
# each sandbox as its last argument, and compares with what's intended.
row() {
    local label=$1 want=("$2" "$3" "$4")
    shift 4
    local results=() mismatch="" detail="" i=0 sandbox got out
    for sandbox in soft appcontainer low; do
        if out=$("$@" $sandbox 2>&1); then got=ok; else got=fails; fi
        case ${want[$i]}/$got in
        ok/ok | fails/fails) results+=("$sandbox $got") ;;
        gap/fails) results+=("$sandbox fails (known gap)") gaps=$((gaps + 1)) ;;
        gap/ok) results+=("$sandbox ok (a known gap that passes now)") ;;
        *)
            results+=("$sandbox $got, not ${want[$i]}") mismatch=yes
            detail="$sandbox: $(grep -v '^\s*$' <<<"$out" | tail -1 | cut -c1-100)"
            ;;
        esac
        i=$((i + 1))
    done
    local joined
    joined=$(printf '%s, ' "${results[@]}")
    if [ -n "$mismatch" ]; then fail "$label: ${joined%, }" "$detail"; else pass "$label: ${joined%, }"; fi
}

# Fixtures: a note, a one-page PDF, an archive of the note, and two clips of
# silence (8 kHz, 8-bit, mono), one long enough to still play when its
# window is looked at: VLC names a clip in its title while it plays it,
# which is within a second or two of starting, but now and then 30 s later
# (docs/findings.md).
printf 'a note for zigsaw\r\n' >"$docs\\zigsaw-note.txt"
cat >"$docs\\zigsaw-doc.pdf" <<'EOF'
%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 100]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj
4 0 obj<</Length 44>>stream
BT /F1 18 Tf 20 40 Td (hello zigsaw) Tj ET
endstream endobj
5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
trailer<</Root 1 0 R>>
%%EOF
EOF
# wav <seconds> <file>
wav() {
    local n=$(($1 * 8000))
    {
        printf 'RIFF' && le32 $((n + 36)) && printf 'WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x40\x1f\x00\x00\x01\x00\x08\x00data' && le32 $n
        head -c $n /dev/zero | tr '\0' '\200'
    } >"$2"
}
le32() { printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($1 & 255)) $(($1 >> 8 & 255)) $(($1 >> 16 & 255)) $(($1 >> 24 & 255)))"; }
wav 60 "$docs\\zigsaw-tone.wav"
wav 1 "$work\\zigsaw-short.wav"
(cd "$docs" && "$zigsaw" run $SEVENZIP a -bd zigsaw-archive.7z zigsaw-note.txt >/dev/null 2>&1)

# Where these apps would keep settings outside zigsaw. Only what isn't there
# before the suite counts, and only that is removed afterwards: someone may
# use the apps installed the usual way.
real_dirs=("$APPDATA\\Notepad++" "$LOCALAPPDATA\\SumatraPDF" "$APPDATA\\vlc")
absent_before=()
for d in "${real_dirs[@]}"; do [ -e "$d" ] || absent_before+=("$d"); done
had_7zip_key=false
reg query 'HKCU\Software\7-Zip' >/dev/null 2>&1 && had_7zip_key=true

cd "$work" || exit 1

data() { echo "$ZIGSAW_HOME\\data\\$1"; }
# opens <id> <export> <file> <title> <settings file name> <sandbox>: the app
# opens the file, the title names it within $window_wait seconds (15 unless
# set), it closes when asked, and its settings are then in its data
# directory.
opens() {
    local id=$1 cmd=$2 file=$3 title=$4 settings=$5 sandbox=$6 limit=${window_wait:-15}
    [ -z "$settings" ] || find "$(cygpath -u "$(data "$id")")" -name "$settings" -delete 2>/dev/null
    local start=$SECONDS
    "$zigsaw" run --sandbox=$sandbox --command=$cmd --file="$file" $id >"$work\\run.log" 2>&1 &
    local runner=$! status i
    "$winwait" "$title" $limit --close
    status=$?
    # zigsaw ends once the app's processes have (it gives them up to 5 s).
    for i in $(seq 50); do
        kill -0 $runner 2>/dev/null || break
        sleep 0.2
    done
    if kill -0 $runner 2>/dev/null; then
        kill $runner
        wait $runner
        echo "no window named $title closed (winwait $status after $((SECONDS - start)) s); $(tail -1 "$work\\run.log")"
        return 1
    fi
    wait $runner || { echo "zigsaw run failed: $(tail -1 "$work\\run.log")"; return 1; }
    [ $status -eq 0 ] || { echo "winwait $status"; return 1; }
    [ -z "$settings" ] && return 0
    [ -n "$(find "$(cygpath -u "$(data "$id")")" -name "$settings")" ] || { echo "no $settings in its data directory"; return 1; }
}

# In an AppContainer, 7-Zip's file manager opens its root instead: it goes
# through the archive's path from the drive root, whose folders it can't read.
row "7-Zip's file manager opens an archive given with --file" ok gap ok \
    opens $SEVENZIP 7zfm "$docs\\zigsaw-archive.7z" 'zigsaw-archive.7z' ''
# 7-Zip keeps its settings in HKCU\Software\7-Zip, which its recipe declares:
# zigsaw keeps the key with its data, and puts it in HKCU only while it runs,
# labelled or granted so that it saves there in every sandbox. Its file
# manager saves its window's position when it closes.
keeps_settings() {
    $had_7zip_key && { echo "HKCU\\Software\\7-Zip existed before"; return 1; }
    rm -f "$(data $SEVENZIP)\\registry\\user.dat"*
    opens $SEVENZIP 7zfm "$docs\\zigsaw-archive.7z" 'class:7-Zip::FM' '' "$1" || return 1
    ! reg query 'HKCU\Software\7-Zip' >/dev/null 2>&1 || { echo "HKCU\\Software\\7-Zip is still there"; return 1; }
    "$zigsaw" run --sandbox=$1 --command=reg $SEVENZIP query 'HKCU\Software\7-Zip\FM' /v Position >/dev/null 2>&1 ||
        { echo "its next run doesn't find the position it saved"; return 1; }
}
if $had_7zip_key; then
    echo "skip  7-Zip keeps its settings with its data: HKCU\\Software\\7-Zip was there before"
else
    row "7-Zip keeps its settings with its data, and in HKCU only while it runs" ok ok ok keeps_settings
fi
row "Notepad++ opens a file given with --file, and keeps its settings in its data directory" ok ok ok \
    opens $NPP notepad++ "$docs\\zigsaw-note.txt" 'zigsaw-note.txt - Notepad++' config.xml
row "SumatraPDF opens a PDF given with --file, and keeps its settings in its data directory" ok ok ok \
    opens $SUMATRA sumatrapdf "$docs\\zigsaw-doc.pdf" 'zigsaw-doc.pdf - SumatraPDF' SumatraPDF-settings.txt
window_wait=60 row "VLC plays a clip given with --file, and keeps its settings in its data directory" ok ok ok \
    opens $VLC vlc "$docs\\zigsaw-tone.wav" 'zigsaw-tone.wav - VLC media player' vlc-qt-interface.ini
decodes() {
    rm -f "$work\\decoded.raw"
    timeout 60 "$zigsaw" run --sandbox=$1 $VLC -I dummy --play-and-exit --aout=afile --audiofile-file=decoded.raw zigsaw-short.wav >"$work\\run.log" 2>&1 ||
        { tail -1 "$work\\run.log"; return 1; }
    [ "$(stat -c %s "$work\\decoded.raw")" -gt 8000 ]
}
row "VLC decodes a clip without a window" ok ok ok decodes

untouched() {
    local d
    for d in "${absent_before[@]}"; do [ ! -e "$d" ] || { echo "$d appeared"; return 1; }; done
}
check "Notepad++, SumatraPDF and VLC left the real AppData alone" untouched

# finds_documents <sandbox>: where SHGetKnownFolderPath puts Documents, which
# the probe may use, and Downloads, which it may not.
finds_documents() {
    local out
    out=$("$zigsaw" run --sandbox=$1 $HOSTPROBE </dev/null 2>&1) || { echo "$out"; return 1; }
    grep -qF "folder Documents = $(data $HOSTPROBE)\\home\\Documents (write ok)" <<<"$out" || { grep 'folder Documents' <<<"$out"; return 1; }
    grep -q '^folder Downloads = .* (missing)$' <<<"$out" || { grep 'folder Downloads' <<<"$out"; return 1; }
}
row "A desktop program finds Documents in its home, as yours, and writes it; not Downloads" ok ok ok finds_documents
# linked <id> <folder...>: the folders are links in the app's home.
linked() {
    local id=$1 f
    shift
    for f in "$@"; do [ -L "$(data "$id")\\home\\$f" ] || { echo "no $f in $id's home"; return 1; }; done
}
documents_apps_linked() {
    local id
    for id in $SEVENZIP $NPP $SUMATRA; do linked $id Desktop Documents Downloads || return 1; done
}
check "7-Zip, Notepad++ and SumatraPDF have Desktop, Documents and Downloads in their homes" documents_apps_linked
check "VLC has Desktop, Downloads, Music, Pictures and Videos" linked $VLC Desktop Downloads Music Pictures Videos

shim_dir=$(dirname "$zigsaw")
# gui_installed <id> <export> <shortcut> <extension...>
gui_installed() {
    local id=$1 cmd=$2 link=$3 ext
    shift 3
    cmp -s "$ZIGSAW_HOME\\bin\\$cmd.exe" "$shim_dir\\zigsaw-shimw.exe" || { echo "$cmd hasn't the windowless shim"; return 1; }
    [ -f "$ZIGSAW_SHORTCUTS_DIR\\$link.lnk" ] || { echo "no shortcut $link"; return 1; }
    for ext in "$@"; do
        reg query "HKCU\\$classes\\$ext\\OpenWithProgids" /v "Zigsaw.$id.${ext#.}" >/dev/null 2>&1 || { echo "$ext isn't registered"; return 1; }
    done
}
check "7-Zip's file manager gets the windowless shim, a shortcut, and .7z, .zip, .tar, .gz, .xz" gui_installed $SEVENZIP 7zfm '7-Zip File Manager' .7z .zip .tar .gz .xz
check "7z, its command-line program, gets the console shim" cmp -s "$ZIGSAW_HOME\\bin\\7z.exe" "$shim_dir\\zigsaw-shim.exe"
check "Notepad++ gets the windowless shim, a shortcut, and .txt, .log, .ini" gui_installed $NPP notepad++ 'Notepad++' .txt .log .ini
check "SumatraPDF gets the windowless shim, a shortcut, and .pdf, .epub" gui_installed $SUMATRA sumatrapdf SumatraPDF .pdf .epub
check "VLC gets the windowless shim, a shortcut, and .mp4, .mkv, .mp3" gui_installed $VLC vlc 'VLC media player' .mp4 .mkv .mp3

cd "$root" || exit 1
for id in "${installed[@]}"; do "$zigsaw" rm --delete-data "$id" >/dev/null 2>&1; done
$had_7zip_key || reg delete 'HKCU\Software\7-Zip' /f >/dev/null 2>&1
for d in "${absent_before[@]}"; do rm -rf "$d"; done
reg delete "HKCU\\$classes" /f >/dev/null 2>&1
reg query 'HKCU\Software\ZigsawTest' 2>/dev/null | grep -q . || reg delete 'HKCU\Software\ZigsawTest' /f >/dev/null 2>&1
$own_store && rm -rf "$ZIGSAW_HOME"
rm -rf "$work" "$docs"
echo
echo "$failures check(s) failed; $gaps known gap(s)."
exit $((failures > 0))
