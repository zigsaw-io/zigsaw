#!/usr/bin/env bash
# End-to-end checks for lazy pulling (src/lazy.zig): `pull --lazy` installs an
# app with its eStargz layer as Cloud Files placeholders, which a helper serves
# from the registry as they're read, under every sandbox, a file's chunks in a
# few requests; the helper hydrates the recipe's prefetch files before any run;
# it comes back when it's gone, going on from what the last one fetched, says
# what it couldn't fetch, and swaps the unpacked layer in once the download,
# which fetches nothing runs did, is done and no run uses it; `rm` takes it all
# away; and a volume that can't have placeholders, or a test hook acting as
# one, gets a whole download. Store a builds a small app (BusyBox, a 16 MiB
# file and three small ones, one of them prefetched) and pushes it; the others
# pull it.
#
#   tests/zot.sh bash tests/lazy.sh [path\to\zigsaw.exe]
#
# Needs a registry on localhost:5000, and a work directory on a volume that can
# have placeholders (NTFS, not a Dev Drive): LAZY_WORK, or a temporary one. With
# LAZY_DEV_DRIVE, a directory on a Dev Drive, one row checks the real refusal.
# SEED_DOWNLOADS: another store's cache\downloads with BusyBox's download, as
# frippery.org refuses everyone. Builds zig-out\test\zigsaw-jobprobe.exe. Takes
# about a minute.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root\\zig-out\\bin\\zigsaw.exe}
(cd "$(cygpath -u "$root")" && zig build jobprobe) || { echo "building the job probe failed"; exit 1; }
jobprobe="$root\\zig-out\\test\\zigsaw-jobprobe.exe"
if [ -n "${LAZY_WORK:-}" ]; then
    work="$LAZY_WORK\\lazy-$$"
    mkdir -p "$(cygpath -u "$work")"
else
    work=$(cygpath -wl "$(mktemp -d)")
fi
mkdir -p "$work\\cwd" && cd "$work\\cwd" || exit 1

export ZIGSAW_TASK_NAME="ZigsawTest-lazy-$$"
export ZIGSAW_GRANTS_KEY="Software\\ZigsawTest\\lazy-$$"
export ZIGSAW_SHORTCUTS_DIR="$work\\links"
export ZIGSAW_USER_FOLDERS="$work\\folders"
mkdir -p "$ZIGSAW_USER_FOLDERS"
# The fixture's layer is small: lazy all the same.
export ZIGSAW_TEST_LAZY_MIN=1

registry=localhost:5000
curl -sf "http://127.0.0.1:5000/v2/" >/dev/null || { echo "no registry on $registry: run this under tests/zot.sh"; exit 1; }

APP=test.lazy.app
repo="$registry/zigsaw-lazy-$RANDOM"
gate="$work\\gate"
store() { echo "$work\\$1"; }
za() { ZIGSAW_HOME="$(store a)" "$zigsaw" "$@"; }
# Stores b to d hold the download back while the gate file is there.
zb() { ZIGSAW_HOME="$(store b)" ZIGSAW_TEST_LAZY_GATE="$gate" "$zigsaw" "$@"; }
zc() { ZIGSAW_HOME="$(store c)" ZIGSAW_TEST_LAZY_GATE="$gate" "$zigsaw" "$@"; }
zd() { ZIGSAW_HOME="$(store d)" ZIGSAW_TEST_LAZY_GATE="$gate" "$zigsaw" "$@"; }
ze() { ZIGSAW_HOME="$(store e)" ZIGSAW_TEST_LAZY_REFUSE=1 "$zigsaw" "$@"; }

cleanup() {
    # rm stops a lazy layer's helper; one whose app is gone already, by its pid.
    for s in b c d e a; do
        ZIGSAW_HOME="$(store $s)" "$zigsaw" rm $APP >/dev/null 2>&1
        p=$(helper_pid $s) && [ -n "$p" ] && taskkill /F /PID "$p" >/dev/null 2>&1
    done
    reg delete "HKCU\\$ZIGSAW_GRANTS_KEY" /f >/dev/null 2>&1
    cd / && rm -rf "$(cygpath -u "$work")" 2>/dev/null
}
trap cleanup EXIT

if [ -n "${SEED_DOWNLOADS:-}" ]; then
    mkdir -p "$(store a)\\cache\\downloads"
    cp -l "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$(store a)")/cache/downloads/" 2>/dev/null ||
        cp -n "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$(store a)")/cache/downloads/"
fi

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
fails() { ! "$@"; }

# The attributes Windows has for a file, without opening it (which would fetch it).
attributes() { powershell -NoProfile -Command "[int][System.IO.File]::GetAttributes('$1')" 2>/dev/null | tr -d '\r'; }
recall_on_access() { local a; a=$(attributes "$1") && [ -n "$a" ] && (( a & 0x400000 )); }
plain_file() { local a; a=$(attributes "$1") && [ -n "$a" ] && (( (a & 0x400000) == 0 && (a & 0x400) == 0 )); }

# --- The fixture -------------------------------------------------------------
fixture="$work\\fixture"
mkdir -p "$(cygpath -u "$fixture")"
head -c 16777216 /dev/urandom >"$(cygpath -u "$fixture")/big.bin"
printf 'hello lazy\n' >"$(cygpath -u "$fixture")/small.txt"
printf 'never read but once\n' >"$(cygpath -u "$fixture")/never.txt"
printf 'what a first run reads\n' >"$(cygpath -u "$fixture")/first.txt"
printf '{ "id": "%s", "version": "1", "command": "busybox.exe", "exports": {}, "layer": "estargz", "prefetch": ["first.txt"],\n  "permissions": { "sandbox": "soft" },\n  "modules": [{ "name": "files", "sources": [\n    { "url": "https://frippery.org/files/busybox/busybox-w64-FRP-6075-g169694ebd.exe", "sha256": "07bb1e5b095b00d68a695481f9240879f33c5724b40aa2308f999d54ed78f075", "dest": "busybox.exe" },\n    { "path": "big.bin" }, { "path": "small.txt" }, { "path": "never.txt" }, { "path": "first.txt" } ] }] }\n' $APP >"$(cygpath -u "$fixture")/app.json"
za build "$fixture\\app.json" >"$work\\build.txt" 2>&1 || { echo "building the fixture failed:"; tail -3 "$work\\build.txt"; exit 1; }
za push $APP "$repo:1" >/dev/null 2>&1 || { echo "pushing the fixture failed"; exit 1; }
manifest=$(grep -o 'sha256:[0-9a-f]*' "$(store a)\\refs\\$APP.json" | head -1 | cut -d: -f2)
hex=$(tr -d ' \r\n' <"$(store a)\\blobs\\sha256\\$manifest" | grep -o '"digest":"sha256:[0-9a-f]\{64\}"' | tail -1 | grep -o '[0-9a-f]\{64\}')
deploy_of() { echo "$(store "$1")\\deploy\\$hex"; }
lazy_of() { echo "$(store "$1")\\lazy\\$hex"; }
helper_pid() { tr -d '\r\n ' 2>/dev/null <"$(lazy_of "$1")\\state.json" | grep -o '"pid":[0-9]*' | cut -d: -f2; }
helper_running() { local p; p=$(helper_pid "$1") && [ -n "$p" ] && [ "$p" != 0 ] && tasklist /fi "PID eq $p" /nh 2>/dev/null | grep -q " $p "; }
helper_gone() { ! helper_running "$1"; }
# The recipe's prefetch: first.txt first, then the landmark, then the rest.
prioritized_first() {
    local names
    names=$(gzip -dc <"$(store a)\\blobs\\sha256\\$hex" 2>/dev/null | tar -t 2>/dev/null | head -2 | tr '\n' ' ')
    [ "$names" = "first.txt .prefetch.landmark " ] || { echo "the blob starts: $names"; return 1; }
}
check "a recipe's prefetch puts its files first in the layer, then the prefetch landmark" prioritized_first

# --- Pulled lazily -----------------------------------------------------------
touch "$(cygpath -u "$gate")"
pull_out=$(zb pull --yes --lazy "$repo:1" 2>&1)
if grep -q "can't have Cloud Files placeholders" <<<"$pull_out"; then
    echo "note  this work directory's volume can't have placeholders ($work): set LAZY_WORK to one on NTFS"
    exit 1
fi
pulled_lazily() {
    grep -q '  lazy     layer' <<<"$pull_out" || { echo "$pull_out" | tail -3; return 1; }
    [ ! -e "$(store b)\\blobs\\sha256\\$hex" ] && [ -d "$(deploy_of b)" ] && recall_on_access "$(deploy_of b)\\small.txt"
}
check "pull --lazy installs the app with its layer as placeholders, and no blob" pulled_lazily
check "list says it's downloading" bash -c "ZIGSAW_HOME='$(store b)' '$zigsaw' list 2>&1 | grep '^$APP ' | grep -q '(downloading'"
# While the download waits on the gate, before any run.
hydrated_ahead() {
    local i
    for i in $(seq 1 40); do grep -q 'hydrated first.txt' "$(lazy_of b)\\log" 2>/dev/null && break; sleep 0.25; done
    grep -q 'hydrated first.txt' "$(lazy_of b)\\log" || { echo "the log says nothing of first.txt"; return 1; }
    local a; a=$(attributes "$(deploy_of b)\\first.txt")
    [ -n "$a" ] && (( (a & 0x400000) == 0 )) || { echo "first.txt's attributes: $a"; return 1; }
    recall_on_access "$(deploy_of b)\\never.txt" || { echo "never.txt isn't a placeholder"; return 1; }
}
check "the helper hydrates the prioritized files ahead of use, and only those" hydrated_ahead
for sb in soft low appcontainer; do
    check "under $sb, BusyBox starts from a placeholder and reads one" \
        bash -c "[ \"\$(ZIGSAW_HOME='$(store b)' ZIGSAW_TEST_LAZY_GATE='$gate' '$zigsaw' run --sandbox=$sb $APP cat '$(deploy_of b)\\small.txt' 2>&1 | tr -d '\r')\" = 'hello lazy' ]"
done
# What starts a program reads its image, so zigsaw fetched busybox.exe; the
# program, the file it read.
check "the helper's log names what fetched each file" grep -q 'fetched small.txt: [0-9]* bytes, for busybox.exe' "$(lazy_of b)\\log"
check "a file nothing read is still a placeholder" recall_on_access "$(deploy_of b)\\never.txt"
breakaway() { local out; out=$(zb run --sandbox=soft $APP sh -c "'$(cygpath -m "$jobprobe")' breakaway" 2>&1); grep -q refused <<<"$out" || { echo "$out"; return 1; }; }
check "a program the app starts can't leave the app's job" breakaway

pid1=$(helper_pid b)
taskkill /F /PID "$pid1" >/dev/null 2>&1
# Stdout only: in a job that refuses breakaway (CI's), the restart says so on stderr.
restarted() {
    local n
    n=$(zb run $APP wc -c "$(deploy_of b)\\big.bin" 2>/dev/null | tr -d '\r' | awk '{ print $1 }')
    [ "$n" = 16777216 ] || { echo "wc said '$n'"; return 1; }
    helper_running b && [ "$(helper_pid b)" != "$pid1" ] || { echo "no new helper (pid $(helper_pid b), was $pid1)"; return 1; }
}
check "a killed helper is started again by the next run, which reads 16 MiB through it" restarted
# Its four chunks, asked for at once: a request each, not one per MiB.
few_requests() {
    local i r=
    for i in $(seq 1 12); do
        r=$(tr -d '\r\n ' <"$(lazy_of b)\\state.json" 2>/dev/null | grep -o '"requests":[0-9]*' | cut -d: -f2)
        [ -n "$r" ] && [ "$r" -gt 0 ] && break
        sleep 0.25
    done
    [ -n "$r" ] && [ "$r" -ge 1 ] && [ "$r" -le 8 ] || { echo "$r requests"; return 1; }
}
check "and those 16 MiB came in a few requests" few_requests

taskkill /F /PID "$(helper_pid b)" >/dev/null 2>&1
told_why() {
    local out
    out=$(ZIGSAW_HOME="$(store b)" ZIGSAW_TEST_LAZY_GATE="$gate" ZIGSAW_TEST_LAZY_FAIL=never.txt "$zigsaw" run $APP cat "$(deploy_of b)\\never.txt" 2>&1) && { echo "it exited 0"; return 1; }
    grep -q "couldn't be: never.txt" <<<"$out" || { echo "$out"; return 1; }
}
check "a fetch that fails makes the run say which file, and why" told_why
# The helper that test started has the hook: the next run gets one without.
taskkill /F /PID "$(helper_pid b)" >/dev/null 2>&1
push_refused() {
    local out
    out=$(zb push $APP "$repo-copy:1" 2>&1) && { echo "it pushed"; return 1; }
    grep -q 'still being downloaded' <<<"$out" || { echo "$out"; return 1; }
}
check "push refuses an app still being downloaded" push_refused

# --- The swap ----------------------------------------------------------------
zb run $APP sleep 6 >/dev/null 2>&1 &
running=$!
sleep 1
rm -f "$(cygpath -u "$gate")"
waits_for_run() {
    local i
    for i in $(seq 1 40); do
        grep -q '"phase": *"unpacking"' "$(lazy_of b)\\state.json" 2>/dev/null && break
        sleep 0.25
    done
    # The swap deletes it.
    cp "$(lazy_of b)\\log" "$work\\b.log" 2>/dev/null
    # Downloaded and unpacked, and the deployment still the placeholders.
    [ -d "$(lazy_of b)" ] && recall_on_access "$(deploy_of b)\\never.txt"
}
check "with the download done, the swap waits while a run uses the deployment" waits_for_run
wait "$running"
swapped() {
    local i
    for i in $(seq 1 80); do [ -d "$(lazy_of b)" ] || break; sleep 0.25; done
    [ ! -d "$(lazy_of b)" ] || { echo "lazy\\ still has the layer"; return 1; }
    plain_file "$(deploy_of b)\\never.txt" || { echo "never.txt isn't a plain file"; return 1; }
    [ "$(sha256sum <"$(store b)\\blobs\\sha256\\$hex" | cut -d' ' -f1)" = "$hex" ] || { echo "the blob isn't the layer"; return 1; }
}
check "after it, the deployment is plain files, and the blob is the layer's" swapped
# The helpers that were killed left what they fetched, big.bin among it,
# and the one that finished fetched none of that again.
skipped_had() {
    local line by earlier size
    line=$(grep 'downloaded and checked the whole blob' "$work\\b.log" | tail -1)
    by=$(sed -n 's/.*blob: \([0-9]*\) bytes by the download.*/\1/p' <<<"$line")
    earlier=$(sed -n 's/.*for reads, \([0-9]*\) an earlier helper got.*/\1/p' <<<"$line")
    size=$(stat -c %s "$(store b)\\blobs\\sha256\\$hex")
    [ -n "$by" ] && [ -n "$earlier" ] || { echo "the log says: ${line:-nothing of it}"; return 1; }
    [ "$earlier" -ge 16777216 ] && [ "$by" -lt $((size - 16777216)) ] || { echo "$line (blob $size)"; return 1; }
}
check "the download went on from what killed helpers fetched, and fetched none of it again" skipped_had
check "the helper is gone" helper_gone b
check "and the app reads the file nothing fetched" bash -c "[ \"\$(ZIGSAW_HOME='$(store b)' '$zigsaw' run $APP cat '$(deploy_of b)\\never.txt' 2>&1 | tr -d '\r')\" = 'never read but once' ]"
check "list says nothing of it any more" bash -c "! ZIGSAW_HOME='$(store b)' '$zigsaw' list 2>&1 | grep '^$APP ' | grep -q '(downloading\|(paused'"

# --- rm, and a job that keeps what it starts ---------------------------------
touch "$(cygpath -u "$gate")"
zc pull --yes --lazy "$repo:1" >/dev/null 2>&1
removed() {
    local pid; pid=$(helper_pid c)
    zc rm $APP >/dev/null 2>&1 || return 1
    [ ! -e "$(deploy_of c)" ] && [ ! -e "$(lazy_of c)" ] || { echo "something is left"; return 1; }
    [ -z "$pid" ] || [ "$pid" = 0 ] || ! tasklist /fi "PID eq $pid" /nh 2>/dev/null | grep -q " $pid "
}
check "rm while it's lazy stops the helper, and leaves no placeholders or download" removed

# As separate arguments: injob takes its command line as it comes, and Git
# Bash would escape quotes in one. (No spaces in these paths.)
injob_out=$(ZIGSAW_HOME="$(store d)" ZIGSAW_TEST_LAZY_GATE="$gate" "$jobprobe" injob "$zigsaw" pull --yes --lazy "$repo:1" 2>&1)
check "pull --lazy in a job that keeps what it starts says the download lasts as long as it" grep -q "in a job that keeps what it starts" <<<"$injob_out"
check "the job's end ended the helper" helper_gone d
# Stdout only, as above: outside that job may still be inside another.
restarted_outside() {
    local out
    out=$(zd run $APP cat "$(deploy_of d)\\small.txt" 2>/dev/null | tr -d '\r')
    [ "$out" = 'hello lazy' ] || { echo "cat said '$out'"; return 1; }
}
check "the next run, outside it, starts the helper again" restarted_outside
# As a pull that stopped would leave it: placeholders, a helper, and no ref.
rm -f "$(store d)\\refs\\$APP.json"
pruned() {
    local pid; pid=$(helper_pid d)
    zd prune >/dev/null 2>&1 || return 1
    [ ! -e "$(deploy_of d)" ] || { echo "the placeholders are still there"; return 1; }
    [ ! -e "$(lazy_of d)" ] || { echo "lazy\\ still has the layer"; return 1; }
    [ -z "$pid" ] || [ "$pid" = 0 ] || ! tasklist /fi "PID eq $pid" /nh 2>/dev/null | grep -q " $pid "
}
check "prune deletes placeholders no installed app uses, and stops their helper" pruned

# --- Where placeholders can't be ---------------------------------------------
fell_back() {
    local out
    out=$(ze pull --yes --lazy "$repo:1" 2>&1) || { echo "$out" | tail -2; return 1; }
    grep -q "downloaded whole" <<<"$out" || { echo "$out"; return 1; }
    [ -e "$(store e)\\blobs\\sha256\\$hex" ] && [ ! -e "$(lazy_of e)" ] && plain_file "$(deploy_of e)\\never.txt"
}
check "where the volume can't have placeholders, pull --lazy downloads the layer whole" fell_back
if [ -n "${LAZY_DEV_DRIVE:-}" ]; then
    dev="$LAZY_DEV_DRIVE\\lazy-$$"
    dev_out=$(ZIGSAW_HOME="$dev" "$zigsaw" pull --yes --lazy "$repo:1" 2>&1)
    check "on a real Dev Drive too" grep -q "can't have Cloud Files placeholders.*downloaded whole" <<<"$dev_out"
    ZIGSAW_HOME="$dev" "$zigsaw" rm $APP >/dev/null 2>&1
    rm -rf "$(cygpath -u "$dev")"
fi

echo "$failures check(s) failed"
[ "$failures" -eq 0 ]
