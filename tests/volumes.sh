#!/usr/bin/env bash
# End-to-end checks for volumes (src/volumes.zig): named volumes, in the store
# and kept elsewhere, and folders of yours, mounted in an app's data directory
# as junctions; what each sandbox lets a run do with them, how long the
# junctions and grants last, an app's files moved into an empty volume, and
# `zigsaw volume`. Busybox apps.
#
#   tests/volumes.sh [path\to\zigsaw.exe]
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
# The record of what stores changed (src/ledger.zig): one of this run's own.
suite_key="Software\\ZigsawTest\\volumes-$$-grants"
export ZIGSAW_GRANTS_KEY="$suite_key"
trap 'reg delete "HKCU\\$suite_key" /f >/dev/null 2>&1' EXIT
# Folders that stand in for yours: no run here may label the real ones.
mkdir -p "$work\\folders\\Documents"
export ZIGSAW_USER_FOLDERS="$work\\folders"
if [ -n "${SEED_DOWNLOADS:-}" ]; then
    mkdir -p "$ZIGSAW_HOME\\cache\\downloads"
    cp -l "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/" 2>/dev/null ||
        cp -n "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/"
fi

BB=net.frippery.busybox
OTHER=test.volumes.other

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
vol() { printf '%s\\volumes\\%s' "$ZIGSAW_HOME" "$1"; }
data_of() { printf '%s\\data\\%s' "$ZIGSAW_HOME" "$1"; }
# writes <app> <sandbox> <path in its data> [run options...]: whether a run
# can create the file.
writes() {
    local app=$1 sb=$2 p=$3
    shift 3
    z run --sandbox="$sb" "$@" "$app" sh -c "echo x > \"\$USERPROFILE/../$p\""
}
# reads <app> <sandbox> <path in its data> <text> [run options...]
reads() {
    local app=$1 sb=$2 p=$3 text=$4
    shift 4
    [ "$(z run --sandbox="$sb" "$@" "$app" sh -c "cat \"\$USERPROFILE/../$p\"" | tr -d '\r')" = "$text" ]
}
label_of() { icacls "$1" | grep -o 'Mandatory Label\\[A-Za-z]* Mandatory Level:([A-Z()]*)'; }
low_label() { label_of "$1" | grep -q 'Low Mandatory Level:(OI)(CI)(NW)'; }
no_label() { ! label_of "$1"; }
has_ace() { icacls "$1" | grep -q "$2"; }
granted() { grep -qxF "$2" "$ZIGSAW_HOME\\grants\\$1.txt" 2>/dev/null; }
# A junction, as Git Bash sees one.
is_link() { [ -L "$(cygpath -u "$1")" ]; }
absent() { [ ! -e "$(cygpath -u "$1")" ] && ! is_link "$1"; }
says() { # <text> <command...>: the command succeeds, and says it
    local text=$1 out
    shift
    out=$("$@" 2>&1) || { echo "$out"; return 1; }
    grep -qF -- "$text" <<<"$out" || { echo "$out"; return 1; }
}
refuses() { # <text> <command...>: the command fails, and says why
    local text=$1 out
    shift
    out=$("$@" 2>&1) && { echo "succeeded: $out"; return 1; }
    grep -qF -- "$text" <<<"$out" || { echo "$out"; return 1; }
}
# hold <dir> <app> [run options...]: a run that goes on until `release`, which
# may write <dir>. Call `release` even if it fails: it may have started.
hold() {
    local dir=$1 app=$2
    shift 2
    rm -f "$dir\\started" "$dir\\stop"
    "$zigsaw" run --filesystem="$dir" "$@" "$app" sh -c "touch '$dir\\started'; while [ ! -f '$dir\\stop' ]; do sleep 0.2; done" </dev/null >/dev/null 2>&1 &
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

cd "$work" || exit 1
"$zigsaw" build "$root/recipes/busybox.json" >/dev/null 2>&1 || { echo "building busybox failed"; exit 1; }
sed "s/\"net.frippery.busybox\"/\"$OTHER\"/" "$root/recipes/busybox.json" >"$work\\other.json"
"$zigsaw" build "$work\\other.json" >/dev/null 2>&1 || { echo "building the second app failed"; exit 1; }
mkdir -p "$work\\hold" "$work\\bind"

# --- Named volumes, in each sandbox ----------------------------------------
#
# Given only on the command line, a mount lasts for the run: its junction and
# its grant go when it ends; the volume stays.

for sb in soft low appcontainer; do
    v="v-$sb"
    check "$sb: a run's --volume makes the volume, and writes it" says "created volume $v" writes $BB $sb state/f --volume=$v:state
    check "  the file is in the volume, in the store" test -f "$(vol $v)\\f"
    check "  the junction goes after the run" absent "$(data_of $BB)\\state"
    if [ $sb = low ]; then
        check "  and so do the volume's label, and its record" sh -c "$(declare -f label_of no_label granted); ZIGSAW_HOME='$ZIGSAW_HOME'; no_label '$(vol $v)' && ! granted $BB 'low $(vol $v)'"
    elif [ $sb = appcontainer ]; then
        check "  and so do the app's access, and its record" sh -c "$(declare -f has_ace granted); ZIGSAW_HOME='$ZIGSAW_HOME'; ! has_ace '$(vol $v)' 'S-1-15-3-' && ! granted $BB '$(vol $v)'"
    fi
    check "$sb: an --ephemeral run reads it" reads $BB $sb state/f x --ephemeral --volume=$v:state
    check "  and it outlives the run's data" test -f "$(vol $v)\\f"
    check "$sb: another app reads it, mounted read-only" reads $OTHER $sb shared/f x --volume=$v:shared:ro
    if [ $sb != soft ]; then
        check "  and can't write it" fails writes $OTHER $sb shared/g --volume=$v:shared:ro
    fi
done

# --- Saved mounts ----------------------------------------------------------

z override --volume=keep:state $BB >/dev/null 2>&1
check "a saved mount writes the volume" writes $BB low state/a
check "  its junction stays after the run" is_link "$(data_of $BB)\\state"
check "  and the volume's label, recorded" sh -c "$(declare -f label_of low_label granted); ZIGSAW_HOME='$ZIGSAW_HOME'; low_label '$(vol keep)' && granted $BB 'low $(vol keep)'"
check "  list shows it" says "--volume=keep:state" z list
deleted_keeps() {
    says "kept volume keep" z rm --delete-data $BB && test -f "$(vol keep)\\a" && absent "$(data_of $BB)" || return 1
    z build "$root/recipes/busybox.json" >/dev/null 2>&1 && z override --volume=keep:state $BB >/dev/null 2>&1 &&
        reads $BB low state/a x
}
check "rm --delete-data keeps the volume, which the app mounts again" deleted_keeps
novolume_takes_away() {
    z override --novolume=state $BB >/dev/null 2>&1 && absent "$(data_of $BB)\\state" && no_label "$(vol keep)" &&
        ! granted $BB "low $(vol keep)" && test -f "$(vol keep)\\a" && z override $BB | grep -q -- '--novolume=state'
}
check "--novolume takes the junction and the label away, not the files" novolume_takes_away

# --- An app's own files, moved into an empty volume ------------------------

z run $BB sh -c 'mkdir -p "$USERPROFILE/../db" && echo old > "$USERPROFILE/../db/x"' >/dev/null 2>&1
check "a run's --volume over the app's own files refuses" refuses "only on the command line" z run --volume=pop:db $BB true
check "  and leaves them" test -f "$(data_of $BB)\\db\\x"
moves_in() {
    z override --volume=pop:db $BB >/dev/null 2>&1 && says "moved $BB's files at db into volume pop" z run $BB true &&
        test -f "$(vol pop)\\x" && is_link "$(data_of $BB)\\db" && reads $BB low db/x old
}
check "a saved mount moves them into the empty volume" moves_in
moved_files_inherit() { ! icacls "$(vol pop)\\x" | grep -q 'S-1-15-'; }
check "  and the files moved take the volume's ACL" moved_files_inherit
z run $BB sh -c 'mkdir -p "$USERPROFILE/../db2" && echo mine > "$USERPROFILE/../db2/y"' >/dev/null 2>&1
z volume create full >/dev/null 2>&1 && echo theirs >"$(vol full)\\z"
z override --volume=full:db2 $BB >/dev/null 2>&1
check "  not into one that has files" refuses "the volume has files already" z run $BB true
check "  which both keep" sh -c "test -f '$(data_of $BB)\\db2\\y' && test -f '$(vol full)\\z'"
z override --novolume=db2 $BB >/dev/null 2>&1
left_link_goes() {
    # The first mount is made before the second refuses.
    z run --volume=r1:made --volume=r2:db2 $BB true >/dev/null 2>&1 && return 1
    is_link "$(data_of $BB)\\made" || return 1
    z run $BB true >/dev/null 2>&1 && absent "$(data_of $BB)\\made"
}
check "a mount a failed run left goes when the app's next run ends" left_link_goes

# --- Folders of yours ------------------------------------------------------

check "a folder of yours, mounted for a run" writes $BB low b/f --volume="$work\\bind:b"
check "  has the file" test -f "$work\\bind\\f"
check "  and is unlabelled, and unlinked, after it" sh -c "$(declare -f label_of no_label is_link absent); no_label '$work\\bind' && absent '$(data_of $BB)\\b'"
saved_bind() {
    z override --volume="$work\\bind:b" $BB >/dev/null 2>&1 && z run $BB true >/dev/null 2>&1 &&
        granted $BB "low $work\\bind" && z grants $BB | grep -qF "$work\\bind" || return 1
    z override --novolume=b $BB >/dev/null 2>&1 && no_label "$work\\bind" && ! granted $BB "low $work\\bind"
}
check "a saved one is a grant like --filesystem's, until --novolume" saved_bind
check "a folder that holds the store refuses" refuses "holds zigsaw's store" z run --volume="$(cygpath -w "$(dirname "$(cygpath -u "$ZIGSAW_HOME")")"):x" $BB true
check "a folder that isn't there refuses" refuses "there's no folder" z run --volume="$work\\missing:x" $BB true

# --- Checked before anything runs ------------------------------------------

check "mounts that overlap refuse" refuses "overlap" z run --volume=a1:x --volume=b1:x/y $BB true
check "a device's name refuses" refuses "Windows device" z run --volume=nul:x $BB true
check "zigsaw's own places refuse" refuses "zigsaw keeps registry" z override --volume=pg:registry $BB
check "  and the user's folders'" refuses "Documents" z override --volume=pg:home/Documents/x $BB
check "a relative folder refuses" refuses "absolute path" z run --volume='rel\dir:x' $BB true

# --- Kept elsewhere --------------------------------------------------------

check "volume create --path makes the folder" says "kept in $work\\ext" z volume create --path="$work\\ext" ext
check "  ls lists it there" sh -c "\"$zigsaw\" volume ls | grep -F ext | grep -qF '$work\\ext'"
z override --volume=ext:e $OTHER >/dev/null 2>&1
check "  a run writes it" writes $OTHER low e/f
check "  in the folder" test -f "$work\\ext\\f"
check "  ls says who mounts it" sh -c "\"$zigsaw\" volume ls | grep -F ext | grep -qF '$OTHER at e'"
check "  inspect says so too" says "$OTHER at e" z volume inspect ext
check "volume rm refuses one an override mounts" refuses "take that away first" z volume rm ext
z override --novolume=e $OTHER >/dev/null 2>&1
in_use() {
    local r=1
    hold "$work\\hold" $OTHER --volume=ext:e && refuses "in use" z volume rm ext && r=0
    release
    return $r
}
check "  or one a run uses" in_use
forgets() { says "its files stay in $work\\ext" z volume rm ext && test -f "$work\\ext\\f" && fails z volume inspect ext; }
check "  and forgets one kept elsewhere, leaving its files" forgets
check "create --path refuses the store" refuses "zigsaw's store" z volume create --path="$ZIGSAW_HOME\\x" inside
check "  and a drive's root" refuses "root of a drive" z volume create --path='C:\' rooty
check "  and a name taken" refuses "there's a volume keep already" z volume create keep

# --- Shared, under AppContainer --------------------------------------------

ac_takes_back() {
    z override --sandbox=appcontainer --volume=acv:s $OTHER >/dev/null 2>&1 && writes $OTHER appcontainer s/f &&
        has_ace "$(vol acv)" 'S-1-15-3-1024-' && granted $OTHER "$(vol acv)" || return 1
    z override --novolume=s $OTHER >/dev/null 2>&1 && fails has_ace "$(vol acv)" 'S-1-15-3-' && ! granted $OTHER "$(vol acv)"
}
check "an AppContainer's access to a volume goes when its app stops mounting it" ac_takes_back

# --- Pruning ---------------------------------------------------------------

check "zigsaw prune counts the volumes no override mounts" says "volume prune" z prune --dry-run
dry_prune() { z volume prune --dry-run 2>&1 | grep -q 'would remove volume v-low' && test -d "$(vol v-low)"; }
check "volume prune --dry-run removes nothing" dry_prune
prunes() {
    z volume prune >/dev/null 2>&1 && absent "$(vol v-low)" && absent "$(vol keep)" && test -d "$(vol pop)" && test -f "$(vol pop)\\x"
}
check "volume prune removes them, not one an override mounts" prunes

z rm $BB >/dev/null 2>&1
z rm $OTHER >/dev/null 2>&1
check "rm takes back what the runs were granted" sh -c "$(declare -f has_ace label_of no_label); no_label '$(vol pop)' && ! has_ace '$(vol pop)' 'S-1-15-'"
cd /
rm -rf "$(cygpath -u "$ZIGSAW_HOME")" "$(cygpath -u "$work")"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
