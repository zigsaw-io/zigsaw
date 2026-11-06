#!/usr/bin/env bash
# Records what a first run of an app reads, as the "prefetch" list of each
# eStargz image it's made of: pulls it lazily into a store of its own, runs it
# once, and lists the files each layer's helper fetched for the run, in the
# order they were first asked for.
#
#   scripts/record-prefetch.sh <ref> [--command=<name>] [-- <args>...]
#   scripts/record-prefetch.sh <ref> --window=<title> [--command=<name>]
#
# The first runs the app (or one of its commands) with the arguments and waits
# for it to end; the second starts it, waits for a window with that title, and
# closes it (zig-out/test/zigsaw-winwait.exe, `zig build winwait`). A run in
# the current directory may need the app's permission for it.
#
# Prints, for each layer that was fetched from, its image's id and a
# "prefetch" block to paste into that image's recipe, with how many files and
# bytes it is. What the helper fetched for zigsaw itself (a program's header,
# its image as Windows starts it) and for Defender stays in: a real first run
# pays for those too.
#
# The store goes in RECORD_WORK (a directory on NTFS, not a Dev Drive: lazy
# pulls need Cloud Files), or a temporary one, and is removed at the end, as
# are the shortcuts and registry keys it made. ZIGSAW is the zigsaw to use,
# zig-out/bin/zigsaw.exe by default. Every eStargz layer is pulled lazily,
# small ones too, its download held back, and an image that already has a
# list has it ignored, so that what the run reads is what it fetches.

set -u
export MSYS_NO_PATHCONV=1

root=$(cd "$(dirname "$0")/.." && pwd)
zigsaw=${ZIGSAW:-$(cygpath -w "$root/zig-out/bin/zigsaw.exe")}
winwait=$(cygpath -w "$root/zig-out/test/zigsaw-winwait.exe")

ref=
command=
window=
args=()
while [ $# -gt 0 ]; do
    case $1 in
    --command=*) command=${1#--command=} ;;
    --window=*) window=${1#--window=} ;;
    --) shift; args=("$@"); break ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) [ -z "$ref" ] && ref=$1 || { echo "one reference only" >&2; exit 2; } ;;
    esac
    shift
done
[ -n "$ref" ] || { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
if [ -n "$window" ] && [ ! -x "$(cygpath -u "$winwait")" ]; then
    echo "--window needs $winwait: zig build winwait" >&2
    exit 2
fi

if [ -n "${RECORD_WORK:-}" ]; then
    work="$RECORD_WORK\\record-$$"
    mkdir -p "$(cygpath -u "$work")"
else
    work=$(cygpath -wl "$(mktemp -d)")
fi
store="$work\\store"
gate="$work\\gate"
touch "$(cygpath -u "$gate")"
mkdir -p "$(cygpath -u "$work\\folders")"
export ZIGSAW_HOME="$store"
export ZIGSAW_TEST_LAZY_MIN=1 ZIGSAW_TEST_LAZY_GATE="$gate" ZIGSAW_TEST_LAZY_NO_HYDRATE=1
export ZIGSAW_TASK_NAME="ZigsawRecord-$$" ZIGSAW_GRANTS_KEY="Software\\ZigsawRecord\\$$"
export ZIGSAW_SHORTCUTS_DIR="$work\\links" ZIGSAW_USER_FOLDERS="$work\\folders"

app=
cleanup() {
    [ -n "$app" ] && "$zigsaw" rm --delete-data "$app" >/dev/null 2>&1
    rm -f "$(cygpath -u "$gate")"
    "$zigsaw" prune >/dev/null 2>&1
    reg delete "HKCU\\Software\\ZigsawRecord\\$$" /f >/dev/null 2>&1
    rm -rf "$(cygpath -u "$work")" 2>/dev/null
}
trap cleanup EXIT

"$zigsaw" pull --yes --lazy "$ref" >"$work\\pull.txt" 2>&1 || { echo "pulling $ref failed:"; tail -3 "$work\\pull.txt"; exit 1; }
app=$(grep -o '^installed [^ ]*' "$work\\pull.txt" | head -1 | cut -d' ' -f2)
[ -n "$app" ] || { echo "the pull didn't say what it installed:"; tail -3 "$work\\pull.txt"; exit 1; }
lazy="$store\\lazy"
ls "$(cygpath -u "$lazy")" 2>/dev/null | grep -qE '^[0-9a-f]{64}$' || { echo "$ref has no eStargz layer to record for"; exit 1; }

run=("$zigsaw" run)
[ -n "$command" ] && run+=("--command=$command")
if [ -n "$window" ]; then
    "${run[@]}" "$app" >"$work\\run.txt" 2>&1 &
    runner=$!
    winpid=$(cat "/proc/$runner/winpid")
    if ! "$winwait" "$winpid" "$window" 180 >/dev/null 2>&1; then
        echo "no window titled \"$window\" in 3 minutes" >&2
        taskkill /PID "$winpid" /T /F >/dev/null 2>&1
        exit 1
    fi
    "$winwait" "$winpid" "$window" 20 --close >/dev/null 2>&1
    kill -0 "$runner" 2>/dev/null && taskkill /PID "$winpid" /T /F >/dev/null 2>&1
    wait "$runner" 2>/dev/null
else
    "${run[@]}" "$app" "${args[@]}" >"$work\\run.txt" 2>&1 || echo "note: the run exited $? ($(tail -1 "$work\\run.txt" | tr -d '\r'))" >&2
fi

# Which image each layer is: the app's own, or a runtime its config names.
manifest=$(grep -o '"manifest": *"sha256:[0-9a-f]*"' "$store\\refs\\$app.json" | grep -o '[0-9a-f]\{64\}')
config_hex=$(tr -d '\r\n ' <"$store\\blobs\\sha256\\$manifest" | grep -o '"config":{[^}]*}' | grep -o '[0-9a-f]\{64\}')
config=$(tr -d '\r\n' <"$store\\blobs\\sha256\\$config_hex" | sed 's/ *: */:/g; s/, */,/g')
own=$(tr -d '\r\n ' <"$store\\blobs\\sha256\\$manifest" | grep -o '"digest":"sha256:[0-9a-f]\{64\}"' | tail -1 | grep -o '[0-9a-f]\{64\}')
image_of() {
    if [ "$1" = "$own" ]; then echo "$app"; return; fi
    local id
    id=$(grep -o '"id":"[^"]*","version":"[^"]*","image":"[^"]*","layer":"sha256:'"$1"'"' <<<"$config" | head -1 | cut -d'"' -f4)
    echo "${id:-layer ${1:0:12}}"
}

found=0
for dir in "$(cygpath -u "$lazy")"/*/; do
    hex=$(basename "$dir")
    [[ $hex =~ ^[0-9a-f]{64}$ ]] || continue
    # First-seen order, each file once: Windows may ask for a file in pieces.
    list=$(sed -n 's/^fetched \(.*\): \([0-9]*\) bytes, for .*/\2 \1/p' "$dir/log" | tr -d '\r' | awk '!seen[$2]++ { print; total += $1; n++ } END { printf "%d %d\n", n, total > "/dev/stderr" }' 2>"$work\\count.txt")
    read -r n bytes <"$work\\count.txt"
    [ "${n:-0}" -gt 0 ] || continue
    found=1
    echo "$(image_of "$hex"): $n files, $(awk -v b="$bytes" 'BEGIN { printf "%.1f MB", b / 1e6 }')"
    echo '  "prefetch": ['
    sed 's/^[0-9]* //; s/\\/\\\\/g; s/"/\\"/g; s/.*/    "&",/' <<<"$list" | sed '$ s/,$//'
    echo '  ],'
done
[ "$found" = 1 ] || { echo "the run fetched nothing from $ref's lazy layers"; exit 1; }
