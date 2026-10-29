#!/usr/bin/env bash
# End-to-end checks for what the enforcing sandboxes change on the host, how
# long it lasts, and what `zigsaw rm` undoes: low integrity labels on the
# paths a low run (the default) may write, access granted to an app's
# AppContainer, and what each lets a run write; which sandbox a run gets
# (the image's, the overrides', the command line's). What a run's command
# line asks for lasts until the app's last run ends; what its permissions and
# saved overrides give stays (src/grants.zig). Busybox apps; tests/matrix.sh
# runs real tools.
#
#   tests/sandbox.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and network access (for the busybox download, unless
# SEED_DOWNLOADS has it). Always uses a temporary store (on TMPDIR's drive),
# and removes it, and the AppContainer profiles it made, afterwards.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
# SEED_DOWNLOADS: another store's cache\downloads, whose files are linked, or
# copied, into this one's, so as not to download them again.
if [ -n "${SEED_DOWNLOADS:-}" ]; then
    mkdir -p "$ZIGSAW_HOME\\cache\\downloads"
    cp -l "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/" 2>/dev/null ||
        cp -n "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/"
fi

BB=net.frippery.busybox
OTHER=test.sandbox.other

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

z() { "$zigsaw" "$@" </dev/null; }
# writes <app> <sandbox> <file> [run options...]: whether a run can create the file.
writes() {
    local app=$1 sb=$2 file=$3
    shift 3
    z run --sandbox="$sb" "$@" "$app" sh -c "echo x > '$file'"
}
# What icacls says about a path's integrity label, and its ACEs for
# AppContainer packages (S-1-15-2-) and capabilities (S-1-15-3-).
label_of() { icacls "$1" | grep -o 'Mandatory Label\\[A-Za-z]* Mandatory Level:([A-Z()]*)'; }
low_label() { label_of "$1" | grep -q 'Low Mandatory Level:(OI)(CI)(NW)'; }
no_label() { ! label_of "$1"; }
has_ace() { icacls "$1" | grep -q "$2"; }
granted() { grep -qxF "$2" "$ZIGSAW_HOME\\grants\\$1.txt" 2>/dev/null; }
# icacls_in <app> <sandbox> <path> [run options...]: icacls's view of the
# path from inside a run of the app, while what the run was granted is there.
icacls_in() {
    local app=$1 sb=$2 p=$3
    shift 3
    z run --sandbox="$sb" "$@" --command=icacls "$app" "$p"
}
# hold <dir> <app> [run options...]: starts a run of the app that goes on,
# writing to <dir>, until `release`; returns once it's going. Its PID is in
# $held.
hold() {
    local dir=$1 app=$2
    shift 2
    rm -f "$dir\\started" "$dir\\stop"
    "$zigsaw" run "$@" "$app" sh -c "touch '$dir\\started'; while [ ! -f '$dir\\stop' ]; do sleep 0.2; done" </dev/null >/dev/null 2>&1 &
    held=$!
    held_dir=$dir
    local i
    for i in $(seq 100); do [ -f "$dir\\started" ] && return 0; sleep 0.1; done
    return 1
}
release() {
    touch "$held_dir\\stop"
    wait $held
}

(cd "$root" && zig build hostprobe) || { echo "building the host probe failed"; exit 1; }
hostprobe="$root\\zig-out\\test\\zigsaw-hostprobe.exe"
"$zigsaw" build "$root/recipes/busybox.json" >/dev/null 2>&1 || { echo "building busybox failed"; exit 1; }
sed "s/\"net.frippery.busybox\"/\"$OTHER\"/" "$root/recipes/busybox.json" >"$work\\other.json"
"$zigsaw" build "$work\\other.json" >/dev/null 2>&1 || { echo "building the second app failed"; exit 1; }

mkdir -p "$work\\rw" "$work\\ro" "$work\\outside" "$work\\cwd" "$work\\ac" "$work\\mine" "$work\\own"
echo secret >"$work\\outside\\secret.txt"

# --- What a low run can write ------------------------------------------------
#
# Grants from a run's command line last for the run: what it has meanwhile
# shows from inside it.

labelled_in_run() { icacls_in $BB low "$1" --filesystem="$2" | grep -qF "$3"; }
label_gone() { no_label "$1" && fails granted $BB "low $1"; }
check "low: writes its data directory" z run --sandbox=low $BB sh -c 'echo x > "$APPDATA/f"'
check "low: writes a path it may write" writes $BB low "$work\\rw\\f" --filesystem="$work\\rw"
check "  which is labelled low while it runs, for everything in it" labelled_in_run "$work\\rw" "$work\\rw" 'Low Mandatory Level:(OI)(CI)(NW)'
check "  what it wrote inherits the label" labelled_in_run "$work\\rw\\f" "$work\\rw" 'Low Mandatory Level:(I)(NW)'
check "  and the label, and its record, go when the run ends" sh -c "$(declare -f label_of no_label fails granted label_gone); BB=$BB; ZIGSAW_HOME='$ZIGSAW_HOME'; label_gone '$work\\rw' && no_label '$work\\rw\\f'"
check "low: can't write a read-only grant" fails writes $BB low "$work\\ro\\f" --filesystem="$work\\ro:ro"
check "  which isn't labelled" no_label "$work\\ro"
check "low: can't write elsewhere" fails writes $BB low "$work\\outside\\f"
check "low: reads elsewhere (not enforced)" z run --sandbox=low $BB cat "$work\\outside\\secret.txt"
check "low: writes cwd with the cwd permission" sh -c "cd '$work\\cwd' && \"\$0\" run --sandbox=low --filesystem=cwd $BB sh -c 'echo x > \"\$1\"' sh '$work\\cwd\\f' </dev/null" "$zigsaw"
check "  which, given on the command line, isn't labelled after it" label_gone "$work\\cwd"
check "  and the run's data directory is labelled" low_label "$ZIGSAW_HOME\\data\\$BB"
refuses_profile() {
    local out
    out=$(writes $BB low "$USERPROFILE\\zigsaw-sandbox-test" --filesystem="$USERPROFILE" 2>&1) && return 1
    grep -q "it's your user profile" <<<"$out" || { echo "$out"; return 1; }
    [ ! -e "$USERPROFILE\\zigsaw-sandbox-test" ] && no_label "$USERPROFILE"
}
check "low: won't label the user profile" refuses_profile
check "low: --ephemeral writes its own data directory" z run --sandbox=low --ephemeral $BB sh -c 'echo x > "$APPDATA/f"'
# BusyBox's sh waits for the last command of sh -c only if it can see its
# parent, zigsaw, which a low-integrity process could not read.
check "low: sh sees zigsaw as its parent" sh -c '[ "$("$0" run --sandbox=low '$BB' sh -c "echo \$PPID" </dev/null | tr -d "\r")" != 1 ]' "$zigsaw"
check "low: sh -c's last command runs to the end, and its exit code comes through" sh -c '
    out=$("$0" run --sandbox=low '$BB' sh -c "busybox.exe sh -c \"sleep 1; echo late; exit 7\"" </dev/null | tr -d "\r"; echo "code ${PIPESTATUS[0]}")
    [ "$out" = "late
code 7" ]' "$zigsaw"

# A directory that gives its owner Modify, not WRITE_OWNER, which labelling
# needs, as a fresh drive's root does (D:\ on Windows 11). zigsaw grants it
# for the change, and puts the ACL back.
mkdir -p "$work\\modify\\rw"
icacls "$work\\modify" /inheritance:r /grant:r "$USERNAME:(OI)(CI)M" >/dev/null
acl_before=$(icacls "$work\\modify\\rw" | grep -v '^Successfully')
if icacls "$work\\modify\\rw" /setintegritylevel '(OI)(CI)low' >/dev/null 2>&1; then
    # An administrator's token can take ownership; CI runs as one.
    echo "skip  low: a path that withholds WRITE_OWNER (this user can label it anyway)"
else
    check "low: writes a path that withholds WRITE_OWNER" writes $BB low "$work\\modify\\rw\\f" --filesystem="$work\\modify\\rw"
    check "  which is labelled low while it runs" labelled_in_run "$work\\modify\\rw" "$work\\modify\\rw" 'Low Mandatory Level:(OI)(CI)(NW)'
    check "  and unlabelled after it, with its ACL as it was" sh -c "[ \"\$(icacls '$work\\modify\\rw' | grep -v '^Successfully')\" = \"\$0\" ]" "$acl_before"
fi

# --- The default sandbox ----------------------------------------------------------
#
# Low, unless the app's image asks for another, or an override or the command
# line chooses one: the app's overrides over the store-wide ones (--global).

SOFT=test.sandbox.soft
sed -e "s/\"net.frippery.busybox\"/\"$SOFT\"/" \
    -e 's/"command": "busybox.exe",/&\n  "permissions": { "sandbox": "soft" },/' \
    "$root/recipes/busybox.json" >"$work\\soft.json"
soft_built=$("$zigsaw" build "$work\\soft.json" 2>&1 </dev/null) || { echo "building the soft app failed: $soft_built"; exit 1; }
mkdir -p "$work\\global"
# from <dir> <run options and app...>: a run that may write its working
# directory tries to, from <dir>; prints what zigsaw said.
from() {
    local d=$1
    shift
    (cd "$d" && "$zigsaw" run --filesystem=cwd "$@" sh -c 'ls >/dev/null && echo x > zigsaw-sandbox-test' </dev/null 2>&1)
}
# read_only_cwd <dir>: a low run from there goes on, with its working
# directory read-only, and says so; nothing is written or labelled.
read_only_cwd() {
    local out
    out=$(from "$1" $BB) && return 1
    grep -q "is read-only for this run, as $2: run the app from a folder inside it" <<<"$out" || { echo "$out"; return 1; }
    [ ! -e "$1\\zigsaw-sandbox-test" ] && fails low_label "$1" && fails granted $BB "low $1"
}
drive=${work:0:3}
home_run_quiet() {
    local home="$ZIGSAW_HOME\\data\\$BB\\home" out
    out=$(from "$home" $BB) || { echo "$out"; return 1; }
    ! grep -q labelled <<<"$out" && fails granted $BB "low $home" && [ ! -e "$ZIGSAW_HOME\\grants\\$BB.cwd" ]
}
global_shown() { [ "$("$zigsaw" override --global </dev/null | tr -d '\r')" = "--sandbox=appcontainer" ]; }
global_reset() {
    "$zigsaw" override --global --reset 2>&1 </dev/null | grep -q 'no store-wide overrides now' && writes $SOFT soft "$work\\outside\\soft4" &&
        z run $SOFT sh -c "echo x > '$work\\outside\\soft5'"
}
global_grant_back() {
    "$zigsaw" override --global --sandbox=low --filesystem="$work\\global" >/dev/null 2>&1 || return 1
    z run $BB sh -c "echo x > '$work\\global\\f'" && low_label "$work\\global" && granted $BB "low $work\\global" || return 1
    local out
    out=$("$zigsaw" override --global --reset 2>&1 </dev/null)
    grep -q 'removed the low integrity label' <<<"$out" || { echo "$out"; return 1; }
    no_label "$work\\global" && fails granted $BB "low $work\\global"
}
check "a run without --sandbox is low: it writes its data directory" z run $BB sh -c 'echo x > "$APPDATA/default"'
check "  and can't write elsewhere" fails z run $BB sh -c "echo x > '$work\\outside\\default'"
check "low: from your user profile, the app runs with its working directory read-only" read_only_cwd "$USERPROFILE" "it's your user profile"
check "low: from a drive's root, too" read_only_cwd "$drive" "it's the root of a drive"
check "low: from the app's own home, as a shortcut starts it, nothing is labelled or recorded" home_run_quiet
check "an image that asks for soft says so when installed" grep -q 'permits  whatever you can write (it asks for the soft sandbox)' <<<"$soft_built"
check "  and its runs write elsewhere" z run $SOFT sh -c "echo x > '$work\\outside\\soft1'"
check "  unless the store-wide overrides choose another sandbox" sh -c "\"\$0\" override --global --sandbox=appcontainer >/dev/null 2>&1 </dev/null && ! \"\$0\" run $SOFT sh -c \"echo x > '$work\\outside\\soft2'\" </dev/null 2>/dev/null" "$zigsaw"
check "  which override --global shows" global_shown
check "  the app's own overrides go over them" sh -c "\"\$0\" override --sandbox=soft $SOFT >/dev/null 2>&1 </dev/null && \"\$0\" run $SOFT sh -c \"echo x > '$work\\outside\\soft3'\" </dev/null" "$zigsaw"
check "  and the command line over those" fails writes $SOFT low "$work\\outside\\soft6"
"$zigsaw" override --reset $SOFT >/dev/null 2>&1 </dev/null
check "override --global --reset removes them" global_reset
check "the store-wide overrides' grants stand, and go when they no longer give them" global_grant_back
check "override takes an app or --global, not both" fails z override --global --sandbox=low $BB
"$zigsaw" rm $SOFT >/dev/null 2>&1 </dev/null

# --- AppContainer grants, and a low run after one ------------------------------

capability_in_run() {
    local out
    out=$(icacls_in $BB appcontainer "$1" --filesystem="$1") || { echo "$out"; return 1; }
    grep -q 'S-1-15-3-1024-' <<<"$out" && ! grep -q 'S-1-15-2-' <<<"$out"
}
ace_gone() { fails has_ace "$1" 'S-1-15-' && fails granted $BB "$1"; }
check "appcontainer: writes a granted path" writes $BB appcontainer "$work\\ac\\f" --filesystem="$work\\ac"
check "  granted to the app's capability while it runs, not its package SID" capability_in_run "$work\\ac"
check "  and revoked when the run ends" ace_gone "$work\\ac"
check "low after appcontainer: runs, and reads what that run wrote" z run --sandbox=low --filesystem="$work\\ac" $BB cat "$work\\ac\\f"
check "appcontainer: can't write elsewhere" fails writes $BB appcontainer "$work\\outside\\f"

# --- A file a run is to open (--file) ---------------------------------------------

mkdir -p "$work\\docs"
for f in soft low ac sibling held; do echo old >"$work\\docs\\$f.txt"; done
# rewrites <sandbox> <file>: the app gets the file as its last argument, and
# reads and writes it.
rewrites() {
    z run --sandbox="$1" --file="$2" $BB sh -c 'grep -q old "$1" && echo new > "$1"' sh && grep -q new "$2"
}
file_low() { label_of "$1" | grep -q 'Low Mandatory Level:(NW)'; }
# Inside the run, which gets the file as $3: it alone is labelled.
alone_labelled_in_run() {
    z run --sandbox=low --file="$work\\docs\\low.txt" $BB sh -c '
        icacls "$3" | grep -q "Low Mandatory Level:(NW)" && ! icacls "$1" | grep -q "Mandatory Label" && ! icacls "$2" | grep -q "Mandatory Label"' \
        sh "$work\\docs" "$work\\docs\\sibling.txt"
}
check "soft: --file gives the app the file's path, to read and write" rewrites soft "$work\\docs\\soft.txt"
relative_file() {
    local got
    got=$(cd "$work\\docs" && z run --sandbox=soft --file=soft.txt $BB sh -c 'echo "$1"' sh | tr -d '\r' | tr '/' '\\')
    [ "$got" = "$work\\docs\\soft.txt" ] || { echo "$got"; return 1; }
}
check "  a relative one is the caller's, whatever the app's working directory" relative_file
check "low: --file lets the app write that file" rewrites low "$work\\docs\\low.txt"
check "  which alone is labelled low while it runs" alone_labelled_in_run
check "  and isn't after it, nor recorded" label_gone "$work\\docs\\low.txt"
check "  the file next to it stays out of reach" fails writes $BB low "$work\\docs\\sibling.txt" --file="$work\\docs\\low.txt"
check "appcontainer: --file lets the app read and write that file" rewrites appcontainer "$work\\docs\\ac.txt"
check "  and revoked when the run ends" ace_gone "$work\\docs\\ac.txt"
check "  the file next to it stays out of reach" fails z run --sandbox=appcontainer --file="$work\\docs\\ac.txt" $BB cat "$work\\docs\\sibling.txt"
check "--file needs a file that exists" sh -c "\"\$0\" run --file='$work\\docs\\none.txt' $BB true 2>&1 | grep -q 'no such file'" "$zigsaw"
check "  and not a directory" sh -c "\"\$0\" run --file='$work\\docs' $BB true 2>&1 | grep -q 'is a directory; --filesystem='" "$zigsaw"
check "override doesn't take --file" sh -c "\"\$0\" override --file=x $BB 2>&1 | grep -q \"can't be saved as an override\"" "$zigsaw"

# --- While another run of the app goes on --------------------------------------
#
# The last run of an app to end takes back what its runs' command lines
# asked for: a second run that hands a file to the first, as Text Editor's
# does, leaves the first able to open it.

held_keeps_file() {
    hold "$work" $BB --sandbox=soft || return 1
    rewrites low "$work\\docs\\held.txt" && file_low "$work\\docs\\held.txt"
    local status=$?
    release
    return $status
}
killed_leaves() {
    hold "$work\\rw" $BB --sandbox=low --filesystem="$work\\rw" || return 1
    kill -9 $held
    touch "$work\\rw\\stop"
    wait $held 2>/dev/null
    low_label "$work\\rw" && granted $BB "low $work\\rw"
}
check "a --file grant stays after its run while another run of the app goes on" held_keeps_file
check "  and goes when that one ends" label_gone "$work\\docs\\held.txt"
check "a killed run leaves what it was granted" killed_leaves
check "  which the app's next run takes back when it ends" sh -c "\"\$0\" run $BB true </dev/null && $(declare -f label_of no_label fails granted label_gone); BB=$BB; ZIGSAW_HOME='$ZIGSAW_HOME'; label_gone '$work\\rw'" "$zigsaw"

# --- What stands --------------------------------------------------------------
#
# A third app, with overrides saved: what a run with nothing on its command
# line would be granted stays, until the overrides no longer give it.

STAND=test.sandbox.standing
sed "s/\"net.frippery.busybox\"/\"$STAND\"/" "$root/recipes/busybox.json" >"$work\\standing.json"
"$zigsaw" build "$work\\standing.json" >/dev/null 2>&1 || { echo "building the third app failed"; exit 1; }
mkdir -p "$work\\keep" "$work\\c1" "$work\\c2"
"$zigsaw" override --sandbox=low --filesystem="$work\\keep" $STAND >/dev/null 2>&1

second_run_quiet() {
    local out
    out=$("$zigsaw" run $STAND true 2>&1 </dev/null) || { echo "$out"; return 1; }
    ! grep -q labelled <<<"$out" || { echo "$out"; return 1; }
}
nofilesystem_now() {
    local out
    out=$("$zigsaw" override --nofilesystem="$work\\keep" $STAND 2>&1 </dev/null)
    grep -q 'removed the low integrity label' <<<"$out" || { echo "$out"; return 1; }
    no_label "$work\\keep" && fails granted $STAND "low $work\\keep"
}
reset_while_running() {
    "$zigsaw" override --sandbox=low --filesystem="$work\\keep" $STAND >/dev/null 2>&1 && z run $STAND true && low_label "$work\\keep" || return 1
    hold "$work\\keep" $STAND || return 1
    local out
    out=$("$zigsaw" override --reset $STAND 2>&1 </dev/null)
    if ! grep -q "is running" <<<"$out" || ! low_label "$work\\keep"; then
        release
        echo "$out"
        return 1
    fi
    release
    no_label "$work\\keep" && fails granted $STAND "low $work\\keep"
}
to_appcontainer() {
    "$zigsaw" override --sandbox=low --filesystem="$work\\keep" $STAND >/dev/null 2>&1 && z run $STAND true && low_label "$work\\keep" || return 1
    "$zigsaw" override --sandbox=appcontainer $STAND >/dev/null 2>&1 && no_label "$work\\keep" || return 1
    z run $STAND true && has_ace "$work\\keep" 'S-1-15-3-1024-.*(F)' && granted $STAND "$work\\keep"
}
read_only_now() {
    local out
    out=$("$zigsaw" override --filesystem="$work\\keep:ro" $STAND 2>&1 </dev/null)
    grep -q "write access to" <<<"$out" || { echo "$out"; return 1; }
    fails writes $STAND appcontainer "$work\\keep\\g" && z run $STAND ls "$work\\keep" >/dev/null &&
        has_ace "$work\\keep" 'S-1-15-3-1024-.*(RX)' && fails has_ace "$work\\keep" 'S-1-15-3-1024-.*(F)'
}
check "an override's path is written by a low run" writes $STAND low "$work\\keep\\f"
check "  and stays labelled after it, recorded" sh -c "$(declare -f label_of low_label granted); ZIGSAW_HOME='$ZIGSAW_HOME'; low_label '$work\\keep' && granted $STAND 'low $work\\keep'"
check "  so the next run doesn't label it again" second_run_quiet
check "override --nofilesystem takes it back at once" nofilesystem_now
check "override --reset while a run goes on takes it back when that run ends" reset_while_running
check "an override's other sandbox takes the label back, and its runs grant access instead" to_appcontainer
check "  and making the path read-only takes back write access" read_only_now

in_dir() {
    local d=$1
    shift
    (cd "$d" && "$zigsaw" "$@" </dev/null)
}
listed_cwd() { grep -qxF "$1" "$ZIGSAW_HOME\\grants\\$STAND.cwd"; }
two_cwds() {
    "$zigsaw" override --reset $STAND >/dev/null 2>&1 && "$zigsaw" override --sandbox=low --filesystem=cwd $STAND >/dev/null 2>&1 || return 1
    in_dir "$work\\c1" run $STAND sh -c 'echo x > f' && in_dir "$work\\c2" run $STAND sh -c 'echo x > f' || return 1
    low_label "$work\\c1" && low_label "$work\\c2" || { echo "not labelled: $(icacls "$work\\c1" "$work\\c2" | tr -d '\r' | tr '\n' ' ')"; return 1; }
    listed_cwd "$work\\c1" && listed_cwd "$work\\c2" || { echo "listed: $(tr '\n' '|' <"$ZIGSAW_HOME\\grants\\$STAND.cwd")"; return 1; }
}
nocwd() {
    "$zigsaw" override --nofilesystem=cwd $STAND >/dev/null 2>&1 && no_label "$work\\c1" && no_label "$work\\c2" &&
        [ ! -e "$ZIGSAW_HOME\\grants\\$STAND.cwd" ]
}
cmdline_cwd() {
    "$zigsaw" override --reset $STAND >/dev/null 2>&1 && in_dir "$work\\c1" run --sandbox=low --filesystem=cwd $STAND sh -c 'echo y > f' &&
        no_label "$work\\c1" && [ ! -e "$ZIGSAW_HOME\\grants\\$STAND.cwd" ]
}
check "cwd: each working directory of a low override's runs stays labelled" two_cwds
check "  until override --nofilesystem=cwd takes them all back" nocwd
check "cwd: one a command-line --filesystem=cwd grants goes after its run" cmdline_cwd
"$zigsaw" rm $STAND >/dev/null 2>&1 </dev/null

# --- The user's folders (--filesystem=documents) -------------------------------
#
# Fake folders: ZIGSAW_USER_FOLDERS has zigsaw take <dir>\Documents and so on
# for the user's. A fourth app declares documents, and a permission of a later
# zigsaw's.

FOLD=test.sandbox.folders
sed -e "s/\"net.frippery.busybox\"/\"$FOLD\"/" \
    -e 's/"command": "busybox.exe",/&\n  "permissions": { "filesystem": ["documents", "xdg-later"] },/' \
    "$root/recipes/busybox.json" >"$work\\folders.json"
"$zigsaw" build "$work\\folders.json" >/dev/null 2>&1 || { echo "building the folders app failed"; exit 1; }
folders="$work\\folders"
mkdir -p "$folders\\Documents" "$folders\\Downloads" "$folders\\Music"
echo mine >"$folders\\Documents\\mine.txt"
# Windows' own Documents holds hidden links that deny listing, as "My Music".
powershell -NoProfile -Command "New-Item -ItemType Junction -Path '$folders\\Documents\\My Music' -Target '$folders\\Music' | Out-Null; icacls '$folders\\Documents\\My Music' /deny 'Everyone:(RD)' | Out-Null"
export ZIGSAW_USER_FOLDERS="$folders"
home="$ZIGSAW_HOME\\data\\$FOLD\\home"
# Git Bash takes a junction for a symbolic link.
is_junction() { [ -L "$1" ]; }
folder_files_kept() { [ -f "$folders\\Documents\\mine.txt" ] && [ -f "$folders\\Music\\song.txt" ]; }
echo song >"$folders\\Music\\song.txt"
warns_unknown() { "$zigsaw" run $FOLD true 2>&1 </dev/null | grep -q 'xdg-later.*doesn.t know'; }
link_gone() { [ ! -e "$home\\Documents" ] && ! is_junction "$home\\Documents" && folder_files_kept; }
override_nofilesystem() {
    "$zigsaw" override --nofilesystem=documents $FOLD >/dev/null 2>&1 &&
        z run $FOLD sh -c '[ ! -e "$USERPROFILE/Documents" ]' &&
        z run --filesystem=documents:ro $FOLD sh -c '[ -f "$USERPROFILE/Documents/mine.txt" ]' &&
        "$zigsaw" override --reset $FOLD >/dev/null 2>&1
}
keeps_own_documents() {
    z run --nofilesystem=documents $FOLD true && mkdir "$home\\Documents" && echo own >"$home\\Documents\\own.txt" || return 1
    "$zigsaw" run $FOLD true 2>&1 </dev/null | grep -q 'kept .*own files' &&
        [ -f "$home\\Documents\\own.txt" ] && ! is_junction "$home\\Documents" && [ ! -e "$folders\\Documents\\own.txt" ]
}
reads_unlabelled() { z run --sandbox=low --filesystem=downloads:ro $FOLD ls "$folders\\Downloads" && no_label "$folders\\Downloads"; }
ephemeral_keeps_folder() { z run --ephemeral $FOLD sh -c 'grep -q mine "$USERPROFILE/Documents/mine.txt"' && folder_files_kept; }
folder_label_back() {
    "$zigsaw" override --nofilesystem=documents $FOLD >/dev/null 2>&1 &&
        no_label "$folders\\Documents" && fails granted $FOLD "low $folders\\Documents"
}
sed -e "s/\"net.frippery.busybox\"/\"$FOLD\"/" "$root/recipes/busybox.json" >"$work\\folders-none.json"
update_takes_back() {
    local out
    out=$("$zigsaw" build "$work\\folders-none.json" 2>&1 </dev/null)
    grep -q "revoked .* access to" <<<"$out" || { echo "$out"; return 1; }
    fails has_ace "$folders\\Documents" 'S-1-15-' && fails granted $FOLD "$folders\\Documents"
}

# Under soft, which store-wide overrides choose until the low rows.
"$zigsaw" override --global --sandbox=soft >/dev/null 2>&1
check "soft: an app's declared folder is linked into its home" z run $FOLD sh -c 'grep -q mine "$USERPROFILE/Documents/mine.txt"'
check "  as a junction" is_junction "$home\\Documents"
check "  a permission this zigsaw doesn't know is left out, with a warning" warns_unknown
check "  and no other folder" z run $FOLD sh -c '[ ! -e "$USERPROFILE/Downloads" ]'
check "--filesystem=downloads adds one" z run --filesystem=downloads $FOLD sh -c '[ -d "$USERPROFILE/Downloads" ]'
check "--nofilesystem=documents takes the app's away" z run --nofilesystem=documents $FOLD sh -c '[ ! -e "$USERPROFILE/Documents" ]'
check "  and its link, not what it pointed to" link_gone
check "override --nofilesystem too, until the command line grants it again" override_nofilesystem
check "a home Documents with the app's own files is kept" keeps_own_documents
is_junction "$home\\Documents" || rm -rf "$home\\Documents"
"$zigsaw" override --global --reset >/dev/null 2>&1
"$zigsaw" override --sandbox=low $FOLD >/dev/null 2>&1
check "low: writes the folder through the link" z run $FOLD sh -c 'echo x > "$USERPROFILE/Documents/low.txt"'
check "  which stays labelled low, as the app's overrides choose low" low_label "$folders\\Documents"
check "  recorded" granted $FOLD "low $folders\\Documents"
check "  a link in it labelled, not what that points to" no_label "$folders\\Music"
check "low: a read-only folder can't be written" fails z run --filesystem=downloads:ro $FOLD sh -c 'echo x > "$USERPROFILE/Downloads/ro.txt"'
check "  but is read, and isn't labelled" reads_unlabelled
check "override --nofilesystem=documents takes the label back" folder_label_back
"$zigsaw" override --reset $FOLD >/dev/null 2>&1
"$zigsaw" override --sandbox=appcontainer $FOLD >/dev/null 2>&1
check "appcontainer: reads and writes the folder through the link" z run $FOLD sh -c 'grep -q mine "$USERPROFILE/Documents/mine.txt" && echo x > "$USERPROFILE/Documents/ac.txt"'
check "  granted to the app's capability, which stays" has_ace "$folders\\Documents" 'S-1-15-3-1024-'
check "appcontainer: a folder it may not use stays out" fails z run $FOLD ls "$folders\\Downloads"
check "an update that no longer permits the folder takes the grant back" update_takes_back
"$zigsaw" build "$work\\folders.json" >/dev/null 2>&1 || { echo "building the folders app again failed"; exit 1; }
check "--ephemeral: linked too, and its data deleted without what the link pointed to" ephemeral_keeps_folder
rm_delete_data_keeps_folder() {
    "$zigsaw" rm --delete-data $FOLD >/dev/null 2>&1 </dev/null || return 1
    [ ! -e "$ZIGSAW_HOME\\data\\$FOLD" ] && folder_files_kept &&
        [ -f "$folders\\Documents\\low.txt" ] && [ -f "$folders\\Documents\\ac.txt" ]
}
check "rm --delete-data leaves the folder's files" rm_delete_data_keeps_folder
check "  and takes back its grant" sh -c "! icacls '$folders\\Documents' | grep -q -e 'Mandatory Label' -e 'S-1-15-'"
prune_data_keeps_folder() {
    "$zigsaw" build "$work\\folders.json" >/dev/null 2>&1 &&
        z run $FOLD true 2>/dev/null && is_junction "$home\\Documents" &&
        "$zigsaw" rm $FOLD >/dev/null 2>&1 </dev/null &&
        "$zigsaw" prune --data >/dev/null 2>&1 </dev/null || return 1
    [ ! -e "$ZIGSAW_HOME\\data\\$FOLD" ] && folder_files_kept
}
check "prune --data of a removed app's data leaves the folder's files" prune_data_keeps_folder
unset ZIGSAW_USER_FOLDERS

# --- Registry keys an app keeps (its config's "registry") --------------------------
#
# A fifth app keeps a test key, and a sixth the same one. Their runs set and
# read values with System32's reg.exe (--command=reg).

REG=test.sandbox.registry
REG2=test.sandbox.registry2
key="Software\\ZigsawTest\\sandbox-$$"
record="HKCU\\Software\\zigsaw\\keys\\Software/ZigsawTest/sandbox-$$"
for app in $REG $REG2; do
    sed -e "s/\"net.frippery.busybox\"/\"$app\"/" \
        -e "s/\"command\": \"busybox.exe\",/&\n  \"registry\": [\"Software\\\\\\\\ZigsawTest\\\\\\\\sandbox-$$\"],/" \
        "$root/recipes/busybox.json" >"$work\\$app.json"
    "$zigsaw" build "$work\\$app.json" >/dev/null 2>&1 || { echo "building $app failed"; exit 1; }
done
# sets <sandbox> <name> [run options...]: a run sets a value in the key.
sets() {
    local sb=$1 name=$2
    shift 2
    z run --sandbox="$sb" "$@" --command=reg $REG add "HKCU\\$key" /v "$name" /d "$sb" /f
}
# has <sandbox> <name> [run options...]: a run finds the value.
has() {
    local sb=$1 name=$2
    shift 2
    z run --sandbox="$sb" "$@" --command=reg $REG query "HKCU\\$key" /v "$name"
}
not_in_hkcu() { ! reg query "HKCU\\$key" >/dev/null 2>&1 && ! reg query "$record" >/dev/null 2>&1; }
in_order() {
    sets soft a && has low a && sets low b && has appcontainer b && sets appcontainer c && has soft c
}
ephemeral_starts_empty() { fails has soft a --ephemeral && sets soft e --ephemeral && fails has soft e && has soft a; }
moved_aside() {
    reg add "HKCU\\$key" /v native /d 1 /f >/dev/null || return 1
    fails has soft native && has soft a || { reg delete "HKCU\\$key" /f >/dev/null 2>&1; return 1; }
    reg query "HKCU\\$key" /v native >/dev/null && ! reg query "HKCU\\$key" /v a >/dev/null 2>&1
    local status=$?
    reg delete "HKCU\\$key" /f >/dev/null 2>&1
    return $status
}
# Runs `sleep` in the app in the background, and waits until its run has put
# the key in HKCU; its PID in $runner.
start_sleeping() {
    "$zigsaw" run "$1" sleep 60 </dev/null >/dev/null 2>&1 &
    runner=$!
    local i
    for i in $(seq 50); do reg query "$record" >/dev/null 2>&1 && return 0; sleep 0.2; done
    return 1
}
killed_run() {
    start_sleeping $REG || return 1
    # Set as the app would, while its run goes on.
    reg add "HKCU\\$key" /v killed /d 1 /f >/dev/null
    kill -9 $runner
    wait $runner 2>/dev/null
    reg query "$record" >/dev/null 2>&1 || { echo "the record went with the run"; return 1; }
    has soft killed && not_in_hkcu
}
other_app_waits() {
    start_sleeping $REG || return 1
    local out
    out=$(z run --command=reg $REG2 query "HKCU\\$key" 2>&1)
    local status=$?
    kill -9 $runner
    wait $runner 2>/dev/null
    [ $status -ne 0 ] && grep -q "which a run of $REG is using" <<<"$out" || { echo "$out"; return 1; }
    # Its next run settles what the killed one left, into $REG's data.
    z run --command=reg $REG2 query "HKCU\\$key" >/dev/null 2>&1 && not_in_hkcu && has soft killed
}
rm_settles() {
    start_sleeping $REG || return 1
    kill -9 $runner
    wait $runner 2>/dev/null
    "$zigsaw" rm --delete-data $REG >/dev/null 2>&1 </dev/null && not_in_hkcu && [ ! -e "$ZIGSAW_HOME\\data\\$REG" ] && [ ! -e "$ZIGSAW_HOME\\data\\$REG.hkcu.lock" ]
}

check "registry: a value one run sets is there in the next, in each sandbox" in_order
check "  in a hive in the app's data" test -f "$ZIGSAW_HOME\\data\\$REG\\registry\\user.dat"
check "  and HKCU has neither the key nor zigsaw's record of it between runs" not_in_hkcu
check "--ephemeral: starts without the app's keys, and leaves them as they were" ephemeral_starts_empty
check "a key of the same name that was there is moved aside for the run, and back after" moved_aside
check "a run that didn't end leaves the key in HKCU, and the next one settles it" killed_run
check "another app keeping the same key can't run while that app's run uses it" other_app_waits
check "rm --delete-data settles what a run left, and leaves nothing in HKCU" rm_settles
"$zigsaw" rm --delete-data $REG2 >/dev/null 2>&1 </dev/null
reg delete "HKCU\\$key" /f >/dev/null 2>&1

# A seventh app keeps a key two levels below one that's there and empty, as
# Java apps keep theirs below an empty HKCU\Software\JavaSoft\Prefs: taking
# it back deletes the key its run made above it, not the one that was there.
REG3=test.sandbox.registry3
deep="Software\\ZigsawTest\\deep-$$"
sed -e "s/\"net.frippery.busybox\"/\"$REG3\"/" \
    -e "s/\"command\": \"busybox.exe\",/&\n  \"registry\": [\"Software\\\\\\\\ZigsawTest\\\\\\\\deep-$$\\\\\\\\made\\\\\\\\settings\"],/" \
    "$root/recipes/busybox.json" >"$work\\$REG3.json"
"$zigsaw" build "$work\\$REG3.json" >/dev/null 2>&1 || { echo "building $REG3 failed"; exit 1; }
only_what_it_made() {
    # Without values, as Java leaves Prefs: reg.exe would give it an empty
    # default value.
    powershell -NoProfile -Command "New-Item -Path 'HKCU:\\$deep' -Force | Out-Null" || return 1
    z run --command=reg $REG3 add "HKCU\\$deep\\made\\settings" /v x /d 1 /f || return 1
    reg query "HKCU\\$deep" >/dev/null 2>&1 || { echo "the key that was there went"; return 1; }
    ! reg query "HKCU\\$deep\\made" >/dev/null 2>&1 || { echo "the key its run made stayed"; return 1; }
    z run --command=reg $REG3 query "HKCU\\$deep\\made\\settings" /v x
}
check "taking a key back deletes the keys above it its run made, not an empty one that was there" only_what_it_made
"$zigsaw" rm --delete-data $REG3 >/dev/null 2>&1 </dev/null
reg delete "HKCU\\$deep" /f >/dev/null 2>&1


# --- Labels two apps share, labels zigsaw didn't make, and rm ---------------------
#
# Both apps' overrides choose low and name the same path, so its label
# stands for both.

for app in $BB $OTHER; do "$zigsaw" override --sandbox=low --filesystem="$work\\rw" $app >/dev/null 2>&1; done
"$zigsaw" override --filesystem="$work\\own" $BB >/dev/null 2>&1
both_write() { writes $BB low "$work\\rw\\g" && writes $OTHER low "$work\\rw\\h"; }
check "two apps whose overrides name the same path write it" both_write
check "  and share the label, recorded for both" sh -c "$(declare -f granted); ZIGSAW_HOME='$ZIGSAW_HOME'; granted $BB 'low $work\\rw' && granted $OTHER 'low $work\\rw'"
check "  the first writes a path only its overrides name" writes $BB low "$work\\own\\f"
icacls "$work\\mine" /setintegritylevel '(OI)(CI)low' >/dev/null
check "a path labelled low by hand is written" writes $BB low "$work\\mine\\f" --filesystem="$work\\mine"
check "  but not recorded" fails granted $BB "low $work\\mine"
check "  and keeps its label after the run" low_label "$work\\mine"

rm_keeps_shared() {
    local out
    out=$("$zigsaw" rm $BB 2>&1) || { echo "$out"; return 1; }
    grep -q "kept the low integrity label of $(sed 's/\\/\\\\/g' <<<"$work\\rw")" <<<"$out" || { echo "$out"; return 1; }
    low_label "$work\\rw"
}
check "rm keeps a label another app still needs" rm_keeps_shared
check "  removes its own labels" no_label "$work\\own"
check "  and what was below them inherited" sh -c "! icacls '$work\\own\\f' | grep -q 'Mandatory Label'"
check "  leaves a label it didn't make" low_label "$work\\mine"
check "the second app's rm removes the shared label" sh -c "\"\$0\" rm $OTHER >/dev/null 2>&1 && ! icacls '$work\\rw' | grep -q 'Mandatory Label'" "$zigsaw"

# --- Programs a run writes, and zigsaw's own folders ---------------------------
#
# Windows starts a program whose file is labelled low at low integrity, and
# what a run writes comes out labelled low: zigsaw takes the label off the
# programs once the app's runs end (src/written.zig). tests/hostprobe.zig is
# the program: it prints its integrity level.

PROG=test.sandbox.programs
sed "s/\"net.frippery.busybox\"/\"$PROG\"/" "$root/recipes/busybox.json" >"$work\\programs.json"
"$zigsaw" build "$work\\programs.json" >/dev/null 2>&1 || { echo "building the fourth app failed"; exit 1; }
mkdir -p "$work\\prog" "$work\\progac" "$work\\lowexe"
cp "$hostprobe" "$work\\prog\\src.bin" && cp "$hostprobe" "$work\\progac\\src.bin"
"$zigsaw" override --sandbox=low --filesystem="$work\\prog" $PROG >/dev/null 2>&1

# starts_at <level> <program>: its own integrity, and its label's.
starts_at() {
    local out
    out=$("$2" 2>&1 | tr -d '\r' | grep '^# integrity')
    [ "$out" = "# integrity $1" ] || { echo "$2: $out"; return 1; }
}
medium_program() { starts_at medium "$1" && icacls "$1" | grep -q 'Medium Mandatory Level:(NW)'; }
recorded_program() { grep -qxF "$2" "$ZIGSAW_HOME\\grants\\$1.programs"; }
writes_program() {
    local app=$1 to=$2
    shift 2
    z run "$@" $app sh -c "cp '$(dirname "$to")\\src.bin' '$to'" >/dev/null 2>&1
}
rewrites_in_place() {
    z run $PROG sh -c "cat '$work\\prog\\src.bin' > '$work\\prog\\p.exe'" && medium_program "$work\\prog\\p.exe"
}
held_stays_low() {
    hold "$work\\prog" $PROG || return 1
    writes_program $PROG "$work\\prog\\h.exe"
    if ! starts_at low "$work\\prog\\h.exe"; then
        release
        return 1
    fi
    release
    medium_program "$work\\prog\\h.exe"
}
rm_forgets() {
    "$zigsaw" rm $PROG >/dev/null 2>&1 </dev/null || return 1
    [ ! -e "$ZIGSAW_HOME\\grants\\$PROG.programs" ] && medium_program "$work\\prog\\p.exe"
}
store_parent=$(dirname "$ZIGSAW_HOME")
refuses_store() {
    local out
    out=$(writes $PROG "$1" "$store_parent\\zigsaw-sandbox-test" --filesystem="$store_parent" 2>&1) && return 1
    grep -q "zigsaw's store is in it" <<<"$out" || { echo "$out"; return 1; }
    [ ! -e "$store_parent\\zigsaw-sandbox-test" ] && no_label "$store_parent" && fails has_ace "$store_parent" 'S-1-15-3-'
}
in_store_read_only() {
    local d="$ZIGSAW_HOME\\cache" out
    out=$(from "$d" $PROG) && return 1
    grep -q "is read-only for this run, as it's in zigsaw's store: run the app from a folder elsewhere" <<<"$out" || { echo "$out"; return 1; }
    [ ! -e "$d\\zigsaw-sandbox-test" ] && no_label "$d"
}
warns_low_program() {
    icacls "$work\\lowexe" /setintegritylevel '(OI)(CI)L' >/dev/null && cp "$hostprobe" "$work\\lowexe\\probe.exe" || return 1
    local out
    out=$(z run --sandbox=soft --command="$work\\lowexe\\probe.exe" $PROG 2>&1)
    grep -q 'is labelled low integrity, so Windows starts it, and this run, at low integrity' <<<"$out" || { echo "$out"; return 1; }
}
low_writes() { writes_program $PROG "$work\\prog\\p.exe" && medium_program "$work\\prog\\p.exe"; }
soft_writes() { writes_program $PROG "$work\\prog\\s.exe" --sandbox=soft && medium_program "$work\\prog\\s.exe"; }
ac_writes() { writes_program $PROG "$work\\progac\\a.exe" --sandbox=appcontainer --filesystem="$work\\progac" && medium_program "$work\\progac\\a.exe"; }
check "low: a program a run writes where it may write starts at medium integrity after" low_writes
check "  recorded" recorded_program $PROG "$work\\prog\\p.exe"
check "  and the app's next low run rewrites it in place, and it's medium again" rewrites_in_place
check "soft: a program written in a folder a low run labelled starts at medium too" soft_writes
check "appcontainer: a program written in a granted path starts at medium too" ac_writes
check "while another run of the app goes on, a program stays low until that one ends" held_stays_low
check "low: from inside the store, the app runs with its working directory read-only" in_store_read_only
check "low: won't label a folder that holds the store" refuses_store low
check "appcontainer: won't let the app write a folder that holds the store" refuses_store appcontainer
check "soft: a run of a program labelled low says it starts at low integrity" warns_low_program

# The data directory: a low run labels it low, and what's written there
# inherits the label; a soft run takes it off first, and the next low run
# labels it again (src/run.zig, unlabelData). zig 0.17 builds its Maker there.
data="$ZIGSAW_HOME\\data\\$PROG"
# soft_starts <sh command>: a soft run of it, whose last program, started by
# the app, is the probe at medium integrity.
soft_starts() {
    local out
    out=$(z run --sandbox=soft $PROG sh -c "$1" 2>&1 | tr -d '\r' | grep '^# integrity')
    [ "$out" = "# integrity medium" ] || { echo "got \"$out\""; return 1; }
}
data_low_written() {
    z run $PROG sh -c "cp '$work\\prog\\src.bin' '$data\\d.exe'" >/dev/null 2>&1 || return 1
    soft_starts "'$data\\d.exe'"
}
data_soft_written() {
    z run $PROG sh -c true >/dev/null 2>&1 || return 1
    soft_starts "cp '$work\\prog\\src.bin' '$data\\s.exe' && '$data\\s.exe'"
}
data_relabelled() {
    z run $PROG sh -c "echo x > '$data\\again.txt'" >/dev/null 2>&1 || return 1
    icacls "$data" | grep -qF 'Low Mandatory Level:(OI)(CI)(NW)'
}
data_held() {
    hold "$work\\prog" $PROG || return 1
    local out
    out=$(z run --sandbox=soft $PROG sh -c true 2>&1)
    release
    grep -q "data folder stays labelled low integrity, as another run of it is going" <<<"$out" || { echo "$out"; return 1; }
    icacls "$data" | grep -qF 'Low Mandatory Level:(OI)(CI)(NW)'
}
check "soft: a program a low run wrote in the data folder starts at medium" data_low_written
check "soft: one the soft run writes there and starts itself, after a low run, too" data_soft_written
check "low: the next low run labels the data folder again and writes there" data_relabelled
check "while another run of the app goes on, a soft run keeps the data folder's label and says so" data_held
check "rm forgets the programs, which stay medium" rm_forgets

rm -rf "$ZIGSAW_HOME" "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
