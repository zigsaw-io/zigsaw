#!/usr/bin/env bash
# End-to-end checks for installing zigsaw itself: scripts/package.sh lays out
# a release's files, and scripts/install.ps1 installs them from that
# directory, as it would from a release on GitHub, into a scratch store's bin,
# with a scratch registry key standing in for the user's environment
# variables. It upgrades over an app that's running, hands the commands of an
# app an earlier zigsaw installed to the new one, and removes itself.
#
#   tests/install.sh
#
# Needs Git Bash, Zig and Windows PowerShell; downloads nothing. Packages into
# a temporary directory unless PACKAGE_DIR names one that scripts/package.sh
# filled already, as the Release workflow does.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
# The long form: the installer writes the directory to PATH as
# GetFullPath gives it, long, and zigsaw names itself so in shims, while the
# temporary directory may have a short (8.3) name in it, as on GitHub's
# runners (C:\Users\RUNNER~1).
work=$(cygpath -wl "$(mktemp -d)")
export ZIGSAW_HOME="$work\\store"
bin="$ZIGSAW_HOME\\bin"
export ZIGSAW_SHORTCUTS_DIR="$work\\links"
# The user's PATH is read and written under this key of HKCU rather than
# Environment.
env_key="Software\\ZigsawTest\\install-$$"
export ZIGSAW_INSTALL_ENV_KEY="$env_key"
script="$root\\scripts\\install.ps1"
APP=test.install.wait

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

package=$(cygpath -aw "${PACKAGE_DIR:-$work\\package}")
if [ -z "${PACKAGE_DIR:-}" ]; then
    bash "$(cygpath -u "$root")/scripts/package.sh" "$(cygpath -u "$package")" >"$work\\package.log" 2>&1 ||
        { echo "packaging failed: $(tail -1 "$work\\package.log")"; exit 1; }
fi
(cd "$root" && zig build) || { echo "building zigsaw failed"; exit 1; }

install() { powershell -NoProfile -ExecutionPolicy Bypass -File "$script" -From "$package" -Dir "$bin" "$@"; }
path_value() { reg query "HKCU\\$env_key" /v Path | tr -d '\r' | grep ' Path '; }

check "the package has the zip, the installer and their hashes" sh -c \
    "test -f '$package\\zigsaw-x86_64-windows.zip' -a -f '$package\\install.ps1' && grep -q 'zigsaw-x86_64-windows.zip' '$package\\SHA256SUMS' && grep -q 'install.ps1' '$package\\SHA256SUMS'"
programs_noted() { for f in zigsaw.exe zigsaw-shim.exe zigsaw-shimw.exe zigsaw-relay.exe; do grep -q "^| \`$f\` | \`[0-9a-f]\{64\}\` |$" "$package\\notes.md" || return 1; done; }
check "its notes list the four programs' hashes" programs_noted

# An app that an earlier zigsaw installed, here the one in zig-out: its shim
# names that zigsaw.
"$root\\zig-out\\bin\\zigsaw.exe" build "$root\\tests\\install\\app.json" >/dev/null 2>&1 || { echo "building the test app failed"; exit 1; }
check "an earlier zigsaw's shim names it" grep -qF "$root\\zig-out\\bin\\zigsaw.exe" "$bin\\install-wait.shim"

# A PATH as Windows keeps it: referring to another variable.
reg add "HKCU\\$env_key" /v Path /t REG_EXPAND_SZ /d '%USERPROFILE%\tools;C:\other' /f >/dev/null

corrupt="$work\\corrupt"
mkdir -p "$corrupt"
cp "$package\\zigsaw-x86_64-windows.zip" "$package\\SHA256SUMS" "$corrupt\\"
printf 'x' >>"$corrupt\\zigsaw-x86_64-windows.zip"
refuses_corrupt() {
    local out
    out=$(powershell -NoProfile -ExecutionPolicy Bypass -File "$script" -From "$corrupt" -Dir "$bin" 2>&1) && { echo "it installed"; return 1; }
    # PowerShell wraps the message at the console's width.
    tr -d '\r\n' <<<"$out" | grep -q "Nothing was installed" || { echo "$out"; return 1; }
    [ ! -e "$bin\\zigsaw.exe" ] && path_value | grep -qF '%USERPROFILE%\tools;C:\other' && ! path_value | grep -qF "$bin"
}
check "a zip that isn't the one SHA256SUMS lists is refused, and nothing changes" refuses_corrupt

installs() {
    local out
    out=$(install 2>&1) || { echo "$out"; return 1; }
    grep -q "^Installed zigsaw [0-9][0-9.]* in " <<<"$out" || { echo "$out"; return 1; }
    for f in zigsaw.exe zigsaw-shim.exe zigsaw-shimw.exe zigsaw-relay.exe; do [ -f "$bin\\$f" ] || { echo "no $f"; return 1; }; done
    [ "$("$bin\\zigsaw.exe" version | tr -d '\r')" = "zigsaw $(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$root\\build.zig.zon")" ]
}
check "it installs zigsaw and its shims, with build.zig.zon's version" installs
version_info() {
    local version f info
    version=$("$bin\\zigsaw.exe" version | tr -d '\r' | cut -d' ' -f2)
    for f in zigsaw.exe zigsaw-shim.exe zigsaw-shimw.exe zigsaw-relay.exe; do
        info=$(powershell -NoProfile -Command "\$v = (Get-Item -LiteralPath '$bin\\$f').VersionInfo; \$v.ProductVersion + '|' + \$v.OriginalFilename" | tr -d '\r')
        [ "$info" = "$version|$f" ] || { echo "$f: $info"; return 1; }
        grep -a -q 'level="asInvoker"' "$bin\\$f" || { echo "$f has no manifest"; return 1; }
    done
}
check "each program's version information has zigsaw's version, and its manifest runs it as the user" version_info
check "the installed zigsaw.exe is the packaged one, without debug information" sh -c "! grep -a -q 'zigsaw\.pdb' '$bin\\zigsaw.exe'"
check "the app's shim names the installed zigsaw now (zigsaw repair)" grep -qF "zigsaw = $bin\\zigsaw.exe" "$bin\\install-wait.shim"
check "its command runs through it" "$bin\\install-wait.exe" 1
path_added() {
    path_value | grep -q 'REG_EXPAND_SZ' || { echo "the type changed: $(path_value)"; return 1; }
    path_value | grep -qF "%USERPROFILE%\\tools;C:\\other;$bin" || { path_value; return 1; }
}
check "PATH gains the directory, and stays as it was otherwise: its type, and the variables it names" path_added

# The shim runs the installed zigsaw, which waits for the app.
"$bin\\install-wait.exe" 12 &
waiter=$!
sleep 2
upgrades() {
    local out
    out=$(install 2>&1) || { echo "$out"; return 1; }
    ls "$(cygpath -u "$bin")"/zigsaw.exe.old-* >/dev/null 2>&1 || { echo "nothing was moved aside: $out"; return 1; }
    "$bin\\zigsaw.exe" version >/dev/null
}
check "it upgrades while zigsaw is running an app, moving the running program aside" upgrades
once() { [ "$(path_value | grep -oF "$bin" | wc -l)" -eq 1 ]; }
check "PATH has the directory once" once
wait $waiter
check "the app that was running ended normally" test $? -eq 0
cleans() { install >/dev/null 2>&1 && ! ls "$(cygpath -u "$bin")"/zigsaw.exe.old-* >/dev/null 2>&1; }
check "the next install removes what was moved aside" cleans

# Piped to iex, as the README says, with its settings in the environment.
piped() {
    local out
    out=$(ZIGSAW_INSTALL_FROM="$package" ZIGSAW_INSTALL_DIR="$work\\piped" ZIGSAW_INSTALL_NO_PATH=1 \
        powershell -NoProfile -Command "Get-Content -Raw -LiteralPath '$script' | Invoke-Expression" 2>&1) || { echo "$out"; return 1; }
    [ -f "$work\\piped\\zigsaw.exe" ] && ! path_value | grep -qF "$work\\piped"
}
check "piped to Invoke-Expression, it installs where the environment says, and leaves PATH alone when told" piped

refuses_with_apps() {
    local out
    out=$(install -Uninstall 2>&1) && { echo "it uninstalled"; return 1; }
    grep -q "still installed: $APP" <<<"$out" && [ -f "$bin\\zigsaw.exe" ]
}
check "uninstalling is refused while apps are installed" refuses_with_apps
"$bin\\zigsaw.exe" rm --delete-data $APP >/dev/null 2>&1
uninstalls() {
    local out
    out=$(install -Uninstall 2>&1) || { echo "$out"; return 1; }
    for f in zigsaw.exe zigsaw-shim.exe zigsaw-shimw.exe zigsaw-relay.exe; do [ ! -e "$bin\\$f" ] || { echo "$f is still there"; return 1; }; done
    path_value | grep -q 'REG_EXPAND_SZ.*%USERPROFILE%\\tools;C:\\other$' || { path_value; return 1; }
}
check "uninstalling removes the programs and the PATH entry, and nothing else of PATH" uninstalls

reg delete "HKCU\\$env_key" /f >/dev/null 2>&1
reg query 'HKCU\Software\ZigsawTest' 2>/dev/null | grep -q . || reg delete 'HKCU\Software\ZigsawTest' /f >/dev/null 2>&1
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
