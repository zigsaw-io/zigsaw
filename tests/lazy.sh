#!/usr/bin/env bash
# End-to-end checks for lazy pulling (src/lazy.zig): `pull --lazy` installs an
# app with its eStargz layer as Cloud Files placeholders, which a helper serves
# from the registry as they're read, under every sandbox, a file's chunks in a
# few requests; the helper hydrates the recipe's prefetch files before any run;
# it comes back when it's gone, going on from what the last one fetched, says
# what it couldn't fetch, and swaps the unpacked layer in once the download,
# which fetches nothing runs did, is done and no run uses it; `rm` takes it all
# away; and a volume that can't have placeholders, or a test hook acting as
# one, gets a whole download. `update --lazy` copies what the version before
# has (stores f to h), and a slow fetch tells Windows how far it's got (i).
# What runs read of a lazy layer is written down for its image, and asked for
# ahead of any run when its next version is pulled lazily (j).
# Store a builds a small app (BusyBox, a 16 MiB file and three small ones, one
# of them prefetched) and pushes it, then its version 2; the others pull them.
#
#   tests/zot.sh bash tests/lazy.sh [path\to\zigsaw.exe]
#
# Needs a registry on localhost:5000, and a work directory on a volume that can
# have placeholders (NTFS, not a Dev Drive): LAZY_WORK, or a temporary one. With
# LAZY_DEV_DRIVE, a directory on a Dev Drive, one row checks the real refusal.
# LAZY_SLOW: the bytes a second of the slow link row (1 MiB); LAZY_WAIT=90000
# makes its fetches outlast Windows' 60 s. SEED_DOWNLOADS: another store's cache\downloads
# with BusyBox's download, as frippery.org refuses everyone. Builds
# zig-out\test\zigsaw-jobprobe.exe. Takes about a minute.

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
    for s in b c d e f g h i j a; do
        ZIGSAW_HOME="$(store $s)" "$zigsaw" rm $APP >/dev/null 2>&1
        p=$(helper_pid $s) && [ -n "$p" ] && taskkill /F /PID "$p" >/dev/null 2>&1
        [ -n "${hex2:-}" ] && p=$(helper2_pid $s) && [ -n "$p" ] && taskkill /F /PID "$p" >/dev/null 2>&1
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
# The helper writes a file down once it has served it, which the run doesn't
# wait for.
learned_of() { echo "$(store "$1")\\learned\\$APP.txt"; }
written_down() {
    local i
    for i in $(seq 1 20); do grep -qxF "$hex small.txt" "$(learned_of b)" 2>/dev/null && break; sleep 0.25; done
    grep -qxF "$hex small.txt" "$(learned_of b)" || { echo "small.txt isn't in it"; return 1; }
    grep -qxF "$hex busybox.exe" "$(learned_of b)" || { echo "busybox.exe isn't in it"; return 1; }
    # Not what the helper hydrated itself, nor what nothing read.
    ! grep -q 'first.txt\|never.txt' "$(learned_of b)" || { echo "it has: $(tr '\n' ' ' <"$(learned_of b)")"; return 1; }
    [ "$(wc -l <"$(learned_of b)")" = 2 ] || { echo "it has $(wc -l <"$(learned_of b)") lines"; return 1; }
}
check "what runs read of the lazy layer is written down for its image, each file once" written_down
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
        grep -q 'unpacking once no run uses the deployment' "$(lazy_of b)\\log" 2>/dev/null && break
        sleep 0.25
    done
    # The swap deletes it.
    cp "$(lazy_of b)\\log" "$work\\b.log" 2>/dev/null
    grep -q 'unpacking once no run uses the deployment' "$work\\b.log" || { echo "the log doesn't say it waits"; return 1; }
    # Downloaded, not unpacked, and the deployment still the placeholders.
    ! grep -q '"phase": *"unpacking"' "$(lazy_of b)\\state.json" || { echo "it's unpacking"; return 1; }
    [ -d "$(lazy_of b)" ] && recall_on_access "$(deploy_of b)\\never.txt"
}
check "with the download done, the unpack and the swap wait while a run uses the deployment" waits_for_run
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

# --- An update, copied from the version before -------------------------------
# Version 2 changes small.txt and adds 1 MiB; big.bin and BusyBox stay. Each
# store pulls version 1 whole, from a repository of its own, which then gets
# version 2.
zf() { ZIGSAW_HOME="$(store f)" ZIGSAW_TEST_LAZY_GATE="$gate" "$zigsaw" "$@"; }
zg() { ZIGSAW_HOME="$(store g)" ZIGSAW_TEST_LAZY_GATE="$gate" "$zigsaw" "$@"; }
zh() { ZIGSAW_HOME="$(store h)" ZIGSAW_TEST_LAZY_GATE="$gate" "$zigsaw" "$@"; }
for s in f g h; do
    za push $APP "$repo-$s:latest" >/dev/null 2>&1 || { echo "pushing version 1 failed"; exit 1; }
    ZIGSAW_HOME="$(store $s)" "$zigsaw" pull --yes "$repo-$s:latest" >/dev/null 2>&1 || { echo "pulling version 1 into $s failed"; exit 1; }
done
fixture2="$work\\fixture2"
cp -r "$(cygpath -u "$fixture")" "$(cygpath -u "$fixture2")"
printf 'hello lazy, version 2\n' >"$(cygpath -u "$fixture2")/small.txt"
head -c 1048576 /dev/urandom >"$(cygpath -u "$fixture2")/new.bin"
sed -i 's/"version": "1"/"version": "2"/; s/{ "path": "first.txt" } ]/{ "path": "first.txt" }, { "path": "new.bin" } ]/' "$(cygpath -u "$fixture2")/app.json"
za build "$fixture2\\app.json" >"$work\\build2.txt" 2>&1 || { echo "building version 2 failed:"; tail -3 "$work\\build2.txt"; exit 1; }
for s in f g h; do za push $APP "$repo-$s:latest" >/dev/null 2>&1 || { echo "pushing version 2 failed"; exit 1; }; done
manifest2=$(grep -o 'sha256:[0-9a-f]*' "$(store a)\\refs\\$APP.json" | head -1 | cut -d: -f2)
hex2=$(tr -d ' \r\n' <"$(store a)\\blobs\\sha256\\$manifest2" | grep -o '"digest":"sha256:[0-9a-f]\{64\}"' | tail -1 | grep -o '[0-9a-f]\{64\}')
deploy2_of() { echo "$(store "$1")\\deploy\\$hex2"; }
lazy2_of() { echo "$(store "$1")\\lazy\\$hex2"; }
helper2_pid() { tr -d '\r\n ' 2>/dev/null <"$(lazy2_of "$1")\\state.json" | grep -o '"pid":[0-9]*' | cut -d: -f2; }
state2() { tr -d '\r\n ' 2>/dev/null <"$(lazy2_of "$1")\\state.json" | grep -o "\"$2\":[0-9]*" | cut -d: -f2; }
# What the helper's log says it copied, once it says so.
copied_of() {
    local i
    for i in $(seq 1 40); do grep -q 'copied [0-9]* bytes from the store' "$(lazy2_of "$1")\\log" 2>/dev/null && break; sleep 0.25; done
    sed -n 's/.*copied \([0-9]*\) bytes from the store.*/\1/p' "$(lazy2_of "$1")\\log" 2>/dev/null | tail -1
}

touch "$(cygpath -u "$gate")"
update_out=$(zf update --yes --lazy $APP 2>&1)
copied_on_update() {
    grep -q 'copied from layers in the store' <<<"$update_out" || { echo "$update_out" | tail -3; return 1; }
    local n; n=$(copied_of f)
    [ -n "$n" ] && [ "$n" -ge 16777216 ] || { echo "the log says it copied '${n:-nothing}'"; return 1; }
}
check "update --lazy copies what the version before has, as its helper starts" copied_on_update
read_copied() {
    local n; n=$(zf run $APP wc -c "$(deploy2_of f)\\big.bin" 2>/dev/null | tr -d '\r' | awk '{ print $1 }')
    [ "$n" = 16777216 ] || { echo "wc said '$n'"; return 1; }
    local s; s=$(zf run $APP cat "$(deploy2_of f)\\small.txt" 2>/dev/null | tr -d '\r')
    [ "$s" = 'hello lazy, version 2' ] || { echo "small.txt says '$s'"; return 1; }
    # Only what changed came from the registry: small.txt's block or two.
    local d; d=$(state2 f on_demand)
    [ -n "$d" ] && [ "$d" -le 262144 ] || { echo "${d:-?} bytes fetched for reads"; return 1; }
}
check "and a run reads the copied files, fetching only what changed" read_copied
taskkill /F /PID "$(helper2_pid f)" >/dev/null 2>&1
copied_once() {
    zf run $APP cat "$(deploy2_of f)\\small.txt" >/dev/null 2>&1
    local i
    for i in $(seq 1 20); do grep -q 'going on with' "$(lazy2_of f)\\log" 2>/dev/null && break; sleep 0.25; done
    grep -q 'going on with' "$(lazy2_of f)\\log" || { echo "the new helper didn't go on from the map"; return 1; }
    sleep 1
    local n; n=$(grep -c 'copied [0-9]* bytes from the store' "$(lazy2_of f)\\log")
    [ "$n" = 1 ] || { echo "the log says it copied $n times"; return 1; }
}
check "a helper started again copies nothing twice" copied_once
rm -f "$(cygpath -u "$gate")"
update_swapped() {
    local i
    for i in $(seq 1 80); do
        grep -q 'downloaded and checked the whole blob' "$(lazy2_of f)\\log" 2>/dev/null && cp "$(lazy2_of f)\\log" "$work\\f.log" 2>/dev/null
        [ -d "$(lazy2_of f)" ] || break
        sleep 0.25
    done
    [ ! -d "$(lazy2_of f)" ] || { echo "lazy\\ still has the layer"; return 1; }
    [ "$(sha256sum <"$(store f)\\blobs\\sha256\\$hex2" | cut -d' ' -f1)" = "$hex2" ] || { echo "the blob isn't the layer"; return 1; }
    # The helper that finished has what the first one copied as "earlier".
    local line by reads earlier from
    line=$(grep 'downloaded and checked the whole blob' "$work\\f.log" | tail -1)
    by=$(sed -n 's/.*blob: \([0-9]*\) bytes by the download.*/\1/p' <<<"$line")
    reads=$(sed -n 's/.*download, \([0-9]*\) for reads.*/\1/p' <<<"$line")
    earlier=$(sed -n 's/.*for reads, \([0-9]*\) an earlier helper got.*/\1/p' <<<"$line")
    from=$(sed -n "s/.*; \([0-9]*\) bytes from the store's layers.*/\1/p" <<<"$line")
    [ -n "$by" ] && [ -n "$reads" ] && [ -n "$earlier" ] && [ -n "$from" ] || { echo "the log says: ${line:-nothing of it}"; return 1; }
    [ $((by + reads)) -lt 3145728 ] && [ $((earlier + from)) -ge 16777216 ] || { echo "$line"; return 1; }
}
check "the update's blob is the layer's, with under 3 MiB from the registry" update_swapped

# Version 1's blob gone before the helper copies: what it would have, fetched.
touch "$(cygpath -u "$gate")"
zg update --yes --lazy $APP >/dev/null 2>&1
gpid=$(helper2_pid g)
taskkill /F /PID "$gpid" >/dev/null 2>&1
for i in $(seq 1 40); do tasklist /fi "PID eq $gpid" /nh 2>/dev/null | grep -q " $gpid " || break; sleep 0.25; done
rm -f "$(lazy2_of g)\\blob.sparse" "$(lazy2_of g)\\have"
old_hex=$(tr -d ' \r\n' <"$(store a)\\blobs\\sha256\\$manifest" 2>/dev/null | grep -o '"digest":"sha256:[0-9a-f]\{64\}"' | tail -1 | grep -o '[0-9a-f]\{64\}')
rm -f "$(store g)\\blobs\\sha256\\$old_hex"
source_gone() {
    local n; n=$(zg run $APP wc -c "$(deploy2_of g)\\big.bin" 2>/dev/null | tr -d '\r' | awk '{ print $1 }')
    [ "$n" = 16777216 ] || { echo "wc said '$n'"; return 1; }
    grep -q 'the store no longer has layer' "$(lazy2_of g)\\log" || { echo "the log says nothing of the missing layer"; return 1; }
}
check "with the version before gone from the store, its files come from the registry" source_gone
rm -f "$(cygpath -u "$gate")"

# A byte of version 1's blob changed: the download's digest check finds it.
flip=$(cygpath -u "$(store h)\\blobs\\sha256\\$old_hex")
printf '\x00' | dd of="$flip" bs=1 seek=2000000 conv=notrunc 2>/dev/null
zh update --yes --lazy $APP >/dev/null 2>&1
bad_copy_caught() {
    local i
    for i in $(seq 1 120); do
        cp "$(lazy2_of h)\\log" "$work\\h.log" 2>/dev/null
        [ -d "$(lazy2_of h)" ] || break
        sleep 0.25
    done
    [ ! -d "$(lazy2_of h)" ] || { echo "lazy\\ still has the layer"; return 1; }
    grep -q "doesn't match its digest" "$work\\h.log" || { echo "the log says nothing of the digest"; return 1; }
    [ "$(sha256sum <"$(store h)\\blobs\\sha256\\$hex2" | cut -d' ' -f1)" = "$hex2" ] || { echo "the blob isn't the layer"; return 1; }
}
check "bytes copied wrong fail the blob's digest, and it's fetched again" bad_copy_caught

# --- What runs read, asked for ahead of the next version ---------------------
# Store j pulls version 1 lazily, from a repository of its own; a run reads
# small.txt, and the layer downloads and is swapped in. Version 2, whose
# small.txt is another, then has it asked for before any run does. (Store a
# builds each version again, which its build cache answers.)
zj() { ZIGSAW_HOME="$(store j)" ZIGSAW_TEST_LAZY_GATE="$gate" "$zigsaw" "$@"; }
za build "$fixture\\app.json" >/dev/null 2>&1 && za push $APP "$repo-j:latest" >/dev/null 2>&1 || { echo "pushing version 1 again failed"; exit 1; }
touch "$(cygpath -u "$gate")"
zj pull --yes --lazy "$repo-j:latest" >/dev/null 2>&1
zj run $APP cat "$(deploy_of j)\\small.txt" >/dev/null 2>&1
for i in $(seq 1 20); do grep -qxF "$hex small.txt" "$(learned_of j)" 2>/dev/null && break; sleep 0.25; done
rm -f "$(cygpath -u "$gate")"
for i in $(seq 1 80); do [ -d "$(lazy_of j)" ] || break; sleep 0.25; done
za build "$fixture2\\app.json" >/dev/null 2>&1 && za push $APP "$repo-j:latest" >/dev/null 2>&1 || { echo "pushing version 2 again failed"; exit 1; }
touch "$(cygpath -u "$gate")"
ahead_out=$(zj update --yes --lazy $APP 2>&1)
# The helper's requests so far, once two looks a second apart agree: its
# state is written once a second.
settled_requests() {
    local i r= last=
    for i in $(seq 1 10); do
        r=$(state2 "$1" requests)
        [ -n "$r" ] && [ "$r" = "$last" ] && break
        last=$r
        sleep 1.2
    done
    echo "$r"
}
asked_ahead() {
    grep -q 'that runs read before come' <<<"$ahead_out" || { echo "$ahead_out" | tail -3; return 1; }
    local i a=
    for i in $(seq 1 40); do a=$(state2 j ahead); [ -n "$a" ] && [ "$a" -gt 0 ] && break; sleep 0.25; done
    [ -n "$a" ] && [ "$a" -gt 0 ] || { echo "nothing was fetched ahead (${a:-no state})"; return 1; }
    grep -q 'asked ahead for 2 files runs read before' "$(lazy2_of j)\\log" || { echo "the log: $(grep 'ahead' "$(lazy2_of j)\\log" | tail -1)"; return 1; }
    # Fetched, not hydrated: a run's read of it is still to be seen.
    recall_on_access "$(deploy2_of j)\\small.txt" || { echo "small.txt isn't a placeholder any more"; return 1; }
}
check "update --lazy asks for what runs read of the version before, ahead of any run" asked_ahead
read_ahead() {
    local before after demand s
    before=$(settled_requests j)
    demand=$(state2 j on_demand)
    s=$(zj run $APP cat "$(deploy2_of j)\\small.txt" 2>/dev/null | tr -d '\r')
    [ "$s" = 'hello lazy, version 2' ] || { echo "small.txt says '$s'"; return 1; }
    after=$(settled_requests j)
    [ -n "$before" ] && [ "$before" = "$after" ] || { echo "requests went from ${before:-?} to ${after:-?}"; return 1; }
    [ "$(state2 j on_demand)" = "$demand" ] || { echo "bytes fetched for reads went from $demand to $(state2 j on_demand)"; return 1; }
    # Seen, and so written down for version 2 as well.
    grep -qxF "$hex2 small.txt" "$(learned_of j)" || { echo "the read wasn't written down: $(tr '\n' ' ' <"$(learned_of j)")"; return 1; }
    recall_on_access "$(deploy2_of j)\\new.bin" || { echo "new.bin was fetched for a run"; return 1; }
}
check "and a run then reads it without a request to the registry" read_ahead
forgotten() {
    zj rm $APP >/dev/null 2>&1 || { echo "rm failed"; return 1; }
    [ -e "$(learned_of j)" ] || { echo "rm deleted the list"; return 1; }
    zj prune >/dev/null 2>&1 || { echo "prune failed"; return 1; }
    [ ! -e "$(learned_of j)" ] || { echo "prune left the list"; return 1; }
}
check "rm leaves what runs read of the app, and prune forgets it" forgotten
rm -f "$(cygpath -u "$gate")"

# --- A slow link -------------------------------------------------------------
# LAZY_SLOW bytes a second, 1 MiB by default: big.bin's first 4 MiB chunk takes
# some 4 s, and the helper tells Windows how far it's got every 2. LAZY_WAIT,
# milliseconds each request waits before it goes: at 90000, what Windows would
# give up on after 60 s without it. (A slower rate doesn't do for that: the
# registry cuts a request that's read so slowly.)
touch "$(cygpath -u "$gate")"
zi() { ZIGSAW_HOME="$(store i)" ZIGSAW_TEST_LAZY_GATE="$gate" ZIGSAW_TEST_LAZY_SLOW="${LAZY_SLOW:-1048576}" ZIGSAW_TEST_LAZY_WAIT="${LAZY_WAIT:-0}" "$zigsaw" "$@"; }
zi pull --yes --lazy "$repo:1" >/dev/null 2>&1
slow_progress() {
    local out; out=$(zi run $APP head -c 10 "$(deploy_of i)\\big.bin" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ "$out" = "$(head -c 10 "$(cygpath -u "$fixture")/big.bin" | od -An -tx1 | tr -d ' \n')" ] || { echo "head read '$out'"; return 1; }
    grep -q 'progress: big.bin' "$(lazy_of i)\\log" || { echo "the log says nothing of progress"; return 1; }
    ! grep -q 'a fetch was cancelled' "$(lazy_of i)\\log" || { echo "Windows cancelled a fetch"; return 1; }
}
check "a slow fetch tells Windows how far it's got, and the run gets its bytes" slow_progress
rm -f "$(cygpath -u "$gate")"

if [ -n "${LAZY_DEV_DRIVE:-}" ]; then
    dev="$LAZY_DEV_DRIVE\\lazy-$$"
    dev_out=$(ZIGSAW_HOME="$dev" "$zigsaw" pull --yes --lazy "$repo:1" 2>&1)
    check "on a real Dev Drive too" grep -q "can't have Cloud Files placeholders.*downloaded whole" <<<"$dev_out"
    ZIGSAW_HOME="$dev" "$zigsaw" rm $APP >/dev/null 2>&1
    rm -rf "$(cygpath -u "$dev")"
fi

echo "$failures check(s) failed"
[ "$failures" -eq 0 ]
