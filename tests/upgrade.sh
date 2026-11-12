#!/usr/bin/env bash
# End-to-end checks for upgrading from real releases: each older release in
# RELEASES, downloaded from GitHub and checked against the hashes below, is
# installed with its own install.ps1 into a scratch store, where it installs an
# app and leaves what a user's store has: data, a command a run installed, a
# shortcut, a named volume an override mounts, and registry keys a killed run
# left in HKCU. Then that zigsaw runs `zigsaw upgrade`, to a package of this
# checkout signed by a key of this run's own, and the rows check that the store
# works as this zigsaw keeps it. Busybox app (tests/upgrade/app.json).
#
#   tests/upgrade.sh
#
# Needs Git Bash, Zig, Windows PowerShell and network access (the releases,
# and the busybox download unless SEED_DOWNLOADS has it). Packages this
# checkout into a temporary directory unless PACKAGE_DIR names one that
# scripts/package.sh filled already; RELEASES_DIR may name a directory with a
# folder per release that has its files, instead of downloading them.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
work=$(cygpath -wl "$(mktemp -d)")
APP=test.upgrade.app
KEY='HKCU\Software\ZigsawTest\UpgradeApp'

# The releases: the first with volumes, and the newest that kept apps' data in
# data\. The zip's hash, as each release's SHA256SUMS lists it.
RELEASES=${RELEASES:-v0.80.0 v0.83.0}
release_zip_sha256() {
    case $1 in
        v0.80.0) echo bb8322d0f02934774255c836ff09001d87dc730c05947b87d29548402d9007df ;;
        v0.83.0) echo 7c6bf0f3f3fd8889188b67e320c4d98d9900cd4b14a05a371d61f494361ad546 ;;
        *) return 1 ;;
    esac
}

suite_key="Software\\ZigsawTest\\upgrade-$$"
export ZIGSAW_INSTALL_ENV_KEY="$suite_key-env"
export ZIGSAW_GRANTS_KEY="$suite_key-grants"
export ZIGSAW_TASK_NAME="ZigsawTest-upgrade-$$"
sch="$(cygpath -u "$WINDIR")/System32/schtasks.exe"
cleanup() {
    reg delete "HKCU\\$suite_key-env" /f >/dev/null 2>&1
    reg delete "HKCU\\$suite_key-grants" /f >/dev/null 2>&1
    reg delete "$KEY" /f >/dev/null 2>&1
    "$sch" /delete /tn "$ZIGSAW_TASK_NAME" /f >/dev/null 2>&1
    reg query 'HKCU\Software\ZigsawTest' 2>/dev/null | grep -q . || reg delete 'HKCU\Software\ZigsawTest' /f >/dev/null 2>&1
}
trap cleanup EXIT

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
        return 1
    fi
}
absent() { [ ! -e "$1" ]; }
# says <text> <command...>: the command's output, errors included, has the text.
says() {
    local text=$1 out
    shift
    out=$("$@" 2>&1)
    grep -qF -- "$text" <<<"$out" || { echo "$out"; return 1; }
}

this_version=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$root\\build.zig.zon")

# This checkout's release, signed as scripts/sign-release.sh signs one, by a
# key that only counts where ZIGSAW_UPGRADE_FROM is set.
package=$(cygpath -aw "${PACKAGE_DIR:-$work\\package}")
if [ -z "${PACKAGE_DIR:-}" ]; then
    bash "$(cygpath -u "$root")/scripts/package.sh" "$(cygpath -u "$package")" >"$work\\package.log" 2>&1 ||
        { echo "packaging failed: $(tail -1 "$work\\package.log")"; exit 1; }
fi
(cd "$root" && zig build && zig build p256sign) || { echo "building zigsaw and the signer failed"; exit 1; }
signer="$root\\zig-out\\test\\zigsaw-p256sign.exe"

# The app's one source, busybox. frippery.org may refuse it (403), and only
# busybox's own recipe falls back to the copy next to its image, so this
# zigsaw builds that recipe once, unless SEED_DOWNLOADS has it.
BUSYBOX_SHA256=07bb1e5b095b00d68a695481f9240879f33c5724b40aa2308f999d54ed78f075
if [ -z "${SEED_DOWNLOADS:-}" ] || [ ! -f "$SEED_DOWNLOADS\\$BUSYBOX_SHA256" ]; then
    ZIGSAW_HOME="$work\\seed" ZIGSAW_USER_FOLDERS="$work\\seed-folders" "$root\\zig-out\\bin\\zigsaw.exe" build "$root\\recipes\\busybox.json" </dev/null >"$work\\seed.log" 2>&1 ||
        { echo "getting busybox failed: $(tail -1 "$work\\seed.log")"; exit 1; }
    ZIGSAW_HOME="$work\\seed" ZIGSAW_USER_FOLDERS="$work\\seed-folders" "$root\\zig-out\\bin\\zigsaw.exe" rm net.frippery.busybox </dev/null >/dev/null 2>&1
    ZIGSAW_HOME="$work\\seed" ZIGSAW_USER_FOLDERS="$work\\seed-folders" "$root\\zig-out\\bin\\zigsaw.exe" prune </dev/null >/dev/null 2>&1
    SEED_DOWNLOADS="$work\\seed\\cache\\downloads"
fi
next="$work\\next"
mkdir -p "$next"
cp "$package\\zigsaw-x86_64-windows.zip" "$package\\SHA256SUMS" "$package\\VERSION" "$next\\"
"$signer" key release "$work\\release.pub"
"$signer" sign release "$next\\SHA256SUMS" >"$next\\SHA256SUMS.sig"
export ZIGSAW_UPGRADE_KEY="$work\\release.pub"

# fetch_release <version>: a directory with the release's install.ps1, zip and SHA256SUMS.
fetch_release() {
    local v=$1 dir="$work\\releases\\$1" want got f
    want=$(release_zip_sha256 "$v") || { echo "no hash for $v in tests/upgrade.sh"; return 1; }
    mkdir -p "$dir"
    for f in zigsaw-x86_64-windows.zip install.ps1 SHA256SUMS; do
        if [ -n "${RELEASES_DIR:-}" ] && [ -f "$RELEASES_DIR\\$v\\$f" ]; then
            cp "$RELEASES_DIR\\$v\\$f" "$dir\\" || return 1
        else
            curl -fsSL --retry 3 -o "$dir\\$f" "https://github.com/zigsaw-io/zigsaw/releases/download/$v/$f" || { echo "downloading $v's $f failed"; return 1; }
        fi
    done
    got=$(sha256sum <"$dir\\zigsaw-x86_64-windows.zip" | cut -d' ' -f1)
    [ "$got" = "$want" ] || { echo "$v's zip is $got, not $want"; return 1; }
    echo "$dir"
}

# shortcut_dir <lnk>: the working directory a shortcut starts in.
shortcut_dir() {
    powershell -NoProfile -Command "(New-Object -ComObject WScript.Shell).CreateShortcut('$1').WorkingDirectory" | tr -d '\r'
}
# shortcut_aumid <lnk>: the AppUserModelID it names (since 0.92), or nothing.
shortcut_aumid() {
    powershell -NoProfile -Command "\$f = Get-Item -LiteralPath '$1'; (New-Object -ComObject Shell.Application).NameSpace(\$f.DirectoryName).ParseName(\$f.Name).ExtendedProperty('System.AppUserModel.ID')" | tr -d '\r'
}

# from_release <version>: the rows for an upgrade from that release.
from_release() {
    local v=$1
    echo "--- from $v"
    rel=$(fetch_release "$v") || { printf 'FAIL  %s\n      %s\n' "$v: the release" "$rel"; failures=$((failures + 1)); return; }
    base="$work\\$v"
    export ZIGSAW_HOME="$base\\store"
    export ZIGSAW_USER_FOLDERS="$base\\folders"
    export ZIGSAW_SHORTCUTS_DIR="$base\\links"
    mkdir -p "$ZIGSAW_USER_FOLDERS\\Documents" "$ZIGSAW_SHORTCUTS_DIR" "$ZIGSAW_HOME\\cache\\downloads"
    if [ -n "${SEED_DOWNLOADS:-}" ]; then
        cp -n "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/" 2>/dev/null
    fi
    bin="$ZIGSAW_HOME\\bin"
    z() { "$bin\\zigsaw.exe" "$@" </dev/null; }
    data_old="$ZIGSAW_HOME\\data\\$APP"
    data_new="$ZIGSAW_HOME\\volumes\\$APP"
    lnk="$ZIGSAW_SHORTCUTS_DIR\\Zigsaw Upgrade Test.lnk"

    # --- What the older zigsaw leaves ------------------------------------
    old_installs() {
        powershell -NoProfile -ExecutionPolicy Bypass -File "$rel\\install.ps1" -From "$rel" -Dir "$bin" -NoUpdateCheck >/dev/null || return 1
        [ "$(z version | tr -d '\r')" = "zigsaw ${v#v}" ]
    }
    check "$v installs with its own install.ps1" old_installs || return
    old_store() {
        z build "$root\\tests\\upgrade\\app.json" >/dev/null 2>&1 || { z build "$root\\tests\\upgrade\\app.json"; return 1; }
        z run $APP sh -c 'echo kept > "$USERPROFILE/../kept.txt"' &&
            z run $APP sh -c 'mkdir -p "$USERPROFILE/../bin" && printf "@echo tool-ran\r\n" > "$USERPROFILE/../bin/upgrade-tool.cmd"' &&
            z run $APP sh -c "reg add '$KEY' /v v /d saved /f >/dev/null" &&
            z override --volume=keep:state $APP >/dev/null 2>&1 &&
            z run $APP sh -c 'echo named > "$USERPROFILE/../state/named.txt"' || return 1
        # Where everything is, as that zigsaw keeps it.
        [ -f "$data_old\\kept.txt" ] || { echo "no kept.txt in $data_old"; return 1; }
        [ -f "$ZIGSAW_HOME\\volumes\\keep\\named.txt" ] || { echo "the named volume has no named.txt"; return 1; }
        [ -f "$bin\\upgrade-tool.exe" ] || { echo "no command for upgrade-tool"; return 1; }
        [ -f "$lnk" ] || { echo "no shortcut"; return 1; }
        shortcut_dir "$lnk" | grep -qF "\\data\\$APP" || { echo "the shortcut starts in $(shortcut_dir "$lnk")"; return 1; }
        [ -z "$(shortcut_aumid "$lnk")" ] || { echo "the shortcut already names a taskbar button: $(shortcut_aumid "$lnk")"; return 1; }
    }
    check "  it installs an app with data, a command a run added, a shortcut and a named volume" old_store || return
    # A run that doesn't end: its keys stay in HKCU, with that zigsaw's record.
    killed_run() {
        z run $APP sh -c "reg add '$KEY' /v v /d killed /f >/dev/null && sleep 60" &
        local pid=$! i
        for i in $(seq 1 60); do
            reg query "$KEY" /v v 2>/dev/null | grep -q killed && break
            sleep 0.5
        done
        taskkill /F /T /PID "$(cat /proc/$pid/winpid)" >/dev/null 2>&1
        wait $pid 2>/dev/null
        reg query "$KEY" /v v 2>/dev/null | grep -q killed || { echo "the key isn't in HKCU after the kill"; return 1; }
    }
    check "  a run of it killed leaves its keys in HKCU" killed_run

    # --- zigsaw upgrade --------------------------------------------------
    upgrades() {
        local out
        out=$(ZIGSAW_UPGRADE_FROM="$next" "$bin\\zigsaw.exe" upgrade --yes 2>&1 </dev/null) || { echo "$out"; return 1; }
        grep -qF "upgraded zigsaw ${v#v} to $this_version" <<<"$out" || { echo "$out"; return 1; }
        [ "$(z version | tr -d '\r')" = "zigsaw $this_version" ]
    }
    check "  $v upgrades to this checkout's $this_version" upgrades || return

    check "  the app's data moved to its own volume, and data\\ is gone" sh -c \
        "test -f '$data_new\\kept.txt' && test ! -e '$ZIGSAW_HOME\\data'"
    keys_back() {
        reg query "$KEY" >/dev/null 2>&1 && { echo "the key is still in HKCU"; return 1; }
        [ "$(z run $APP sh -c "reg query '$KEY' /v v" | tr -d '\r' | grep -o 'killed')" = killed ]
    }
    check "  the keys the killed run left went back into its data, and a run has them" keys_back
    check "  a run reads its data" sh -c "[ \"\$(\"\$0\" run $APP sh -c 'cat \"\$USERPROFILE/../kept.txt\"' </dev/null | tr -d '\r')\" = kept ]" "$bin\\zigsaw.exe"
    check "  the command a run added runs" sh -c "\"\$0\" | tr -d '\r' | grep -qx tool-ran" "$bin\\upgrade-tool.exe"
    check "  the app's export runs" sh -c "\"\$0\" -c 'echo hi' | tr -d '\r' | grep -qx hi" "$bin\\upgrade-sh.exe"
    no_old_paths() {
        if grep -l -F "\\data\\$APP" "$(cygpath -u "$bin")"/*.shim 2>/dev/null; then return 1; fi
        shortcut_dir "$lnk" | grep -qF "\\volumes\\$APP" || { echo "the shortcut starts in $(shortcut_dir "$lnk")"; return 1; }
    }
    check "  no shim names data\\, and the shortcut starts in the app's volume (repair)" no_old_paths
    names_button() {
        local got
        got=$(shortcut_aumid "$lnk")
        [ "$got" = "Zigsaw.$APP" ] || { echo "got: $got"; return 1; }
    }
    check "  the shortcut names the app's taskbar button now (repair)" names_button
    check "  the named volume is still mounted" sh -c "[ \"\$(\"\$0\" run $APP sh -c 'cat \"\$USERPROFILE/../state/named.txt\"' </dev/null | tr -d '\r')\" = named ]" "$bin\\zigsaw.exe"
    check "  volume ls lists both" sh -c "\"\$0\" volume ls </dev/null | grep -q '^$APP ' && \"\$0\" volume ls </dev/null | grep -q '^keep '" "$bin\\zigsaw.exe"

    # --- The older zigsaw again, as "What it breaks" in docs/iteration-85.md says
    unzip -q -o "$rel\\zigsaw-x86_64-windows.zip" -d "$base\\old" || { echo "unzipping $v failed"; return; }
    older_again() {
        "$base\\old\\zigsaw.exe" run $APP sh -c 'test ! -f "$USERPROFILE/../kept.txt" && echo late > "$USERPROFILE/../late.txt"' </dev/null || { echo "$v found the data"; return 1; }
        says "a zigsaw before 0.85 left" z run $APP true && test -f "$data_new\\kept.txt"
    }
    check "  $v run again starts the app empty; this zigsaw says what it left, and keeps the volume" older_again

    # --- Taking it away --------------------------------------------------
    removes() {
        z rm --delete-data $APP >/dev/null 2>&1 || return 1
        absent "$data_new" && test -f "$ZIGSAW_HOME\\volumes\\keep\\named.txt" && absent "$bin\\upgrade-tool.exe" && absent "$lnk"
    }
    check "  rm --delete-data takes the app, its volume, command and shortcut, and keeps the named volume" removes
    check "  volume prune takes the named volume nothing mounts now" sh -c "\"\$0\" volume prune </dev/null >/dev/null 2>&1 && test ! -e '$ZIGSAW_HOME\\volumes\\keep'" "$bin\\zigsaw.exe"
}

for v in $RELEASES; do
    from_release "$v"
    # Whatever failed: what the store deployed is read-only until zigsaw takes it away.
    if [ -n "${bin:-}" ] && [ -x "$bin\\zigsaw.exe" ]; then
        "$bin\\zigsaw.exe" rm --delete-data $APP </dev/null >/dev/null 2>&1
        "$bin\\zigsaw.exe" prune --volumes </dev/null >/dev/null 2>&1
    fi
    reg delete "$KEY" /f >/dev/null 2>&1
    rm -rf "$(cygpath -u "$work\\$v")"
    bin=
done

cd /
rm -rf "$(cygpath -u "$work")"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
