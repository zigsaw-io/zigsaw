#!/usr/bin/env bash
# End-to-end checks for `zigsaw update` and `zigsaw uninstall --unused`: apps update from
# their recipe, replaced and removed versions are cleaned up, and nothing a
# running app uses is deleted.
#
#   tests/store.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and network access (for the busybox download, unless
# SEED_DOWNLOADS has it). Always uses a temporary store, since it deletes
# things, and removes it afterwards.
# Updating from a registry is covered by tests/registry.sh.

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
says() { # <text> <command...>: the command's output, either stream, has the text
    local text=$1 out
    shift
    out=$("$@" 2>&1)
    grep -qF -- "$text" <<<"$out" || { echo "$out"; return 1; }
}
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

# --- Flatpak's names (0.105) -----------------------------------------------------

installed_info() {
    local out
    out=$(z info $BB 2>&1) || { echo "$out"; return 1; }
    grep -q "^$BB test-2" <<<"$out" &&
        grep -qF "origin     $recipe" <<<"$out" &&
        grep -qF "location   $ZIGSAW_HOME\\deploy\\" <<<"$out" &&
        grep -qF "data       $ZIGSAW_HOME\\volumes\\$BB" <<<"$out" &&
        ! grep -q '^  download' <<<"$out" || { echo "$out"; return 1; }
}
check "info shows an installed app, where it came from and where it is" installed_info
check "info of an app that isn't installed points at remote-info" says "isn't installed; \`zigsaw remote-info no.such.app\`" z info no.such.app
check "info of an image reference points at remote-info" says "\`zigsaw remote-info ghcr.io/a/b\`" z info ghcr.io/a/b
moved() { # <old command...> -- <what it says it is now>
    local args=() out
    while [ "$1" != -- ]; do args+=("$1"); shift; done
    out=$(z "${args[@]}" 2>&1) && { echo "it worked: $out"; return 1; }
    grep -qF "\`zigsaw ${args[0]}\` is \`zigsaw $2\` since zigsaw 0.105" <<<"$out" || { echo "$out"; return 1; }
}
check "pull fails, pointing at install" moved pull $BB -- install
check "rm fails, pointing at uninstall, and uninstalls nothing" moved rm $BB -- uninstall
check "  (still installed)" test "$(installed_version)" = test-2
check "prune fails, pointing at uninstall --unused" moved prune -- "uninstall --unused"
check "exec, stop, hold point at enter, kill, mask" sh -c 'for a in "exec enter" "stop kill" "hold mask"; do set -- $a; "$0" $1 x 2>&1 | grep -qF "is \`zigsaw $2\`" || exit 1; done' "$zigsaw"
check "grants --take-back points at permission-remove" moved grants --take-back 'C:\x' -- permission-remove
check "push --catalog points at build-update-repo" moved push --catalog $BB -- build-update-repo
check "signature check points at build-sign --check" moved signature check $BB -- "build-sign --check"
check "uninstall takes no --unused options without --unused" says "usage:" z uninstall --dry-run $BB
check "uninstall --unused takes no app" says "usage:" z uninstall --unused $BB
check "kill --now takes no --time" says "usage:" z kill --now --time=1 $BB
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
prune_while_running() { z uninstall --unused 2>&1 | grep -q 'kept 1 unused deployment' && expect_count deployments 2; }
check "prune: keeps a deployment in use" prune_while_running
# `check` runs commands in a subshell, which can't wait for this shell's jobs.
wait $running
status=$?
check "the running app finishes normally" test $status -eq 0

# The running version is the one test-3 replaced, so its blobs stay, for
# `rollback`; the earlier prune removed those of the first version. Only its
# files were in use, and they go.
dry_run() { z uninstall --unused --dry-run 2>&1 | grep -q '^would remove 1 deployment' && expect_count deployments 2 && expect_count blobs 6; }
check "prune --dry-run deletes nothing" dry_run
prune_after_exit() { z uninstall --unused >/dev/null 2>&1 && expect_count deployments 1 && expect_count blobs 6; }
check "prune: removes it once unused, and keeps the previous version's blobs" prune_after_exit
prune_previous() { z uninstall --unused --previous 2>&1 | grep -q 'forgot 1 previous version' && expect_count deployments 1 && expect_count blobs 3; }
check "prune --previous: removes those too" prune_previous

# --- tmp\ ----------------------------------------------------------------------

z run --ephemeral $BB sh -c 'echo x > "$APPDATA/f" && sleep 5' &
ephemeral=$!
sleep 1
mkdir "$ZIGSAW_HOME\\tmp\\stale-dir" && echo x >"$ZIGSAW_HOME\\tmp\\stale-dir\\f" && echo x >"$ZIGSAW_HOME\\tmp\\stale-file"
run_dirs() { find "$ZIGSAW_HOME/tmp" -mindepth 1 -maxdepth 1 -name 'run-*' | wc -l; }
prune_tmp() {
    z uninstall --unused 2>&1 | grep -q 'kept the data of 1 running --ephemeral app' &&
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
rm_while_running() { z uninstall $BB 2>&1 | grep -q 'still in use' && expect_count deployments 1; }
check "rm: keeps the files of a running app" rm_while_running
wait $running
orphaned_data() { z uninstall --unused 2>&1 | grep -q "volume(s) that nothing mounts: $BB (" && expect_count deployments 0; }
check "prune: removes them afterwards, and names the removed app's own volume, its data" orphaned_data
check "prune --volumes deletes it" sh -c "\"\$0\" uninstall --unused --volumes >/dev/null 2>&1 && [ ! -e '$ZIGSAW_HOME\\volumes\\$BB' ]" "$zigsaw"
downloads() { find "$ZIGSAW_HOME/cache/downloads" -type f | wc -l; }
prune_downloads() { z uninstall --unused --downloads >/dev/null 2>&1 && expect_count downloads 0; }
check "prune --downloads clears the download cache" prune_downloads
# Files of Windows' roots that earlier runs had (${roots}, src/roots.zig).
stale_roots() { : >"$ZIGSAW_HOME\\certs\\roots-0000000000000000.pem" && z uninstall --unused >/dev/null 2>&1 && [ ! -e "$ZIGSAW_HOME\\certs\\roots-0000000000000000.pem" ]; }
check "prune deletes files of Windows' roots that aren't today's" stale_roots

# --- the store lock --------------------------------------------------------------

# Holds the store lock (the byte Zig's file locks use) for 3 seconds.
powershell -NoProfile -Command "\$f = [IO.File]::Open('$ZIGSAW_HOME\\lock', 'OpenOrCreate', 'ReadWrite', 'ReadWrite'); \$f.Lock(0, 1); 'locked'; Start-Sleep 3; \$f.Close()" >"$work\\held" &
holder=$!
until grep -q locked "$work\\held" 2>/dev/null; do sleep 0.2; done
waits_for_lock() {
    local start=$SECONDS out
    out=$(z uninstall --unused 2>&1) && grep -q 'waiting for another zigsaw' <<<"$out" && [ $((SECONDS - start)) -ge 1 ]
}
check "prune waits for the store lock" waits_for_lock
wait $holder

z uninstall --unused --downloads --volumes >/dev/null 2>&1
rm -rf "$ZIGSAW_HOME" "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
