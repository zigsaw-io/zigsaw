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
# A build that the driver stops with Ctrl+C in b's second command, which writes
# half.txt into the prefix and waits; built again, it goes on at that command,
# which then finds half.txt gone, as the command before it left the prefix, and
# that it ran once already.
"$zigsaw" build "$root/recipes/busybox.json" >/dev/null 2>&1 || { echo "building busybox failed"; exit 1; }
bb_digest=$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\refs\\net.frippery.busybox.json")
cat >"$work\\build.json" <<EOF
{ "id": "test.ctrlc.build", "version": "1", "command": "a.txt", "exports": {}, "sdk": { "busybox": "net.frippery.busybox@$bb_digest" },
  "modules": [
    { "name": "a", "build": ["echo a >\"\$PREFIX/a.txt\""] },
    { "name": "b", "build": [
      "echo b1 >\"\$PREFIX/b1.txt\"",
      "[ ! -e \"\$PREFIX/half.txt\" ] || exit 7; [ -f stopped ] || { touch stopped; echo half >\"\$PREFIX/half.txt\"; echo \"stop\"\"-now\"; sleep 600; }",
      "echo b >\"\$PREFIX/b.txt\""] },
    { "name": "c", "build": ["echo c >\"\$PREFIX/c.txt\""] } ] }
EOF
CTRLC_BUILD_RECIPE="$work\\build.json" "$root/zig-out/test/zigsaw-ctrlc.exe" "$zigsaw" "$ZIGSAW_HOME" "$work"
status=$?

if $own_store; then
    for app in org.nodejs.node test.ctrlc.build net.frippery.busybox; do "$zigsaw" rm --delete-data $app >/dev/null 2>&1; done
    "$zigsaw" prune --downloads >/dev/null 2>&1
    rm -rf "$ZIGSAW_HOME"
fi
rm -rf "$work"
exit $status
