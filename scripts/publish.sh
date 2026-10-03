#!/usr/bin/env bash
# Builds recipes and publishes them as images, each tagged with its app's
# version and "latest", to the default registry (ghcr.io/zigsaw-io) or the
# one in ZIGSAW_REGISTRY.
#
#   scripts/publish.sh [recipe.json...]     (default: those in published-recipes.txt)
#
# Needs Git Bash, a built zigsaw (zig build), and credentials for the
# registry: a login saved with `zigsaw login ghcr.io`, or
# ZIGSAW_REGISTRY_USERNAME and ZIGSAW_REGISTRY_PASSWORD. For ghcr.io, that's a
# GitHub user and a token with the write:packages scope, and new packages
# start out private: make each one public in its package settings on GitHub.
#
# Builds happen in a temporary store, unless ZIGSAW_HOME points at one (to
# reuse its downloads). Either way, each image is built from its recipe right
# before it's pushed, so what's published is exactly what the recipe produces.
# The files each image was built from are pushed next to it (push --sources),
# so its recipe still builds if they're gone from where they came from.

set -eu
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${ZIGSAW:-$root/zig-out/bin/zigsaw.exe}
registry=${ZIGSAW_REGISTRY:-ghcr.io/zigsaw-io}

own_store=false
if [ -z "${ZIGSAW_HOME:-}" ]; then
    ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
    own_store=true
fi
export ZIGSAW_HOME

if [ $# -eq 0 ]; then
    for name in $(grep -v '^#' "$root/scripts/published-recipes.txt" | tr -d '\r'); do set -- "$@" "$root/recipes/$name"; done
fi

published=()
for recipe in "$@"; do
    id=$(grep -o '"id": *"[^"]*"' "$recipe" | cut -d'"' -f4)
    echo "== $id"
    "$zigsaw" build "$recipe"
    "$zigsaw" push --sources "$id"
    "$zigsaw" push "$id" "$id:latest"
    version=$("$zigsaw" list | awk -v id="$id" '$1 == id { print $2 }')
    digest=$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\refs\\$id.json")
    published+=("$id $version $digest")
done

if $own_store; then
    # Installed apps are protected against deletion, so remove them through zigsaw.
    for line in "${published[@]}"; do "$zigsaw" rm --delete-data "${line%% *}" >/dev/null 2>&1 || true; done
    "$zigsaw" prune --downloads >/dev/null 2>&1 || true
    rm -rf "$ZIGSAW_HOME"
fi

echo
echo "Published to $registry:"
printf '  %-32s %-22s %s\n' ID VERSION MANIFEST
for line in "${published[@]}"; do
    read -r id version digest <<<"$line"
    printf '  %-32s %-22s %s\n' "$id" "$version" "$digest"
done
case $registry in
ghcr.io/*)
    echo
    echo "New packages on ghcr.io are private. Make each one public under"
    echo "https://github.com/orgs/${registry#ghcr.io/}/packages -> the package -> Package settings."
    ;;
esac
