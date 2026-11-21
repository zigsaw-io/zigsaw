#!/usr/bin/env bash
# Checks that the published recipes whose commands run `make` build with GNU
# make (org.gnu.make), not BusyBox's: one job at a time, no pattern rules or
# $(shell), and an empty macro on its command line can come out as garbage.
# A recipe reaches GNU make by listing it in "sdk" or "runtimes", or by
# listing an SDK or runtime whose recipe here has it in "runtimes" (GTK's
# SDK, PostgreSQL's SDK).
#
#   scripts/check-make.sh [recipe.json...]   (default: those in published-recipes.txt)
#
# "Runs make" is a guess from the commands' text, as zigsaw build's note is:
# `make` as a word of the shell's, so `cmake` and `automake` aren't. Needs
# jq and bash; reads nothing but recipes/.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)

if [ $# -eq 0 ]; then
    for name in $(grep -v '^#' "$root/scripts/published-recipes.txt" | tr -d '\r'); do set -- "$@" "$root/recipes/$name"; done
fi

# The ids of the recipes here that bring GNU make as a runtime.
brings=$(for f in "$root"/recipes/*.json "$root"/recipes/no-publish/*.json; do
    [ -f "$f" ] || continue
    jq -r 'select((.runtimes // {}) | to_entries | any(.value | startswith("org.gnu.make:") or startswith("org.gnu.make@"))) | .id' "$f"
done | tr -d '\r')

runs_make='[.modules[] | (.build // [])[], ((.vendor // {}).commands // [])[]]
    | any(test("(^|[ \t\n;&|(])make($|[ \t\n;&|)])"))'

failed=0 checked=0
for f in "$@"; do
    name=${f##*/}
    [ "$(jq -r "$runs_make" "$f")" = true ] || continue
    checked=$((checked + 1))
    pins=$(jq -r '[(.sdk // {}), (.runtimes // {})] | map(to_entries[].value) | .[]' "$f" | tr -d '\r')
    ok=
    while read -r pin; do
        [ -n "$pin" ] || continue
        id=${pin%%[:@]*}
        if [ "$id" = org.gnu.make ] || grep -qxF "$id" <<<"$brings"; then ok=1; break; fi
    done <<<"$pins"
    if [ -n "$ok" ]; then
        echo "ok      $name"
    else
        echo "FAILED  $name: runs make, but neither it nor an SDK or runtime it lists has org.gnu.make"
        failed=$((failed + 1))
    fi
done
echo "$checked recipes run make; $failed without GNU make"
[ "$failed" -eq 0 ]
