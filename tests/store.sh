#!/usr/bin/env bash
# End-to-end checks for `zigsaw update` and `zigsaw prune`: apps update from
# their recipe, replaced and removed versions are cleaned up, and nothing a
# running app uses is deleted.
#
#   tests/store.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and network access (for the busybox download). Always uses a
# temporary store, since it deletes things, and removes it afterwards.
# Updating from a registry is covered by tests/registry.sh.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")

BB=net.frippery.busybox

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

z() { "$zigsaw" "$@"; }
deployments() { find "$ZIGSAW_HOME/deploy" -mindepth 1 -maxdepth 1 -type d | wc -l; }
blobs() { find "$ZIGSAW_HOME/blobs/sha256" -type f | wc -l; }
expect_count() { local got; got=$("$1"); [ "$got" -eq "$2" ] || { echo "$1: got $got, want $2"; return 1; }; }

# A copy of the busybox recipe whose version the checks change. Each version
# also has a marker file saying which it is, so its files differ: deployments
# are per layer, and versions with the same files would share one.
recipe="$work\\busybox.json"
sed 's/"dest": "busybox.exe"/"dest": "busybox.exe" }, { "path": "marker.txt"/' "$root/recipes/busybox.json" >"$recipe"
echo original >"$work\\marker.txt"
# (A POSIX path: sed -i can't move its temporary file across drives.)
set_version() {
    sed -i "s/\"version\": \"[^\"]*\"/\"version\": \"$1\"/" "$(cygpath -u "$recipe")"
    echo "$1" >"$work\\marker.txt"
}
installed_version() { z list | awk -v id=$BB '$1 == id { print $2 }'; }
z build "$recipe" >/dev/null 2>&1 || { echo "building busybox failed"; exit 1; }

# --- update ------------------------------------------------------------------

up_to_date() { z update 2>&1 | grep -q "^$BB .*: up to date"; }
check "update: an unchanged recipe is up to date" up_to_date

changed_recipe() {
    set_version test-2
    z update $BB >/dev/null 2>&1 && [ "$(installed_version)" = test-2 ] && expect_count deployments 1
}
check "update: a changed recipe is rebuilt, the old version removed" changed_recipe
check "update: an unknown app fails" sh -c "! \"\$0\" update no.such.app" "$zigsaw"

# --- in-use protection ---------------------------------------------------------

# Starts `busybox sleep` on the installed version, in the background.
z run $BB sleep 6 &
running=$!
sleep 1
update_while_running() {
    set_version test-3
    z update $BB 2>&1 | grep -q 'still running' && [ "$(installed_version)" = test-3 ] && expect_count deployments 2
}
check "update: a running version's files are kept" update_while_running
prune_while_running() { z prune 2>&1 | grep -q 'kept 1 unused deployment' && expect_count deployments 2; }
check "prune: keeps a deployment in use" prune_while_running
# `check` runs commands in a subshell, which can't wait for this shell's jobs.
wait $running
status=$?
check "the running app finishes normally" test $status -eq 0

# The earlier prune already removed the running version's blobs: only its
# files were in use.
dry_run() { z prune --dry-run 2>&1 | grep -q '^would remove 1 deployment' && expect_count deployments 2 && expect_count blobs 3; }
check "prune --dry-run deletes nothing" dry_run
prune_after_exit() { z prune >/dev/null 2>&1 && expect_count deployments 1 && expect_count blobs 3; }
check "prune: removes it once unused" prune_after_exit

# --- tmp\ ----------------------------------------------------------------------

z run --ephemeral $BB sh -c 'echo x > "$APPDATA/f" && sleep 5' &
ephemeral=$!
sleep 1
mkdir "$ZIGSAW_HOME\\tmp\\stale-dir" && echo x >"$ZIGSAW_HOME\\tmp\\stale-dir\\f" && echo x >"$ZIGSAW_HOME\\tmp\\stale-file"
run_dirs() { find "$ZIGSAW_HOME/tmp" -mindepth 1 -maxdepth 1 -name 'run-*' | wc -l; }
prune_tmp() {
    z prune 2>&1 | grep -q 'kept the data of 1 running --ephemeral app' &&
        [ ! -e "$ZIGSAW_HOME\\tmp\\stale-dir" ] && [ ! -e "$ZIGSAW_HOME\\tmp\\stale-file" ] &&
        expect_count run_dirs 2 # The directory and its lock.
}
check "prune: clears tmp\\ but keeps a running --ephemeral app's data" prune_tmp
wait $ephemeral
status=$?
ephemeral_done() { [ $status -eq 0 ] && expect_count run_dirs 0; }
check "the --ephemeral run cleans up after itself" ephemeral_done

# --- rm, orphaned data and downloads ---------------------------------------------

z run $BB sleep 5 &
running=$!
sleep 1
rm_while_running() { z rm $BB 2>&1 | grep -q 'still in use' && expect_count deployments 1; }
check "rm: keeps the files of a running app" rm_while_running
wait $running
orphaned_data() { z prune 2>&1 | grep -q "kept data of apps that aren't installed: $BB" && expect_count deployments 0; }
check "prune: removes them afterwards, and lists orphaned data" orphaned_data
check "prune --data deletes it" sh -c "\"\$0\" prune --data >/dev/null 2>&1 && [ ! -e '$ZIGSAW_HOME\\data\\$BB' ]" "$zigsaw"
downloads() { find "$ZIGSAW_HOME/cache/downloads" -type f | wc -l; }
prune_downloads() { z prune --downloads >/dev/null 2>&1 && expect_count downloads 0; }
check "prune --downloads clears the download cache" prune_downloads

# --- the store lock --------------------------------------------------------------

# Holds the store lock (the byte Zig's file locks use) for 3 seconds.
powershell -NoProfile -Command "\$f = [IO.File]::Open('$ZIGSAW_HOME\\lock', 'OpenOrCreate', 'ReadWrite', 'ReadWrite'); \$f.Lock(0, 1); 'locked'; Start-Sleep 3; \$f.Close()" >"$work\\held" &
holder=$!
until grep -q locked "$work\\held" 2>/dev/null; do sleep 0.2; done
waits_for_lock() {
    local start=$SECONDS out
    out=$(z prune 2>&1) && grep -q 'waiting for another zigsaw' <<<"$out" && [ $((SECONDS - start)) -ge 1 ]
}
check "prune waits for the store lock" waits_for_lock
wait $holder

z prune --downloads --data >/dev/null 2>&1
rm -rf "$ZIGSAW_HOME" "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
