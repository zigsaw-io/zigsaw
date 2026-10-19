#!/usr/bin/env bash
# Fills a store with the apps the end-to-end suites run, for CI's suites job
# (.github/workflows/reproduce.yml), which runs beside the jobs that build the
# published recipes and so can't take their builds.
#
#   tests/seed-store.sh [--build] <recipe>... [--pull <recipe>...]
#   e.g. tests/seed-store.sh --build busybox node --pull zig ripgrep
#
# Recipes are named as in recipes/, without .json. After --pull (the
# default), each recipe's image is pulled at the recipe's version from the
# default registry (or ZIGSAW_REGISTRY), which tests/published.sh checks is
# what the recipe builds; a version that isn't published yet is built from
# the recipe instead. After --build, recipes are built, so that their
# downloads are in the store's cache\downloads, for the suites'
# SEED_DOWNLOADS. Uses the store in ZIGSAW_HOME (required) and the zigsaw in
# ZIGSAW (default zig-out\bin\zigsaw.exe); apps installed there already are
# left as they are.

set -u
export MSYS_NO_PATHCONV=1
root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${ZIGSAW:-$root\\zig-out\\bin\\zigsaw.exe}
[ -n "${ZIGSAW_HOME:-}" ] || { echo "ZIGSAW_HOME isn't set"; exit 2; }
export ZIGSAW_HOME
log=$(mktemp)
trap 'rm -f "$log"' EXIT

build() {
    "$zigsaw" build "$root\\recipes\\$1.json" >"$log" 2>&1 || { cat "$log"; echo "building $1 failed"; exit 1; }
}

mode=pull
for recipe in "$@"; do
    case $recipe in
    --build | --pull)
        mode=${recipe#--}
        continue
        ;;
    esac
    id=$(grep -o '"id": *"[^"]*"' "$root\\recipes\\$recipe.json" | cut -d'"' -f4)
    version=$(grep -o '"version": *"[^"]*"' "$root\\recipes\\$recipe.json" | head -1 | cut -d'"' -f4)
    if "$zigsaw" list 2>/dev/null | grep -q "^$id  *$version "; then
        echo "have    $id $version"
    elif [ $mode = build ]; then
        build "$recipe"
        echo "built   $id $version"
    elif "$zigsaw" pull "$id:$version" >"$log" 2>&1; then
        echo "pulled  $id $version"
    elif grep -qE "not found|doesn't exist, or needs credentials" "$log"; then
        # As tests/published.sh tells a version that isn't published yet.
        build "$recipe"
        echo "built   $id $version (not published yet)"
    else
        cat "$log"
        echo "pulling $id:$version failed"
        exit 1
    fi
done
