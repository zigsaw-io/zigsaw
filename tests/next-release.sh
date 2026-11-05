#!/usr/bin/env bash
# Packages a later release of this checkout, with the same code and the next patch
# version: the only way to have a zigsaw that says it's newer, for tests of
# `zigsaw upgrade`. It needs what packaging needs, git and a real Zig, so
# tests/standard-user.sh runs it before handing over to an account with neither.
#
#   tests/next-release.sh <output directory>
#
# Prints nothing but what's wrong.

set -u
export MSYS_NO_PATHCONV=1

[ $# -eq 1 ] || { echo "usage: tests/next-release.sh <output directory>"; exit 2; }
root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
out=$1
copy=$(cygpath -w "$(mktemp -d)")
trap 'rm -rf "$copy"' EXIT

this_version=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$root\\build.zig.zon")
next_version="${this_version%.*}.$((${this_version##*.} + 1))"
(cd "$root" && git ls-files -co --exclude-standard -z | tar --null -T - -cf - | tar -xf - -C "$(cygpath -u "$copy")") ||
    { echo "copying the checkout failed"; exit 1; }
sed -i "s/\.version = \"$this_version\"/.version = \"$next_version\"/" "$(cygpath -u "$copy\\build.zig.zon")"
sed -i "s/\"version\": \"$this_version\"/\"version\": \"$next_version\"/" "$(cygpath -u "$copy\\zigsaw.json")"
log=$(mktemp)
(cd "$copy" && bash scripts/package.sh "$(cygpath -u "$out")") >"$log" 2>&1 ||
    { echo "packaging the later release failed: $(tail -1 "$log")"; rm -f "$log"; exit 1; }
rm -f "$log"
