#!/usr/bin/env bash
# Console events end to end: Ctrl+C, Ctrl+Break and closing the console reach
# an app run through zigsaw, directly and through a shim, as they reach it run
# alone, and the app's process tree ends with the run.
#
#   tests/ctrlc.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and network access (for the Node download, unless the store
# in %ZIGSAW_HOME% or SEED_DOWNLOADS has it). Builds the test driver
# (tests/ctrlc.zig), which runs each app in a pseudoconsole, as a terminal
# does, so no window opens. Uses a temporary store unless ZIGSAW_HOME is set.

set -u
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.." || exit 1
root=$(cygpath -w "$(pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
zig build ctrlc-driver || { echo "building the test driver failed"; exit 1; }

own_store=false
if [ -z "${ZIGSAW_HOME:-}" ]; then
    ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
    own_store=true
fi
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
# SEED_DOWNLOADS: another store's cache\downloads, whose files are linked, or
# copied, into this one's, so as not to download them again.
if [ -n "${SEED_DOWNLOADS:-}" ]; then
    mkdir -p "$ZIGSAW_HOME\\cache\\downloads"
    cp -l "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/" 2>/dev/null ||
        cp -n "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/"
fi

"$zigsaw" build "$root/recipes/node.json" >/dev/null 2>&1 || { echo "building node failed"; exit 1; }
"$root/zig-out/test/zigsaw-ctrlc.exe" "$zigsaw" "$ZIGSAW_HOME" "$work"
status=$?

if $own_store; then
    "$zigsaw" rm --delete-data org.nodejs.node >/dev/null 2>&1
    "$zigsaw" prune --downloads >/dev/null 2>&1
    rm -rf "$ZIGSAW_HOME"
fi
rm -rf "$work"
exit $status
