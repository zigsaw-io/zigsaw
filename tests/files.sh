#!/usr/bin/env bash
# Files end to end: Files (recipes/no-publish/files.json), a C# file manager
# with WinUI 3, built from its release tarball with .NET's SDK image and
# patched to run without a package, runs on .NET's runtime image: it's laid
# out as an app without a package (its manifest beside it, its assets, the
# Windows App SDK in its own directory), gets the windowless shim and a
# shortcut with the icon in its executable, starts up and finds the drives,
# opens a folder given on its command line, and keeps its settings in its
# data directory: files in its Local AppData, registry values in a hive.
# Only the soft sandbox: at low integrity and in an AppContainer, Windows'
# storage APIs refuse an app without a package, and Files shows no drives
# (docs/findings.md).
#
# Not in CI: .NET's images can't be published, so they're built from
# Microsoft's download, and Files' first build takes about ten minutes.
#
#   FILES_HOME=path\to\store bash tests/files.sh [path\to\zigsaw.exe]
#
# It builds .NET's images and Files into the store unless it has them (the
# NuGet packages Files' vendor step fetches are kept in the store's
# downloads, so later builds take a few minutes), and removes what it
# installed afterwards. Files opens windows on the desktop for a moment.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
ZIGSAW_HOME=${FILES_HOME:-${BUILD_HOME:-}}
if [ -z "$ZIGSAW_HOME" ]; then
    echo "tests/files.sh needs a store in FILES_HOME or BUILD_HOME; it builds .NET's images and Files there"
    echo "unless it has them (about ten minutes the first time)."
    exit 1
fi
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
FILES=community.files.Files
# Start menu shortcuts go here rather than the user's Start menu.
links="$work\\links"
export ZIGSAW_SHORTCUTS_DIR="$links"
# The user's folders Files may use are these, not yours.
for f in Desktop Documents Downloads Music Pictures Videos; do mkdir -p "$work\\folders\\$f"; done
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

installed_dotnet=false installed_files=false
[ -f "$ZIGSAW_HOME\\refs\\com.microsoft.dotnet.Sdk.json" ] || installed_dotnet=true
[ -f "$ZIGSAW_HOME\\refs\\$FILES.json" ] || installed_files=true
for r in dotnet-sdk dotnet; do
    z build "$root\\recipes\\no-publish\\$r.json" >"$work\\$r.log" 2>&1 || echo "building $r.json failed: $(tail -1 "$work\\$r.log")"
done
check "Files 4.3 builds from its release tarball, with its NuGet packages vendored" z build "$root\\recipes\\no-publish\\files.json"
files_dir="$ZIGSAW_HOME\\deploy\\$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of $FILES | cut -d: -f2)" | tail -1 | cut -d: -f2)"
bin="$files_dir\\bin"

# Without a package, Files reads its name and version from the manifest
# copied next to it, and its icons from Assets, which the recipe copies
# (dotnet publish leaves them out: a package build takes them from the
# package's layout instead).
layout() {
    grep -q '<DisplayName>Files - Zigsaw build</DisplayName>' "$bin\\Package.appxmanifest" || { echo "no Files - Zigsaw build in its manifest"; return 1; }
    test -f "$bin\\Assets\\AppTiles\\Dev\\Logo.ico" || { echo "no Assets\\AppTiles\\Dev\\Logo.ico"; return 1; }
    test -f "$bin\\Microsoft.ui.xaml.dll" || { echo "no Windows App SDK in bin"; return 1; }
    [ ! -e "$bin\\Assets\\Libraries" ] || { echo "Assets\\Libraries is in the image"; return 1; }
    [ -z "$(find "$files_dir" -name '*.pdb' | head -1)" ] || { echo "PDBs in the image"; return 1; }
}
check "it's laid out as an app without a package: its manifest, its assets and the Windows App SDK next to it" layout
# Framework-dependent: .NET comes from the runtime image, not its bin.
on_runtime() {
    grep -q '"framework"' "$bin\\Files.runtimeconfig.json" || { echo "Files.runtimeconfig.json names no shared framework"; return 1; }
    [ ! -e "$bin\\coreclr.dll" ] || { echo "it has a .NET runtime of its own"; return 1; }
}
check "it runs on .NET's runtime image rather than a runtime of its own" on_runtime

shim_dir=$(dirname "$zigsaw")
check "it gets the windowless shim and a shortcut" sh -c "cmp -s '$ZIGSAW_HOME\\bin\\files.exe' '$shim_dir\\zigsaw-shimw.exe' && test -f '$links\\Files - Zigsaw build.lnk'"
lnk_icon() { powershell -NoProfile -Command "(New-Object -ComObject WScript.Shell).CreateShortcut('$1').IconLocation" | tr -d '\r'; }
exe_icons() {
    powershell -NoProfile -Command "Add-Type -Namespace Z -Name I -MemberDefinition '[DllImport(\"shell32.dll\", CharSet = CharSet.Unicode)] public static extern uint ExtractIconEx(string f, int i, IntPtr[] l, IntPtr[] s, uint n);'; [Z.I]::ExtractIconEx('$1', -1, \$null, \$null, 0)" | tr -d '\r'
}
files_icon() {
    local ico
    ico=$(lnk_icon "$links\\Files - Zigsaw build.lnk")
    [ "$ico" = "$bin\\Files.exe,0" ] || { echo "Files: $ico"; return 1; }
    [ "$(exe_icons "$bin\\Files.exe")" -ge 1 ] || { echo "no icon in Files.exe"; return 1; }
}
check "its shortcut shows the icon in its executable" files_icon

# Files keeps running in the background when its window closes, and hands a
# new launch to an instance that does: none of this store's may be left over.
end_files() {
    powershell -NoProfile -Command "Get-Process Files -ErrorAction SilentlyContinue | Where-Object { \$_.Path -like '$ZIGSAW_HOME\\*' } | Stop-Process -Force" >/dev/null 2>&1
}
# stays_up <seconds> <zigsaw run arguments...>: the app is still running
# when the time is up, rather than having crashed or handed over. Then it
# ends Files, not zigsaw, so that the run ends as it would when Files exits:
# zigsaw puts Files' registry key back in its hive.
stays_up() {
    local seconds=$1
    shift
    end_files
    "$zigsaw" run "$@" >/dev/null 2>&1 &
    local run=$! i
    sleep "$seconds"
    if ! kill -0 $run 2>/dev/null; then
        wait $run
        echo "the run ended (exit code $?) within $seconds s"
        return 1
    fi
    end_files
    for i in $(seq 1 30); do kill -0 $run 2>/dev/null || break; sleep 1; done
    if kill -0 $run 2>/dev/null; then
        kill $run
        echo "zigsaw run didn't end after Files did"
        return 1
    fi
    wait $run
    return 0
}
state="$ZIGSAW_HOME\\data\\$FILES\\home\\AppData\\Local\\Files Community\\FilesDev\\LocalState"
launches() { grep -c '|Information|App launched' "$state\\debug.log" 2>/dev/null || echo 0; }
# Startup ends with "App launched" in Files' log, and the drives it found.
# Files catches what goes wrong at startup and carries on, so a run that
# stays up isn't enough.
started() {
    local before after
    before=$(launches)
    stays_up 20 $FILES || { echo "Files didn't stay up"; return 1; }
    after=$(launches)
    [ "$after" -gt "$before" ] || { echo "no 'App launched' in its log"; return 1; }
    tail -20 "$state\\debug.log" | grep -qF 'Drive added: C:\' || { echo "no drive C: in its log"; return 1; }
}
check "Files starts up and finds the drives" started

# Files saves its open tabs in its settings once they've loaded.
folder="$work\\Folder $$"
mkdir -p "$folder" && echo text >"$folder\\note.txt"
opens_folder() {
    stays_up 20 $FILES "$folder" || { echo "Files didn't stay up"; return 1; }
    grep -qF "Folder $$" "$state\\settings\\user_settings.json" || { echo "no tab for $folder in its settings"; return 1; }
}
check "it opens a folder given on its command line" opens_folder

# Files' own files go to its Local AppData, which is in its data directory;
# its registry values (HKCU\Software\Files Community, which its recipe
# declares) are in a hive there, and not in the real registry between runs.
kept() {
    test -f "$state\\settings\\user_settings.json" || { echo "no settings in its data directory"; return 1; }
    grep -aq TotalLaunchCount "$ZIGSAW_HOME\\data\\$FILES\\registry\\user.dat" || { echo "no Files values in its hive"; return 1; }
    ! reg query 'HKCU\Software\Files Community\FilesDev' >/dev/null 2>&1 || { echo "HKCU\\Software\\Files Community\\FilesDev is in the registry"; return 1; }
}
check "it keeps its settings in its data directory, and its registry values in a hive there" kept

cd "$root" || exit 1
end_files
$installed_files && z rm --delete-data $FILES >/dev/null 2>&1
$installed_dotnet && { z rm --delete-data com.microsoft.dotnet >/dev/null 2>&1; z rm --delete-data com.microsoft.dotnet.Sdk >/dev/null 2>&1; }
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
