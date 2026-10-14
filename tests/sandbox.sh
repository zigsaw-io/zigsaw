#!/usr/bin/env bash
# End-to-end checks for what the enforcing sandboxes change on the host, and
# what `zigsaw rm` undoes: low integrity labels on the paths a --sandbox=low
# run may write, access granted to an app's AppContainer, and what each lets
# a run write. Two busybox apps; tests/matrix.sh runs real tools.
#
#   tests/sandbox.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and network access (for the busybox download, unless
# SEED_DOWNLOADS has it). Always uses a temporary store, and removes it, and
# the AppContainer profiles it made, afterwards.

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

"$zigsaw" build "$root/recipes/busybox.json" >/dev/null 2>&1 || { echo "building busybox failed"; exit 1; }
sed "s/\"net.frippery.busybox\"/\"$OTHER\"/" "$root/recipes/busybox.json" >"$work\\other.json"
"$zigsaw" build "$work\\other.json" >/dev/null 2>&1 || { echo "building the second app failed"; exit 1; }

mkdir -p "$work\\rw" "$work\\ro" "$work\\outside" "$work\\cwd" "$work\\ac" "$work\\mine"
echo secret >"$work\\outside\\secret.txt"

# --- What a low run can write ------------------------------------------------

check "low: writes its data directory" z run --sandbox=low $BB sh -c 'echo x > "$APPDATA/f"'
check "low: writes a path it may write" writes $BB low "$work\\rw\\f" --filesystem="$work\\rw"
check "  which is labelled low, for everything in it" low_label "$work\\rw"
check "  and recorded for rm" granted $BB "low $work\\rw"
check "  what it wrote inherits the label" sh -c "icacls '$work\\rw\\f' | grep -q 'Low Mandatory Level:(I)(NW)'"
check "low: can't write a read-only grant" fails writes $BB low "$work\\ro\\f" --filesystem="$work\\ro:ro"
check "  which isn't labelled" no_label "$work\\ro"
check "low: can't write elsewhere" fails writes $BB low "$work\\outside\\f"
check "low: reads elsewhere (not enforced)" z run --sandbox=low $BB cat "$work\\outside\\secret.txt"
check "low: writes cwd with the cwd permission" sh -c "cd '$work\\cwd' && \"\$0\" run --sandbox=low --filesystem=cwd $BB sh -c 'echo x > \"\$1\"' sh '$work\\cwd\\f' </dev/null" "$zigsaw"
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
    modify_fixture=false
else
    modify_fixture=true
    check "low: writes a path that withholds WRITE_OWNER" writes $BB low "$work\\modify\\rw\\f" --filesystem="$work\\modify\\rw"
    check "  which is labelled low" low_label "$work\\modify\\rw"
    check "  with its ACL as it was" sh -c "[ \"\$(icacls '$work\\modify\\rw' | grep -v -e '^Successfully' -e 'Mandatory Label')\" = \"\$0\" ]" "$acl_before"
fi

# --- AppContainer grants, and a low run after one ------------------------------

check "appcontainer: writes a granted path" writes $BB appcontainer "$work\\ac\\f" --filesystem="$work\\ac"
check "  granted to the app's capability, not its package SID" sh -c "icacls '$work\\ac' | grep -q 'S-1-15-3-1024-' && ! icacls '$work\\ac' | grep -q 'S-1-15-2-'"
check "  and recorded for rm" granted $BB "$work\\ac"
check "low after appcontainer: runs, and reads what that run wrote" z run --sandbox=low --filesystem="$work\\ac" $BB cat "$work\\ac\\f"
check "appcontainer: can't write elsewhere" fails writes $BB appcontainer "$work\\outside\\f"

# --- A file a run is to open (--file) ---------------------------------------------

mkdir -p "$work\\docs"
for f in soft low ac sibling; do echo old >"$work\\docs\\$f.txt"; done
# rewrites <sandbox> <file>: the app gets the file as its last argument, and
# reads and writes it.
rewrites() {
    z run --sandbox="$1" --file="$2" $BB sh -c 'grep -q old "$1" && echo new > "$1"' sh && grep -q new "$2"
}
file_low() { label_of "$1" | grep -q 'Low Mandatory Level:(NW)'; }
check "soft: --file gives the app the file's path, to read and write" rewrites soft "$work\\docs\\soft.txt"
relative_file() {
    local got
    got=$(cd "$work\\docs" && z run --file=soft.txt $BB sh -c 'echo "$1"' sh | tr -d '\r' | tr '/' '\\')
    [ "$got" = "$work\\docs\\soft.txt" ] || { echo "$got"; return 1; }
}
check "  a relative one is the caller's, whatever the app's working directory" relative_file
check "low: --file lets the app write that file" rewrites low "$work\\docs\\low.txt"
check "  which alone is labelled low" sh -c "$(declare -f label_of file_low no_label); file_low '$work\\docs\\low.txt' && no_label '$work\\docs' && no_label '$work\\docs\\sibling.txt'"
check "  and recorded for rm" granted $BB "low $work\\docs\\low.txt"
check "  the file next to it stays out of reach" fails writes $BB low "$work\\docs\\sibling.txt" --file="$work\\docs\\low.txt"
check "appcontainer: --file lets the app read and write that file" rewrites appcontainer "$work\\docs\\ac.txt"
check "  recorded for rm" granted $BB "$work\\docs\\ac.txt"
check "  the file next to it stays out of reach" fails z run --sandbox=appcontainer --file="$work\\docs\\ac.txt" $BB cat "$work\\docs\\sibling.txt"
check "--file needs a file that exists" sh -c "\"\$0\" run --file='$work\\docs\\none.txt' $BB true 2>&1 | grep -q 'no such file'" "$zigsaw"
check "  and not a directory" sh -c "\"\$0\" run --file='$work\\docs' $BB true 2>&1 | grep -q 'is a directory; --filesystem='" "$zigsaw"
check "override doesn't take --file" sh -c "\"\$0\" override --file=x $BB 2>&1 | grep -q \"can't be saved as an override\"" "$zigsaw"

# --- The user's folders (--filesystem=documents) -------------------------------
#
# Fake folders: ZIGSAW_USER_FOLDERS has zigsaw take <dir>\Documents and so on
# for the user's. A third app declares documents, and a permission of a later
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
check "low: writes the folder through the link" z run --sandbox=low $FOLD sh -c 'echo x > "$USERPROFILE/Documents/low.txt"'
check "  which is labelled low" low_label "$folders\\Documents"
check "  and recorded for rm" granted $FOLD "low $folders\\Documents"
check "  a link in it labelled, not what that points to" no_label "$folders\\Music"
check "low: a read-only folder can't be written" fails z run --sandbox=low --filesystem=downloads:ro $FOLD sh -c 'echo x > "$USERPROFILE/Downloads/ro.txt"'
check "  but is read, and isn't labelled" reads_unlabelled
check "appcontainer: reads and writes the folder through the link" z run --sandbox=appcontainer $FOLD sh -c 'grep -q mine "$USERPROFILE/Documents/mine.txt" && echo x > "$USERPROFILE/Documents/ac.txt"'
check "  granted to the app's capability" has_ace "$folders\\Documents" 'S-1-15-3-1024-'
check "appcontainer: a folder it may not use stays out" fails z run --sandbox=appcontainer $FOLD ls "$folders\\Downloads"
check "--ephemeral: linked too, and its data deleted without what the link pointed to" ephemeral_keeps_folder
rm_delete_data_keeps_folder() {
    "$zigsaw" rm --delete-data $FOLD >/dev/null 2>&1 </dev/null || return 1
    [ ! -e "$ZIGSAW_HOME\\data\\$FOLD" ] && folder_files_kept &&
        [ -f "$folders\\Documents\\low.txt" ] && [ -f "$folders\\Documents\\ac.txt" ]
}
check "rm --delete-data leaves the folder's files" rm_delete_data_keeps_folder
check "  and takes back its label and grant" sh -c "! icacls '$folders\\Documents' | grep -q -e 'Mandatory Label' -e 'S-1-15-'"
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
# A fourth app keeps a test key, and a fifth the same one. Their runs set and
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

# --- Labels two apps share, labels zigsaw didn't make, and rm ---------------------

check "a second app's low run writes the same path" writes $OTHER low "$work\\rw\\g" --filesystem="$work\\rw"
check "  and shares the label, recorded for both" granted $OTHER "low $work\\rw"
icacls "$work\\mine" /setintegritylevel '(OI)(CI)low' >/dev/null
check "a path labelled low by hand is written" writes $BB low "$work\\mine\\f" --filesystem="$work\\mine"
check "  but not recorded" fails granted $BB "low $work\\mine"

rm_keeps_shared() {
    local out
    out=$("$zigsaw" rm $BB 2>&1) || { echo "$out"; return 1; }
    grep -q "kept the low integrity label of $(sed 's/\\/\\\\/g' <<<"$work\\rw")" <<<"$out" || { echo "$out"; return 1; }
    low_label "$work\\rw"
}
check "rm keeps a label another app still needs" rm_keeps_shared
check "  removes its own labels" no_label "$work\\cwd"
check "  and what was below them inherited" sh -c "! icacls '$work\\cwd\\f' | grep -q 'Mandatory Label'"
check "  revokes its AppContainer grants" sh -c "! icacls '$work\\ac' | grep -q 'S-1-15-'"
check "  and those of the files it opened" sh -c "! icacls '$work\\docs\\low.txt' '$work\\docs\\ac.txt' | grep -q -e 'Mandatory Label' -e 'S-1-15-'"
check "  leaves a label it didn't make" low_label "$work\\mine"
if $modify_fixture; then
    check "  removes the label of a path that withholds WRITE_OWNER" no_label "$work\\modify\\rw"
    check "  with its ACL as it was" sh -c "[ \"\$(icacls '$work\\modify\\rw' | grep -v '^Successfully')\" = \"\$0\" ]" "$acl_before"
fi
check "the second app's rm removes the shared label" sh -c "\"\$0\" rm $OTHER >/dev/null 2>&1 && ! icacls '$work\\rw' | grep -q 'Mandatory Label'" "$zigsaw"

rm -rf "$ZIGSAW_HOME" "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
