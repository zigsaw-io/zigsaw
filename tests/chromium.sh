#!/usr/bin/env bash
# Chromium and Electron through the three sandboxes: ungoogled-chromium and
# VSCodium, as their recipes package them from upstream's zips. They bring a
# sandbox of their own, which Windows doesn't let start at low integrity or in
# an AppContainer (docs/findings.md), so both images ask for soft: each row
# says so, and tests/procprobe.zig checks with Windows that their renderers
# are confined. Each opens a file given with --file, hands a second one to the
# running instance, and is closed as its close button would. Their settings
# must be in their data directory, not the real AppData or registry.
#
#   tests/chromium.sh [path\to\zigsaw.exe]
#
# Like tests/guiapps.sh, each row states the intended result per sandbox: "ok",
# "fails", or "gap" for "ok is intended, but zigsaw doesn't manage it yet"; a
# gap is reported and doesn't fail the suite, so only changes do.
#
# Never kill Chromium here: its next start then asks "Restore pages?", and each
# later close counts as a crash until something answers.
#
# Needs Git Bash and git; opens windows on the desktop for a moment; not run
# in CI. Uses the store in CHROMIUM_HOME, or BUILD_HOME as tests/published.sh
# leaves it, and builds the apps that store lacks; without either, a temporary
# store, which downloads about 420 MB unless SEED_DOWNLOADS has the files. Apps
# it installed are removed again.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
own_store=false
ZIGSAW_HOME=${CHROMIUM_HOME:-${BUILD_HOME:-}}
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
export ZIGSAW_SHORTCUTS_DIR="$work\\links"
classes="Software\\ZigsawTest\\chromium-$$"
export ZIGSAW_CLASSES_KEY="$classes"
folders="$work\\folders"
for f in Desktop Documents Downloads Music Pictures Videos; do mkdir -p "$folders\\$f"; done
export ZIGSAW_USER_FOLDERS="$folders"

CHROMIUM=io.github.ungoogled_software.ungoogled_chromium
CODIUM=com.vscodium.codium

. "$(dirname "$0")/acprobe.sh"

(cd "$root" && zig build winwait procprobe) || { echo "building the window waiter and the process probe failed"; exit 1; }
winwait="$root\\zig-out\\test\\zigsaw-winwait.exe"
procprobe="$root\\zig-out\\test\\zigsaw-procprobe.exe"

installed=()
for recipe in recipes\\no-publish\\ungoogled-chromium recipes\\vscodium; do
    id=$(grep -o '"id": *"[^"]*"' "$root\\$recipe.json" | cut -d'"' -f4)
    [ -f "$ZIGSAW_HOME\\refs\\$id.json" ] || installed+=("$id")
    "$zigsaw" build "$root\\$recipe.json" >"$work\\build.log" 2>&1 || { echo "building $recipe failed: $(tail -1 "$work\\build.log")"; exit 1; }
done
# Another app's command, for VSCodium's terminal.
(cd "$root" && zig build hostprobe) || { echo "building the host probe failed"; exit 1; }
"$zigsaw" build "$root\\tests\\reach\\tool.json" >"$work\\build.log" 2>&1 || { echo "building the test tool failed: $(tail -1 "$work\\build.log")"; exit 1; }

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

# Where these apps would keep things outside zigsaw. Only what isn't there
# before the suite counts, and only that is removed afterwards.
real_dirs=("$LOCALAPPDATA\\Chromium" "$APPDATA\\VSCodium" "$USERPROFILE\\.vscode-oss" "$USERPROFILE\\AppData\\LocalLow\\Chromium")
absent_before=()
for d in "${real_dirs[@]}"; do [ -e "$d" ] || absent_before+=("$d"); done
had_chromium_key=false
reg query 'HKCU\Software\Chromium' >/dev/null 2>&1 && had_chromium_key=true
# What programs write to be found by others: a run that registers itself
# leaves its mark here. VSCodium did, on each start, until its recipe took
# that out.
hkcu_marks() {
    local k
    for k in 'HKCU\Software\Classes' 'HKCU\Software\RegisteredApplications' 'HKCU\Software\Clients\StartMenuInternet' \
        'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'; do
        reg query "$k" 2>/dev/null
    done | tr -d '\r' | sort
}
marks_before=$(hkcu_marks)
had_scheme_key=false
reg query 'HKCU\Software\Classes\vscodium' >/dev/null 2>&1 && had_scheme_key=true

cd "$work" || exit 1

page="$work\\zigsaw-page.html"
cat >"$page" <<'EOF'
<!doctype html><title>zigsaw-page</title><canvas id=c></canvas><script>
let g=document.getElementById('c').getContext('webgl');
document.title='zigsaw-page '+(g?'webgl-ok':'webgl-none');
</script>
EOF
printf '<!doctype html><title>zigsaw-second</title>' >"$work\\zigsaw-second.html"
cat >"$work\\zigsaw-download.html" <<'EOF'
<!doctype html><title>zigsaw-download</title><a id=a download="zigsaw-downloaded.txt" href="data:text/plain,hello">x</a>
<script>document.getElementById('a').click()</script>
EOF
note="$work\\zigsaw-note.txt"
printf 'a note for zigsaw\r\n' >"$note"
printf 'a second note\r\n' >"$work\\zigsaw-second.txt"

data() { echo "$ZIGSAW_HOME\\volumes\\$1"; }

runner=
winpid=
# start <id> <command> <sandbox> <file> [args]: runs the app in the background.
start() {
    local id=$1 cmd=$2 sandbox=$3 file=$4
    shift 4
    "$zigsaw" run --sandbox=$sandbox --command=$cmd --file="$file" $id "$@" >"$work\\run.log" 2>&1 &
    runner=$!
    # Only windows of that run count (its Windows pid; $! is Git Bash's).
    winpid=$(cat /proc/$runner/winpid)
}
# window <title> <seconds>: a window of the run has that title; gives up at once
# if the run has ended, as under a sandbox the app can't start in.
window() {
    local title=$1 limit=$2 i
    for ((i = 0; i < limit; i++)); do
        "$winwait" "$winpid" "$title" 1 >/dev/null 2>&1 && return 0
        kill -0 $runner 2>/dev/null || {
            wait $runner
            echo "the run ended with exit code $? and no window named $title; $(tail -1 "$work\\run.log")"
            return 1
        }
    done
    echo "no window named $title in $limit s"
    stop
    return 1
}
# stop: ends the run if it's still going. Closing its window ends it; this is
# for when something went wrong.
stop() {
    kill -0 $runner 2>/dev/null && taskkill /PID "$winpid" /T /F >/dev/null 2>&1
    wait $runner 2>/dev/null
}
# finish <title>: closes the window, as its close button would; the run must
# then end by itself, with exit code 0.
finish() {
    local title=$1 i status
    "$winwait" "$winpid" "$title" 15 --close >/dev/null
    status=$?
    for i in $(seq 75); do
        kill -0 $runner 2>/dev/null || break
        sleep 0.2
    done
    if kill -0 $runner 2>/dev/null; then
        stop
        echo "the run didn't end after closing $title (winwait $status)"
        return 1
    fi
    wait $runner || { echo "zigsaw run failed: $(tail -1 "$work\\run.log")"; return 1; }
}

# A window station is what's refused at low integrity and in an AppContainer:
# this is why the rows below fail there, so a Windows that allows it shows up
# here first.
acprobe_run "$zigsaw" "$root" "$work"
makes_station() {
    local out
    out=$(cd "$work\\acprobe\\cwd" && "$zigsaw" run --sandbox=$1 $ACPROBE_ID 2>/dev/null | tr -d '\r')
    grep -qx 'window-station ok' <<<"$out" || { grep '^window-station' <<<"$out"; return 1; }
}
row "A program can make a window station, which Chromium's sandbox needs before anything else" ok fails fails makes_station

# opens <id> <command> <file> <title> <seconds> <args...> -- <sandbox>
opens() {
    local id=$1 cmd=$2 file=$3 title=$4 limit=$5
    shift 5
    local args=()
    while [ "$1" != -- ]; do args+=("$1"); shift; done
    start $id $cmd "$2" "$file" "${args[@]}"
    window "$title" $limit || return 1
    finish "$title"
}
row "Chromium opens a page given with --file, and draws WebGL" ok fails fails \
    opens $CHROMIUM chromium "$page" 'webgl-ok' 30 --
row "VSCodium opens a file given with --file" ok fails fails \
    opens $CODIUM codium "$note" 'zigsaw-note.txt - ' 30 --
# What docs/published-apps.md offers those who'd rather confine its extensions
# and terminal. In an AppContainer, Node's realpath stops it first.
row "VSCodium opens a file given with --file, told --no-sandbox" ok gap ok \
    opens $CODIUM codium "$note" 'zigsaw-note.txt - ' 30 --no-sandbox --

# confined <id> <command> <file> <title> <sandbox>: Windows says the app's
# renderers are at untrusted integrity with restricted tokens, its GPU process
# restricted, and nothing was told --no-sandbox.
confined() {
    local id=$1 cmd=$2 file=$3 title=$4 sandbox=$5 procs result=0
    start $id $cmd $sandbox "$file"
    window "$title" 30 || return 1
    sleep 3
    procs=$("$procprobe" "$winpid")
    grep -q 'type=renderer.*il=untrusted.*restricted=yes' <<<"$procs" || { echo "no confined renderer: $procs"; result=1; }
    ! grep 'type=renderer' <<<"$procs" | grep -qv 'il=untrusted.*restricted=yes' || { echo "a renderer isn't confined: $(grep 'type=renderer' <<<"$procs")"; result=1; }
    grep -q 'type=gpu-process.*restricted=yes' <<<"$procs" || { echo "the GPU process isn't restricted: $(grep gpu-process <<<"$procs")"; result=1; }
    ! grep -q 'no-sandbox=yes' <<<"$procs" || { echo "something was told --no-sandbox"; result=1; }
    finish "$title" || result=1
    return $result
}
check "Chromium's renderers are confined under its image's sandbox" confined $CHROMIUM chromium "$page" 'webgl-ok' soft
check "VSCodium's renderer is confined under its image's sandbox" confined $CODIUM codium "$note" 'zigsaw-note.txt - ' soft

# hands_over <id> <command> <first file> <first title> <second file> <second title>:
# a second run gives its file to the running instance, and ends.
hands_over() {
    local id=$1 cmd=$2 one=$3 first=$4 two=$5 second=$6 i
    start $id $cmd soft "$one"
    window "$first" 30 || return 1
    "$zigsaw" run --sandbox=soft --command=$cmd --file="$two" $id >"$work\\second.log" 2>&1 &
    local other=$!
    for i in $(seq 75); do
        kill -0 $other 2>/dev/null || break
        sleep 0.2
    done
    if kill -0 $other 2>/dev/null; then
        taskkill /PID "$(cat /proc/$other/winpid)" /T /F >/dev/null 2>&1
        finish "$first"
        echo "the second run didn't end"
        return 1
    fi
    wait $other || { finish "$first"; echo "the second run failed: $(tail -1 "$work\\second.log")"; return 1; }
    window "$second" 15 || return 1
    finish "$second"
}
check "Chromium's second run opens a tab in the first, and ends" hands_over $CHROMIUM chromium "$page" 'webgl-ok' "$work\\zigsaw-second.html" 'zigsaw-second'
check "VSCodium's second run opens its file in the first, and ends" hands_over $CODIUM codium "$note" 'zigsaw-note.txt - ' "$work\\zigsaw-second.txt" 'zigsaw-second.txt - '

# plays: Chromium decodes H.264, whose decoder is in its build's ffmpeg. The
# clip is a few frames made by ffmpeg, if this machine has it. The first frame
# is what's waited for, and it's told not to hold back in a covered window, as
# it may not be at the front.
printf '<!doctype html><title>video-page</title><video id=v src="zigsaw-clip.mp4" muted autoplay></video><script>
let v=document.getElementById("v");
v.onloadeddata=()=>{document.title="video-result decoded "+v.videoWidth+"x"+v.videoHeight};
v.onerror=()=>{document.title="video-result error "+v.error.code};
</script>\n' >"$work\\zigsaw-video.html"
plays() {
    start $CHROMIUM chromium soft "$work\\zigsaw-video.html" --disable-backgrounding-occluded-windows
    window 'video-result' 30 || return 1
    local title
    title=$("$winwait" "$winpid" 'video-result' 1)
    finish 'video-result' || return 1
    grep -q 'video-result decoded 320x240' <<<"$title" || { echo "$title"; return 1; }
}
if ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=2:size=320x240:rate=25 -c:v libx264 -pix_fmt yuv420p "$work\\zigsaw-clip.mp4" 2>/dev/null; then
    check "Chromium decodes an H.264 clip" plays
else
    echo "skip  Chromium decodes an H.264 clip: no ffmpeg with x264 here"
fi

# keeps_key: Chromium keeps HKCU\Software\Chromium, which its recipe declares,
# with its data, in HKCU only while it runs.
keeps_key() {
    start $CHROMIUM chromium soft "$page"
    window 'webgl-ok' 30 || return 1
    sleep 2
    reg query 'HKCU\Software\Chromium' >/dev/null 2>&1 || { finish 'webgl-ok'; echo "the key isn't there while it runs"; return 1; }
    finish 'webgl-ok' || return 1
    ! reg query 'HKCU\Software\Chromium' >/dev/null 2>&1 || { echo "HKCU\\Software\\Chromium is still there"; return 1; }
    [ -f "$(data $CHROMIUM)\\registry\\user.dat" ] || { echo "no user.dat in its data"; return 1; }
}
if $had_chromium_key; then
    echo "skip  Chromium keeps its key with its data: HKCU\\Software\\Chromium was there before"
else
    check "Chromium keeps its registry key with its data, and in HKCU only while it runs" keeps_key
fi

# save_as: a download asks where to save, as ungoogled-chromium's defaults
# have it, and Windows' dialog finds every folder it looks for: it complains
# about a home without Documents ("Location is not available"). It goes in
# Downloads, your own through a link: its .tmp file is there while it asks.
save_as() {
    local result=0 downloads
    downloads=$(cygpath -u "$folders\\Downloads")
    rm -f "$downloads"/*.tmp
    start $CHROMIUM chromium soft "$work\\zigsaw-download.html"
    window 'zigsaw-download' 30 || return 1
    window 'Save As' 15 || return 1
    sleep 2
    if "$winwait" "$winpid" 'Location is not available' 1 >/dev/null 2>&1; then
        echo "Windows' dialog said a location isn't available"
        "$winwait" "$winpid" 'Location is not available' 1 --dismiss >/dev/null
        sleep 1
        result=1
    fi
    ls "$downloads"/*.tmp >/dev/null 2>&1 || { echo "no .tmp in the Downloads it was granted"; result=1; }
    "$winwait" "$winpid" 'Save As' 5 --dismiss >/dev/null
    sleep 1
    finish ' - Chromium' || result=1
    rm -f "$downloads"/*.tmp
    return $result
}
check "Chromium's download asks where to save, with no complaint, and starts in Downloads" save_as

# The terminal, without clicking: a workspace task runs in VSCodium's terminal
# as the folder opens, and says what it finds there. Its settings let it.
proj="$work\\proj"
mkdir -p "$proj\\.vscode"
(cd "$proj" && git init -q)
cat >"$proj\\.vscode\\tasks.json" <<'EOF'
{ "version": "2.0.0", "tasks": [ { "label": "probe", "type": "process", "command": "cmd.exe", "args": ["/d", "/c", "probe.cmd"],
  "runOptions": { "runOn": "folderOpen" }, "presentation": { "reveal": "never" }, "problemMatcher": [] } ] }
EOF
{
    printf '@echo off\r\n> term.txt echo started\r\n'
    printf 'whoami /groups | findstr /C:"Mandatory Label" >> term.txt\r\n'
    printf 'git --version >> term.txt 2>&1\r\ngit status --short --branch >> term.txt 2>&1\r\n'
    printf 'call reach-probe >> term.txt 2>&1\r\n'
    printf 'zigsaw-host cmd /c set USERPROFILE >> term.txt 2>&1\r\n'
    printf 'call codium --version >> term.txt 2>&1\r\n>> term.txt echo done\r\n'
} >"$proj\\probe.cmd"
settings="$(data $CODIUM)\\home\\AppData\\Roaming\\VSCodium\\User"
mkdir -p "$settings"
# Its own question before a link opens a file stays in the image; a dialog
# here would only hold the suite up.
printf '{ "security.workspace.trust.enabled": false, "task.allowAutomaticTasks": "on", "security.promptForLocalFileProtocolHandling": false }\n' >"$settings\\settings.json"
terminal() {
    local i
    rm -f "$proj\\term.txt"
    cd "$proj" || return 1
    "$zigsaw" run --command=codium $CODIUM "$proj" >"$work\\run.log" 2>&1 &
    runner=$!
    winpid=$(cat /proc/$runner/winpid)
    cd "$work" || return 1
    window 'proj - ' 30 || return 1
    for i in $(seq 100); do
        grep -q '^done' "$proj\\term.txt" 2>/dev/null && break
        sleep 0.3
    done
    sleep 2
    finish 'proj - ' || return 1
    [ -f "$proj\\term.txt" ] || { echo "the task wrote nothing"; return 1; }
    grep -qE 'Mandatory Label.(Medium|High) ' "$proj\\term.txt" || { echo "not at the run's integrity level: $(cat "$proj\\term.txt")"; return 1; }
    grep -q '^git version .*windows' "$proj\\term.txt" || { echo "git isn't there: $(cat "$proj\\term.txt")"; return 1; }
    grep -q '^## ' "$proj\\term.txt" || { echo "git status failed: $(cat "$proj\\term.txt")"; return 1; }
    grep -qE '^[0-9]+\.[0-9]+\.[0-9]+' "$proj\\term.txt" || { echo "codium isn't on its terminal's PATH: $(cat "$proj\\term.txt")"; return 1; }
    grep -qF "env USERPROFILE = $ZIGSAW_HOME\\volumes\\test.reach.tool\\home" "$proj\\term.txt" || { echo "another app's command didn't run as itself: $(tail -5 "$proj\\term.txt")"; return 1; }
    grep -qF "USERPROFILE=$USERPROFILE" "$proj\\term.txt" || { echo "zigsaw-host didn't give your environment: $(tail -5 "$proj\\term.txt")"; return 1; }
    local log
    log=$(find "$(cygpath -u "$(data $CODIUM)")" -name Git.log 2>/dev/null | xargs -r ls -t 2>/dev/null | head -1)
    grep -q 'Using git .*windows' "$log" || { echo "git's extension didn't find it: $log"; return 1; }
}
check "VSCodium's terminal runs a task, with git, your apps' commands and zigsaw-host on its PATH, and its git extension finds git" terminal

# saves <sandbox>: a small extension edits a file and saves it, through the
# editor's own file service.
saves() {
    local i saved="$work\\saved-$1.txt"
    printf 'before\n' >"$saved"
    "$zigsaw" run --sandbox=$1 --env="ZIGSAW_SAVER_FILE=$saved" --file="$saved" $CODIUM "--extensionDevelopmentPath=$root\\tests\\chromium\\saver" ${2:-} >"$work\\run.log" 2>&1 &
    runner=$!
    winpid=$(cat /proc/$runner/winpid)
    window "saved-$1.txt - " 30 || return 1
    for i in $(seq 75); do
        grep -q '^saved by the editor' "$saved" && break
        sleep 0.2
    done
    finish "saved-$1.txt - " || return 1
    grep -q '^saved by the editor' "$saved" || { echo "the file on disk says: $(head -1 "$saved")"; return 1; }
}
saves_row() {
    if [ "$1" = soft ]; then saves soft; else saves low --no-sandbox; fi
}
check "VSCodium's extension host edits and saves a file (under soft)" saves_row soft
check "VSCodium's extension host edits and saves a file (at low, told --no-sandbox)" saves_row low

# The console's commands.
cli_version() {
    local out
    out=$("$zigsaw" run --sandbox=$1 --command=codium-cli $CODIUM --version 2>/dev/null | tr -d '\r' | head -1)
    grep -qx '[0-9]*\.[0-9]*\.[0-9]*' <<<"$out" || { echo "codium-cli --version said \"$out\""; return 1; }
}
# In an AppContainer, Node's realpath fails on the drive's root.
row "codium-cli --version" ok gap ok cli_version
no_update_check() {
    local log
    log=$(ls -td "$(cygpath -u "$(data $CODIUM)")"/home/AppData/Roaming/VSCodium/logs/*/main.log 2>/dev/null | head -1)
    grep -q 'no update URL' "$log" || { echo "its log doesn't say updates are off: $log"; return 1; }
}
check "VSCodium doesn't look for updates: zigsaw's its way of getting them" no_update_check

# codium <folder>: through the shim, as from a console, the editor outlives
# the command that a console would come back from. codium-cli hands over too.
shim_stays() {
    local i
    cd "$proj" || return 1
    "$ZIGSAW_HOME\\bin\\codium.exe" . >"$work\\run.log" 2>&1 </dev/null &
    runner=$!
    winpid=$(cat /proc/$runner/winpid)
    cd "$work" || return 1
    window 'proj - ' 30 || return 1
    sleep 4
    "$winwait" "$winpid" 'proj - ' 1 >/dev/null || { echo "its window went away"; stop; return 1; }
    (cd "$proj" && "$ZIGSAW_HOME\\bin\\codium-cli.exe" "$work\\zigsaw-second.txt" >"$work\\second.log" 2>&1 </dev/null) || { finish 'proj - '; echo "codium-cli failed: $(tail -1 "$work\\second.log")"; return 1; }
    window 'zigsaw-second.txt - ' 15 || return 1
    finish 'zigsaw-second.txt - '
}
check "codium <folder> stays up after its shim's started it, and codium-cli opens a file in it" shim_stays

# Links, through the shims Windows would start. VSCodium's handler is its own:
# it opens a file named by a vscodium://file/ link. Each row's file is one it
# has never opened, so that restoring its last session can't show it.
codium_url="$ZIGSAW_HOME\\open\\$CODIUM\\urls\\codium-url.exe"
chromium_url="$ZIGSAW_HOME\\open\\$CHROMIUM\\urls\\chromium-url.exe"
link_to() { printf 'vscodium://file/%s' "$(cygpath -m "$1")"; }
for f in started handed windows; do printf 'opened by a link\r\n' >"$work\\zigsaw-link-$f.txt"; done
link_starts() {
    "$codium_url" "$(link_to "$work\\zigsaw-link-started.txt")" >"$work\\run.log" 2>&1 </dev/null &
    runner=$!
    winpid=$(cat /proc/$runner/winpid)
    window 'zigsaw-link-started.txt - ' 30 || return 1
    finish 'zigsaw-link-started.txt - '
}
check "A vscodium: link starts VSCodium, with the file it names" link_starts
link_hands_over() {
    start $CODIUM codium soft "$note"
    window 'zigsaw-note.txt - ' 30 || return 1
    "$codium_url" "$(link_to "$work\\zigsaw-link-handed.txt")" >"$work\\second.log" 2>&1 </dev/null || { finish 'zigsaw-note.txt - '; echo "the link's run failed: $(tail -1 "$work\\second.log")"; return 1; }
    window 'zigsaw-link-handed.txt - ' 15 || return 1
    finish 'zigsaw-link-handed.txt - '
}
check "A vscodium: link goes to the VSCodium that's running" link_hands_over
link_refused() {
    local out
    out=$("$codium_url" "$(link_to "$note")" --disable-extensions 2>&1 </dev/null) && { echo "two arguments were taken"; return 1; }
    grep -q 'came as several' <<<"$out" || { echo "$out"; return 1; }
}
check "A link that comes as two arguments starts nothing" link_refused
# Nothing listens there: Chromium's error page has the host for its title.
http_link() {
    "$chromium_url" 'http://127.0.0.1:9/zigsaw-link' >"$work\\run.log" 2>&1 </dev/null &
    runner=$!
    winpid=$(cat /proc/$runner/winpid)
    window '127.0.0.1' 30 || return 1
    finish '127.0.0.1'
}
check "An http: link opens in Chromium, through --single-argument" http_link
says_why() {
    local out sb
    for sb in low appcontainer; do
        out=$("$zigsaw" run --sandbox=$sb --command=codium-cli $CODIUM --version 2>&1 </dev/null)
        grep -q "can't run under the $sb sandbox: Windows refuses Chromium's sandbox a window station" <<<"$out" || { echo "$sb: $out"; return 1; }
    done
}
check "A run under a sandbox it can't use says why" says_why

untouched() {
    local d now
    for d in "${absent_before[@]}"; do [ ! -e "$d" ] || { echo "$d appeared"; return 1; }; done
    $had_chromium_key || ! reg query 'HKCU\Software\Chromium' >/dev/null 2>&1 || { echo "HKCU\\Software\\Chromium appeared"; return 1; }
    ! reg query 'HKCU\Software\VSCodium' >/dev/null 2>&1 || { echo "HKCU\\Software\\VSCodium appeared"; return 1; }
    now=$(hkcu_marks)
    [ "$now" = "$marks_before" ] || { echo "new in HKCU: $(comm -13 <(printf '%s\n' "$marks_before") <(printf '%s\n' "$now") | head -3 | tr '\n' ' ')"; return 1; }
}
check "They left the real AppData, profile and registry alone" untouched

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
check "Chromium gets the windowless shim, a shortcut, and .html, .htm, .pdf, .svg" gui_installed $CHROMIUM chromium ungoogled-chromium .html .htm .pdf .svg
check "VSCodium gets the windowless shim, a shortcut, and .json, .js, .ts, .py, .zig, .md" gui_installed $CODIUM codium VSCodium .json .js .ts .py .zig .md
check "codium-cli, its command-line program, gets the console shim" cmp -s "$ZIGSAW_HOME\\bin\\codium-cli.exe" "$shim_dir\\zigsaw-shim.exe"
offered() {
    local caps="HKCU\\$classes\\Apps\\$CHROMIUM\\Capabilities\\URLAssociations"
    reg query "$caps" /v http >/dev/null 2>&1 || { echo "http isn't listed"; return 1; }
    reg query "$caps" /v https >/dev/null 2>&1 || { echo "https isn't listed"; return 1; }
    ! reg query "HKCU\\$classes\\http" >/dev/null 2>&1 || { echo "it took http's own key"; return 1; }
    reg query "HKCU\\$classes\\Zigsaw.$CHROMIUM.url.https\\shell\\open\\command" >/dev/null 2>&1 || { echo "nothing to open https with"; return 1; }
}
check "Chromium is offered for http and https, and takes neither" offered

# Last, in the real classes, followed through Windows; only if nothing has the
# scheme, and all of it is taken back.
through_windows() {
    local key='HKCU\Software\Classes\vscodium' out i pid
    ZIGSAW_CLASSES_KEY='Software\Classes' "$zigsaw" build "$root\\recipes\\vscodium.json" >"$work\\build.log" 2>&1 || { echo "installing it failed: $(tail -1 "$work\\build.log")"; return 1; }
    out=$(reg query "$key\\shell\\open\\command" 2>&1)
    grep -qF "$ZIGSAW_HOME\\open\\$CODIUM\\urls\\codium-url.exe" <<<"$out" || { echo "$out"; return 1; }
    powershell -NoProfile -Command "Start-Process '$(link_to "$work\\zigsaw-link-windows.txt")'" || return 1
    for ((i = 0; i < 40; i++)); do
        pid=$(powershell -NoProfile -Command "(Get-Process VSCodium -ErrorAction SilentlyContinue | Where-Object { \$_.MainWindowTitle -like 'zigsaw-link-windows.txt*' } | Select-Object -First 1).Id" | tr -d '\r')
        [ -n "$pid" ] && break
        sleep 0.5
    done
    local result=0
    if [ -n "$pid" ]; then
        "$winwait" "$pid" 'zigsaw-link-windows.txt - ' 15 --close >/dev/null
        sleep 3
    else
        echo "no window for the file"
        result=1
    fi
    # It stays as zigsaw wrote it: a run doesn't rewrite it.
    out=$(reg query "$key\\shell\\open\\command" 2>&1)
    grep -qF "$ZIGSAW_HOME\\open\\$CODIUM\\urls\\codium-url.exe" <<<"$out" || { echo "the run rewrote it: $out"; result=1; }
    # Whatever came of that, the real registry goes back as it was.
    ZIGSAW_CLASSES_KEY='Software\Classes' "$zigsaw" rm "$CODIUM" >/dev/null 2>&1 || { echo "rm failed"; result=1; }
    ! reg query "$key" >/dev/null 2>&1 || { echo "rm left it"; result=1; }
    "$zigsaw" build "$root\\recipes\\vscodium.json" >"$work\\build.log" 2>&1
    return $result
}
if $had_scheme_key; then
    echo "skip  a link followed through Windows: HKCU\\Software\\Classes\\vscodium was there before"
else
    check "A link Windows follows starts VSCodium through zigsaw, and rm takes the key out" through_windows
fi

cd "$root" || exit 1
acprobe_rm "$zigsaw"
for id in "${installed[@]}"; do "$zigsaw" rm --delete-data "$id" >/dev/null 2>&1; done
"$zigsaw" rm --delete-data test.reach.tool >/dev/null 2>&1
$had_chromium_key || reg delete 'HKCU\Software\Chromium' /f >/dev/null 2>&1
for d in "${absent_before[@]}"; do rm -rf "$d"; done
reg delete "HKCU\\$classes" /f >/dev/null 2>&1
reg query 'HKCU\Software\ZigsawTest' 2>/dev/null | grep -q . || reg delete 'HKCU\Software\ZigsawTest' /f >/dev/null 2>&1
$own_store && rm -rf "$ZIGSAW_HOME"
rm -rf "$work"
echo
echo "$failures check(s) failed; $gaps known gap(s)."
exit $((failures > 0))
