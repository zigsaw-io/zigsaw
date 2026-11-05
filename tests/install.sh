#!/usr/bin/env bash
# End-to-end checks for installing zigsaw itself: scripts/package.sh lays out
# a release's files, and scripts/install.ps1 installs them from that
# directory, as it would from a release on GitHub, into a scratch store's bin,
# with a scratch registry key standing in for the user's environment
# variables. It upgrades over an app that's running, hands the commands of an
# app an earlier zigsaw installed to the new one, and removes itself. Then the
# same for `zigsaw upgrade`, from a release of the same code with a later version,
# and what install.ps1 does about the daily check, in a scratch LOCALAPPDATA whose
# store is the default one, under a scheduled task name of this run's own.
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
export ZIGSAW_GRANTS_KEY="Software\\ZigsawTest\\install-$$-grants"
export ZIGSAW_TASK_NAME="ZigsawTest-install-$$"
sch="$(cygpath -u "$WINDIR")/System32/schtasks.exe"
has_task() { "$sch" /query /tn "$1" >/dev/null 2>&1; }
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
programs_noted() { for f in zigsaw.exe zigsaw-shim.exe zigsaw-shimw.exe zigsaw-relay.exe zigsaw-host.exe zigsaw-notify.exe; do grep -q "^| \`$f\` | \`[0-9a-f]\{64\}\` |$" "$package\\notes.md" || return 1; done; }
check "its notes list the programs' hashes" programs_noted
version_file() { [ "$(tr -d '\r\n' <"$package\\VERSION")" = "$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$root\\build.zig.zon")" ]; }
check "and VERSION says which release it is" version_file

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
    for f in zigsaw.exe zigsaw-shim.exe zigsaw-shimw.exe zigsaw-relay.exe zigsaw-host.exe zigsaw-notify.exe; do [ -f "$bin\\$f" ] || { echo "no $f"; return 1; }; done
    [ "$("$bin\\zigsaw.exe" version | tr -d '\r')" = "zigsaw $(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$root\\build.zig.zon")" ]
}
check "it installs zigsaw and its shims, with build.zig.zon's version" installs
version_info() {
    local version f info
    version=$("$bin\\zigsaw.exe" version | tr -d '\r' | cut -d' ' -f2)
    for f in zigsaw.exe zigsaw-shim.exe zigsaw-shimw.exe zigsaw-relay.exe zigsaw-host.exe zigsaw-notify.exe; do
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
    for f in zigsaw.exe zigsaw-shim.exe zigsaw-shimw.exe zigsaw-relay.exe zigsaw-host.exe zigsaw-notify.exe; do [ ! -e "$bin\\$f" ] || { echo "$f is still there"; return 1; }; done
    path_value | grep -q 'REG_EXPAND_SZ.*%USERPROFILE%\\tools;C:\\other$' || { path_value; return 1; }
}
check "uninstalling removes the programs and the PATH entry, and nothing else of PATH" uninstalls
record_gone() { ! reg query "HKCU\\$ZIGSAW_GRANTS_KEY" >/dev/null 2>&1; }
check "and the record of what stores changed, which has nothing left" record_gone
reinstall_with_record() {
    local out
    install >/dev/null 2>&1 || return 1
    # Another store, still there, has something recorded.
    reg add "HKCU\\$ZIGSAW_GRANTS_KEY" /v "$work\\kept|test.other|low $work" /f >/dev/null 2>&1 &&
        mkdir -p "$work\\kept\\grants" && printf 'low %s\n' "$work" >"$work\\kept\\grants\\test.other.txt" || return 1
    out=$(install -Uninstall 2>&1) || { echo "$out"; return 1; }
    grep -q "still has what other stores changed" <<<"$out" && reg query "HKCU\\$ZIGSAW_GRANTS_KEY" 2>/dev/null | grep -qF 'test.other'
}
check "uninstalling leaves what another store still needs in the record, and says so" reinstall_with_record

# --- zigsaw upgrade --------------------------------------------------------------
# A later release of the same code: the only way to have a zigsaw that says it's newer.
this_version=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$root\\build.zig.zon")
next_version="${this_version%.*}.$((${this_version##*.} + 1))"
copy="$work\\copy"
mkdir -p "$copy" && (cd "$root" && git ls-files -co --exclude-standard -z | tar --null -T - -cf - | tar -xf - -C "$(cygpath -u "$copy")") ||
    { echo "copying the checkout failed"; exit 1; }
sed -i "s/\.version = \"$this_version\"/.version = \"$next_version\"/" "$(cygpath -u "$copy\\build.zig.zon")"
sed -i "s/\"version\": \"$this_version\"/\"version\": \"$next_version\"/" "$(cygpath -u "$copy\\zigsaw.json")"
next="$work\\next"
(cd "$copy" && bash scripts/package.sh "$(cygpath -u "$next")") >"$work\\next.log" 2>&1 ||
    { echo "packaging the later release failed: $(tail -1 "$work\\next.log")"; exit 1; }

install >/dev/null 2>&1 || { echo "installing again failed"; exit 1; }
"$bin\\zigsaw.exe" build "$root\\tests\\install\\app.json" >/dev/null 2>&1 || { echo "building the test app failed"; exit 1; }
up() { ZIGSAW_UPGRADE_FROM="$from" "$bin\\zigsaw.exe" upgrade "$@"; }
same_as_package() { # <package dir>: the programs in bin are that package's
    local unpacked="$work\\unpacked-$RANDOM" f
    powershell -NoProfile -Command "Expand-Archive -LiteralPath '$1\\zigsaw-x86_64-windows.zip' -DestinationPath '$unpacked'" || return 1
    for f in zigsaw.exe zigsaw-shim.exe zigsaw-shimw.exe zigsaw-relay.exe zigsaw-host.exe zigsaw-notify.exe; do
        cmp "$unpacked\\$f" "$bin\\$f" || return 1
    done
}
bin_unchanged() { same_as_package "$package" && ! ls "$(cygpath -u "$bin")" | grep -qE '\.(old|new)-'; }

from="$package"
up_to_date() {
    local out
    out=$(up --yes 2>&1) || { echo "$out"; return 1; }
    grep -q "zigsaw $this_version is up to date" <<<"$out" && bin_unchanged
}
check "upgrade: with nothing newer, it says so" up_to_date

from="$work\\next"
no_answer() {
    local out
    out=$(up 2>&1 </dev/null) && { echo "it upgraded"; return 1; }
    grep -q "nothing answered" <<<"$out" && bin_unchanged
}
check "upgrade: with nobody to answer, it doesn't, and says --yes would" no_answer
answer_no() {
    local out
    out=$(echo n | up 2>&1) && { echo "it upgraded"; return 1; }
    grep -q "Upgrade zigsaw $this_version to $next_version?" <<<"$out" && grep -q "zigsaw stays at $this_version" <<<"$out" && bin_unchanged
}
check "upgrade: it asks, naming both versions, and no means no" answer_no

corrupt_next="$work\\corrupt-next"
mkdir -p "$corrupt_next"
cp "$work\\next\\zigsaw-x86_64-windows.zip" "$work\\next\\SHA256SUMS" "$work\\next\\VERSION" "$corrupt_next\\"
printf 'x' >>"$corrupt_next\\zigsaw-x86_64-windows.zip"
from="$corrupt_next"
refuses_hash() {
    local out
    out=$(up --yes 2>&1) && { echo "it upgraded"; return 1; }
    grep -q "isn't the file its SHA256SUMS lists" <<<"$out" && grep -q "Nothing was changed" <<<"$out" && bin_unchanged
}
check "upgrade: a zip that isn't the one SHA256SUMS lists is refused, and nothing changes" refuses_hash

# A zip that's fine by its hash, of a zigsaw that isn't the release it says it is.
lying="$work\\lying"
mkdir -p "$lying"
cp "$package\\zigsaw-x86_64-windows.zip" "$package\\SHA256SUMS" "$lying\\"
printf '999.0.0\n' >"$lying\\VERSION"
from="$lying"
refuses_lie() {
    local out
    out=$(up --yes 2>&1) && { echo "it upgraded"; return 1; }
    grep -q "the new zigsaw says \"zigsaw $this_version\", but this release is 999.0.0" <<<"$out" && grep -q "Nothing was changed" <<<"$out" && bin_unchanged
}
check "upgrade: a program that isn't the version the release says is refused, and nothing changes" refuses_lie

missing="$work\\missing"
mkdir -p "$missing"
from="$missing"
refuses_missing() {
    local out
    out=$(up --yes 2>&1) && { echo "it upgraded"; return 1; }
    bin_unchanged
}
check "upgrade: no release there is an error, and nothing changes" refuses_missing

elsewhere() {
    local out
    out=$(ZIGSAW_UPGRADE_FROM="$work\\next" "$root\\zig-out\\bin\\zigsaw.exe" upgrade --yes 2>&1) && { echo "it upgraded"; return 1; }
    grep -q "isn't in its store's bin" <<<"$out" && grep -q "install.ps1" <<<"$out" && [ -f "$root\\zig-out\\bin\\zigsaw.exe" ]
}
check "upgrade: a zigsaw that isn't in its store's bin, as a dev build, won't replace itself" elsewhere

# The shim runs the installed zigsaw, which waits for the app.
"$bin\\install-wait.exe" 12 &
waiter=$!
sleep 2
from="$work\\next"
upgrades() {
    local out
    out=$(up --yes 2>&1) || { echo "$out"; return 1; }
    grep -q "upgraded zigsaw $this_version to $next_version" <<<"$out" || { echo "$out"; return 1; }
    [ "$("$bin\\zigsaw.exe" version | tr -d '\r')" = "zigsaw $next_version" ] || return 1
    same_as_package "$work\\next" || return 1
    ! ls "$(cygpath -u "$bin")" | grep -q '\.new-' || { echo "something was left behind"; return 1; }
    ls "$(cygpath -u "$bin")"/zigsaw.exe.old-* >/dev/null 2>&1 || { echo "nothing was moved aside"; return 1; }
}
check "upgrade: it replaces every program while zigsaw is running an app, moving the running one aside" upgrades
check "  the app's shim names the upgraded zigsaw, and runs through it" "$bin\\install-wait.exe" 1
wait $waiter
check "  the app that was running ended normally" test $? -eq 0
no_task_elsewhere() { ! "$bin\\zigsaw.exe" grants 2>/dev/null | grep -q 'scheduled task'; }
check "  in a store that isn't the default one, it starts no daily check" no_task_elsewhere
cleans_up() {
    local out
    out=$(up --yes 2>&1) || { echo "$out"; return 1; }
    grep -q "is up to date" <<<"$out"
    # Nothing newer: leftovers stay until there's something to do, or an install.
    install >/dev/null 2>&1 && ! ls "$(cygpath -u "$bin")" | grep -q '\.old-'
}
check "  what was moved aside goes with the next install" cleans_up
"$bin\\zigsaw.exe" rm --delete-data $APP >/dev/null 2>&1

# --- The daily check, for the default store ------------------------------------
# A LOCALAPPDATA of its own: what's the default store here isn't the user's.
default_home="$work\\lad"
mkdir -p "$default_home"
default_bin="$default_home\\zigsaw\\bin"
as_default() {
    env -u ZIGSAW_HOME LOCALAPPDATA="$default_home" powershell -NoProfile -ExecutionPolicy Bypass -File "$script" -From "$package" -NoPath "$@"
}
daily_on() {
    local out
    out=$(as_default 2>&1) || { echo "$out"; return 1; }
    tr -d '\r\n' <<<"$out" | grep -q "A daily check will tell you when updates are waiting; it installs nothing" || { echo "$out"; return 1; }
    has_task "$ZIGSAW_TASK_NAME" || { echo "no task"; return 1; }
    "$sch" /query /tn "$ZIGSAW_TASK_NAME" /xml | tr -d '\r' | grep -qF "<Command>$default_bin\\zigsaw-notify.exe</Command>"
}
check "installing into the default store starts the daily check, and says so" daily_on
off_remembered() {
    local out
    env -u ZIGSAW_HOME LOCALAPPDATA="$default_home" "$default_bin\\zigsaw.exe" updates off >/dev/null 2>&1 || return 1
    has_task "$ZIGSAW_TASK_NAME" && return 1
    out=$(as_default 2>&1) || { echo "$out"; return 1; }
    tr -d '\r\n' <<<"$out" | grep -q "stays off, as you left it" || { echo "$out"; return 1; }
    ! has_task "$ZIGSAW_TASK_NAME"
}
check "turned off, it stays off through an upgrade, and says so" off_remembered
back_on() { env -u ZIGSAW_HOME LOCALAPPDATA="$default_home" "$default_bin\\zigsaw.exe" updates on >/dev/null 2>&1 && has_task "$ZIGSAW_TASK_NAME"; }
check "  until it's turned on" back_on
no_update_check() {
    local out
    out=$(as_default -NoUpdateCheck 2>&1) || { echo "$out"; return 1; }
    tr -d '\r\n' <<<"$out" | grep -q "No daily check for updates" || { echo "$out"; return 1; }
    ! has_task "$ZIGSAW_TASK_NAME" && [ -f "$default_home\\zigsaw\\updates\\off" ]
}
check "-NoUpdateCheck removes it, and remembers" no_update_check
env -u ZIGSAW_HOME LOCALAPPDATA="$default_home" "$default_bin\\zigsaw.exe" updates on >/dev/null 2>&1
upgrade_default() {
    env -u ZIGSAW_HOME LOCALAPPDATA="$default_home" "$default_bin\\zigsaw.exe" updates off >/dev/null 2>&1
    rm -f "$default_home\\zigsaw\\updates\\off"
    env -u ZIGSAW_HOME LOCALAPPDATA="$default_home" ZIGSAW_UPGRADE_FROM="$work\\next" "$default_bin\\zigsaw.exe" upgrade --yes >/dev/null 2>&1 || return 1
    has_task "$ZIGSAW_TASK_NAME"
}
check "upgrade starts it too, for the default store, unless turned off" upgrade_default

# Going back with -Version, to a release from before there was a notify program.
old_package="$work\\old-package"
mkdir -p "$old_package"
powershell -NoProfile -Command "Expand-Archive -LiteralPath '$package\\zigsaw-x86_64-windows.zip' -DestinationPath '$work\\old-files'; Remove-Item -LiteralPath '$work\\old-files\\zigsaw-notify.exe'; Compress-Archive -Path '$work\\old-files\\*' -DestinationPath '$old_package\\zigsaw-x86_64-windows.zip'"
printf '%s  zigsaw-x86_64-windows.zip\n' "$(sha256sum <"$old_package\\zigsaw-x86_64-windows.zip" | cut -d' ' -f1)" >"$old_package\\SHA256SUMS"
installs_old() {
    local out
    out=$(env -u ZIGSAW_HOME LOCALAPPDATA="$default_home" powershell -NoProfile -ExecutionPolicy Bypass -File "$script" -From "$old_package" -NoPath 2>&1) || { echo "$out"; return 1; }
    [ -f "$default_bin\\zigsaw.exe" ] && [ ! -e "$default_bin\\zigsaw-notify.exe" ] || { echo "$out"; return 1; }
    ! has_task "$ZIGSAW_TASK_NAME" || { echo "the task stays, with nothing to start"; return 1; }
    [ ! -e "$default_home\\zigsaw\\updates\\off" ]
}
check "a release without zigsaw-notify still installs, and the task it couldn't run goes" installs_old
as_default >/dev/null 2>&1
uninstalls_task() {
    local out
    has_task "$ZIGSAW_TASK_NAME" || { echo "no task to begin with"; return 1; }
    out=$(as_default -Uninstall 2>&1) || { echo "$out"; return 1; }
    ! has_task "$ZIGSAW_TASK_NAME" && [ ! -e "$default_bin\\zigsaw-notify.exe" ] && [ ! -e "$default_home\\zigsaw\\updates\\off" ]
}
check "uninstalling removes the task and the program" uninstalls_task
not_in_scratch() { ! "$sch" /query /fo csv /nh 2>/dev/null | tr -d '\r' | grep -qF "\"\\$ZIGSAW_TASK_NAME"; }
check "no task of this run is left" not_in_scratch
"$sch" /delete /tn "$ZIGSAW_TASK_NAME" /f >/dev/null 2>&1

reg delete "HKCU\\$ZIGSAW_GRANTS_KEY" /f >/dev/null 2>&1
reg delete "HKCU\\$env_key" /f >/dev/null 2>&1
reg query 'HKCU\Software\ZigsawTest' 2>/dev/null | grep -q . || reg delete 'HKCU\Software\ZigsawTest' /f >/dev/null 2>&1
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
