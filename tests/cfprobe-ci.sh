#!/usr/bin/env bash
# Whether this machine lets an app run from Cloud Files placeholders, as lazy
# pulling would (see docs/experiment-cloud-files.md on the experiment/cfapi
# branch): the probe that iteration 77 runs on GitHub's Windows Server 2025
# before building on it. It changes nothing in zigsaw; tests/cfprobe.zig is the
# provider.
#
#   tests/cfprobe-ci.sh [<base dir>...]
#
# For each base directory (one temporary directory by default), on its drive:
# a fixture app with an eStargz layer (BusyBox from ghcr.io's net.frippery.busybox,
# copied twice, and a 15 MB text file) is built in a store there. Its layer is
# then mounted as placeholders where a second store's deployment belongs, and
# `zigsaw run` reads the text file through BusyBox started from a placeholder,
# under soft, low and appcontainer. Then, on the first: placeholders with no
# provider, and placeholders of Qt's runtime from ghcr.io's storage, by URL.
# CFPROBE_ACCOUNT, an account file as tests/standard-user.sh takes, adds a row
# as that standard user. ZIGSAW and CFPROBE name the programs (zig-out's by
# default). With GITHUB_STEP_SUMMARY set, the results go there too.
#
# Rows are `ok`, `FAIL`, or `note` (what Windows answered, for the record). It
# exits 1 if any row failed.

set -u
export MSYS_NO_PATHCONV=1
w() { cygpath -w "$1"; }
u() { cygpath -u "$1"; }

repo=$(w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${ZIGSAW:-$repo\\zig-out\\bin\\zigsaw.exe}
cfprobe=${CFPROBE:-$repo\\zig-out\\test\\zigsaw-cfprobe.exe}
[ -f "$(u "$zigsaw")" ] && [ -f "$(u "$cfprobe")" ] || { echo "build first: zig build && zig build cfprobe"; exit 2; }
if [ $# -eq 0 ]; then set -- "$(w "$(mktemp -d)")"; fi

scratch=$(w "$(mktemp -d)")
export ZIGSAW_USER_FOLDERS="$scratch\\folders"
export ZIGSAW_SHORTCUTS_DIR="$scratch\\links"
export ZIGSAW_TASK_NAME="ZigsawTest-cfprobe-$$"
export ZIGSAW_GRANTS_KEY="Software\\ZigsawTest\\cfprobe-$$"
mkdir -p "$(u "$ZIGSAW_USER_FOLDERS")" "$(u "$ZIGSAW_SHORTCUTS_DIR")"
trap 'reg delete "HKCU\\$ZIGSAW_GRANTS_KEY" /f >/dev/null 2>&1' EXIT

failed=0
rows=()
row() { # <ok|FAIL|note> <label> [detail]
    echo "$1  $2${3:+: $3}"
    rows+=("| $1 | $2 | ${3:-} |")
    [ "$1" = FAIL ] && failed=$((failed + 1))
    return 0
}

# --- Facts ----------------------------------------------------------------------
echo "== this machine"
ver=$(cmd /c ver | tr -d '\r' | grep .)
ubr=$(reg query 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' /v UBR 2>/dev/null | awk '/UBR/ { print $3 }')
product=$(reg query 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' /v ProductName 2>/dev/null | sed -n 's/.*REG_SZ *//p' | tr -d '\r')
row note "Windows" "$product, $ver, UBR $((ubr))"
row note "cldflt service" "$(sc query cldflt 2>&1 | tr -d '\r' | awk '/STATE/ { print $3, $4 }')"
filters=$(fltmc filters 2>&1 | tr -d '\r')
if grep -qi cldflt <<<"$filters"; then row note "fltmc" "CldFlt is loaded: $(grep -i cldflt <<<"$filters" | tr -s ' ')"
else row note "fltmc" "$(head -c 200 <<<"$filters" | tr '\n' ' ')"; fi
whoami_groups=$(whoami /groups 2>/dev/null | tr -d '\r')
grep -q 'S-1-16-12288' <<<"$whoami_groups" && row note "token" "elevated (high integrity)" || row note "token" "not elevated"
row note "job" "$("$cfprobe" job 2>&1 | tr -d '\r' | tr '\n' ' ')"

APP=test.cfprobe.app
first=1
for base in "$@"; do
    drive=${base:0:2}
    echo "== $base"
    row note "$drive" "$(powershell -NoProfile -Command "\$v = Get-Volume -DriveLetter ${drive:0:1}; \"\$(\$v.FileSystem), label '\$(\$v.FileSystemLabel)', \$(\$v.DriveType)\"" 2>&1 | tr -d '\r')"
    rm -rf "$(u "$base")"; mkdir -p "$(u "$base")"
    a="$base\\a"
    fixture="$base\\fixture"
    logs="$base\\logs"
    mkdir -p "$(u "$fixture")/sub/dir" "$(u "$logs")"

    # The fixture, from BusyBox's published image.
    if ! ZIGSAW_HOME="$a" "$zigsaw" pull --yes net.frippery.busybox >"$(u "$logs")/pull.txt" 2>&1; then
        row FAIL "$drive: pulling BusyBox from ghcr.io" "$(tail -1 "$(u "$logs")/pull.txt")"; continue
    fi
    bb=$(find "$(u "$a")/deploy" -name busybox.exe | head -1)
    cp "$bb" "$(u "$fixture")/busybox.exe" && cp "$bb" "$(u "$fixture")/sub/dir/busybox2.exe"
    "$(u "$fixture")/busybox.exe" seq 1 2000000 >"$(u "$fixture")/big.txt"
    hash=$("$(u "$fixture")/busybox.exe" sha256sum "$fixture\\big.txt" | cut -d' ' -f1)
    printf '{ "id": "%s", "version": "1", "command": "busybox.exe", "exports": {}, "layer": "estargz",\n  "modules": [{ "name": "files", "sources": [{ "path": ".", "skip": ["/app.json"] }] }] }\n' $APP >"$(u "$fixture")/app.json"
    if ! ZIGSAW_HOME="$a" "$zigsaw" build "$fixture\\app.json" >"$(u "$logs")/build.txt" 2>&1; then
        row FAIL "$drive: building the fixture" "$(tail -1 "$(u "$logs")/build.txt")"; continue
    fi
    manifest=$(grep -o 'sha256:[0-9a-f]*' "$(u "$a")/refs/$APP.json" | head -1 | cut -d: -f2)
    hex=$(tr -d ' \r\n' <"$(u "$a")/blobs/sha256/$manifest" | grep -o '"digest":"sha256:[0-9a-f]\{64\}"' | tail -1 | grep -o '[0-9a-f]\{64\}')
    blob="$a\\blobs\\sha256\\$hex"
    grep -q 'stargz/toc.digest' "$(u "$a")/blobs/sha256/$manifest" || { row FAIL "$drive: the fixture's layer isn't eStargz"; continue; }

    # A store with the app's ref and blobs and no deployment, where the mount goes.
    fresh() { # <name>: prints the store's path
        local s="$base\\$1"
        rm -rf "$(u "$s")"; mkdir -p "$(u "$s")"
        cp -r "$(u "$a")/refs" "$(u "$a")/blobs" "$(u "$s")/"
        echo "$s"
    }
    done_with() { # <store>
        ZIGSAW_HOME="$1" "$zigsaw" rm $APP >/dev/null 2>&1
        "$cfprobe" unregister "$1\\deploy\\$hex" >/dev/null 2>&1
        cmd /c rd /s /q "$1" >/dev/null 2>&1
    }

    for sb in soft low appcontainer; do
        s=$(fresh "run-$sb")
        root="$s\\deploy\\$hex"
        out=$(ZIGSAW_HOME="$s" "$cfprobe" mount "$root" "$blob" --log "$logs\\$sb.log" -- \
            "$zigsaw" run --sandbox=$sb $APP sha256sum "$root\\big.txt" 2>&1 | tr -d '\r')
        echo "$out" >"$(u "$logs")/$sb.txt"
        stats=$(grep '^cfprobe: [0-9]* fetches' <<<"$out" | sed 's/^cfprobe: //')
        if grep -q "^$hash " <<<"$out"; then
            row ok "$drive, $sb: BusyBox started from a placeholder read the text file" "$stats"
        else
            row FAIL "$drive, $sb: run from placeholders" "$(grep -m1 -E 'failed: |error: [A-Z]' <<<"$out" || tail -1 <<<"$out")"
        fi
        [ "$sb" = appcontainer ] && grep -q 'cfprobe:   busybox.exe' <<<"$out" &&
            row note "$drive, $sb: the provider saw the confined busybox.exe fetch" "$(grep 'cfprobe:   busybox.exe' <<<"$out" | head -1 | sed 's/^cfprobe: *//')"
        done_with "$s"
    done

    if [ $first = 1 ]; then
        # No provider: the placeholders made, then the provider gone.
        s=$(fresh none)
        root="$s\\deploy\\$hex"
        made=$("$cfprobe" mount "$root" "$blob" --placeholders-only 2>&1 | tr -d '\r' | grep -o '[0-9]* placeholders' | head -1)
        read_out=$("$cfprobe" read "$root\\big.txt" 2>&1 | tr -d '\r' | tr '\n' ' ')
        run_out=$(ZIGSAW_HOME="$s" "$zigsaw" run --sandbox=soft $APP true 2>&1 | tr -d '\r' | tail -2 | tr '\n' ' '); run_rc=$?
        row note "no provider: $made, then reading the text file" "$read_out"
        row note "no provider: starting BusyBox through zigsaw run" "${run_out:-(nothing printed)}"
        done_with "$s"

        # Qt's runtime by URL, from ghcr.io's storage, with blocks of 1 MiB.
        version=$(grep -m1 '"version"' "$(u "$repo")/recipes/qt6.json" | cut -d'"' -f4)
        tok=$(curl -s "https://ghcr.io/token?scope=repository:zigsaw-io/io.qt.qt6:pull" | sed -E 's/.*"token":"([^"]+)".*/\1/')
        layer=$(curl -s -H "Authorization: Bearer $tok" -H "Accept: application/vnd.oci.image.manifest.v1+json" \
            "https://ghcr.io/v2/zigsaw-io/io.qt.qt6/manifests/$version" | tr -d ' \r\n' | grep -o '"digest":"sha256:[0-9a-f]\{64\}","size":[0-9]*' | tail -1)
        ldigest=$(cut -d'"' -f4 <<<"$layer"); lsize=${layer##*:}
        url=$(curl -s -o NUL -w '%{redirect_url}' -H "Authorization: Bearer $tok" "https://ghcr.io/v2/zigsaw-io/io.qt.qt6/blobs/$ldigest")
        if [ -n "$url" ] && [ -n "$lsize" ]; then
            root="$base\\qt"
            out=$("$cfprobe" mount "$root" "$url" --size "$lsize" --block-kib 1024 -- "$cfprobe" read "$root\\bin\\Qt6Core.dll" 2>&1 | tr -d '\r')
            echo "$out" >"$(u "$logs")/url.txt"
            if grep -q 'exit 0' <<<"$out" && ! grep -qi 'failed' <<<"$(grep -v '^cfprobe:' <<<"$out")"; then
                row ok "by URL: Qt6Core.dll of Qt $version's runtime read from ghcr.io's storage" "$(grep -E '^cfprobe: (toc|[0-9]+ fetches)' <<<"$out" | sed 's/^cfprobe: //' | tr '\n' ' ')"
            else
                row FAIL "by URL: Qt6Core.dll" "$(grep -m1 -E 'failed: |error: [A-Z]|error [0-9]' <<<"$out" || tail -1 <<<"$out")"
            fi
            "$cfprobe" unregister "$root" >/dev/null 2>&1; cmd /c rd /s /q "$root" >/dev/null 2>&1
        else
            row FAIL "by URL: no storage URL for Qt's runtime layer" "layer '$layer'"
        fi

        # As a standard user: the provider and BusyBox in that account's logon.
        if [ -n "${CFPROBE_ACCOUNT:-}" ]; then
            asuser="$repo\\zig-out\\test\\zigsaw-asuser.exe"
            user=$(head -1 "$CFPROBE_ACCOUNT" | tr -d '\r')
            stage="$base\\stage"
            mkdir -p "$(u "$stage")"
            cp "$(u "$cfprobe")" "$(u "$stage")/cfprobe.exe"; cp "$(u "$blob")" "$(u "$stage")/blob"
            icacls "$stage" /grant "$user:(OI)(CI)M" >/dev/null
            "$(u "$asuser")" "$(w "$CFPROBE_ACCOUNT")" "$stage\\out.txt" \
                "\"$stage\\cfprobe.exe\" mount \"$stage\\root\" \"$stage\\blob\" -- \"$stage\\root\\busybox.exe\" sha256sum \"$stage\\root\\big.txt\""
            out=$(tr -d '\r' <"$(u "$stage")/out.txt" 2>/dev/null)
            if grep -q "^$hash " <<<"$out"; then row ok "as the standard user $user: BusyBox from a placeholder read the text file"
            else row FAIL "as the standard user $user" "$(tail -3 <<<"$out" | tr '\n' ' ')"; fi
            "$cfprobe" unregister "$stage\\root" >/dev/null 2>&1
        fi
        first=0
    fi
    ZIGSAW_HOME="$a" "$zigsaw" rm $APP >/dev/null 2>&1
    ZIGSAW_HOME="$a" "$zigsaw" rm net.frippery.busybox >/dev/null 2>&1
done

echo "$failed row(s) failed"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { echo "## Cloud Files on this runner"; echo; echo "| | row | detail |"; echo "|---|---|---|"
      printf '%s\n' "${rows[@]}"; echo; echo "$failed row(s) failed"; } >>"$GITHUB_STEP_SUMMARY"
fi
[ $failed -eq 0 ]
