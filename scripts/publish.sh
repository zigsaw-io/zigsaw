#!/usr/bin/env bash
# Builds recipes and publishes them as images, each tagged with its app's
# version and "latest", to the default registry (ghcr.io/zigsaw-io) or the
# one in ZIGSAW_REGISTRY; then the registry's catalog of the apps, which
# `zigsaw search` reads.
#
#   scripts/publish.sh [--skip-unchanged[=REV]] [recipe.json...]
#                                  (default: those in published-recipes.txt)
#
# With --skip-unchanged, only new or changed recipes are built and published,
# as git sees them: a recipe is changed if it, or a file in the directory
# named like it (recipes/gtk4-sdk/ for gtk4-sdk.json), differs from REV
# (default HEAD) in the working tree or isn't tracked yet. Pass the commit the
# registry was last published from to catch committed changes. A recipe that
# names the image of a chosen one (meld on GTK, say) is chosen too, and so on
# down, when both are in this run.
# The catalog is pushed either way.
#
# It refuses recipes in recipes/no-publish/, whose images mustn't be
# published.
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

changed=
skipped=()
case ${1:-} in
--skip-unchanged | --skip-unchanged=*)
    since=${1#--skip-unchanged}
    since=${since#=}
    since=${since:-HEAD}
    shift
    # Files under recipes/ that differ from $since in the working tree, plus
    # those git doesn't track yet.
    changed=$({
        git -C "$root" diff --name-only "$since" -- recipes
        git -C "$root" ls-files --others --exclude-standard -- recipes
    } | tr -d '\r')
    # Nothing changed must not read as "no filter".
    changed=${changed:-/nothing}
    ;;
esac

if [ $# -eq 0 ]; then
    for name in $(grep -v '^#' "$root/scripts/published-recipes.txt" | tr -d '\r'); do set -- "$@" "$root/recipes/$name"; done
fi
# Recipes in recipes/no-publish/ make images whose licences don't allow
# publishing them (Microsoft's .NET binaries, for one). Any of them, named or
# listed, stops this before anything is published.
for recipe in "$@"; do
    case /${recipe//\\//} in
    */no-publish/*)
        echo "error: $recipe is in recipes/no-publish/: its image mustn't be published" >&2
        exit 1
        ;;
    esac
done

own_store=false
if [ -z "${ZIGSAW_HOME:-}" ]; then
    ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
    own_store=true
fi
export ZIGSAW_HOME

# With --skip-unchanged: work out which recipes to publish. Those git sees
# changed, then (until nothing more is added) those that name the image of one
# already chosen, such as "org.gtk.Gtk3:3.24.52@sha256:...".
todo=("$@")
if [ -n "$changed" ]; then
    declare -A ids pick
    for recipe in "$@"; do
        ids[$recipe]=$(grep -o '"id": *"[^"]*"' "$recipe" | head -1 | cut -d'"' -f4)
        rel=recipes/${recipe##*/recipes/}
        stem=${rel%.json}
        if grep -qxE "$rel|$stem/.*" <<<"$changed"; then pick[$recipe]=git; fi
    done
    more=true
    while $more; do
        more=false
        for recipe in "$@"; do
            [ -n "${pick[$recipe]:-}" ] && continue
            for other in "$@"; do
                [ -n "${pick[$other]:-}" ] && [ "$other" != "$recipe" ] || continue
                if grep -qF "\"${ids[$other]}:" "$recipe"; then
                    pick[$recipe]="uses ${ids[$other]}"
                    more=true
                    break
                fi
            done
        done
    done
    todo=()
    for recipe in "$@"; do
        if [ -n "${pick[$recipe]:-}" ]; then todo+=("$recipe"); else skipped+=("${ids[$recipe]}"); fi
    done
fi

published=()
for recipe in "${todo[@]}"; do
    id=$(grep -o '"id": *"[^"]*"' "$recipe" | cut -d'"' -f4)
    echo "== $id"
    "$zigsaw" build "$recipe"
    "$zigsaw" push --sources "$id"
    "$zigsaw" push "$id" "$id:latest"
    version=$("$zigsaw" list | awk -v id="$id" '$1 == id { print $2 }')
    digest=$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\refs\\$id.json")
    published+=("$id $version $digest")
done

# The catalog `zigsaw search` reads lists every app published-recipes.txt
# names, as the registry has it now: those published before this run too.
catalog_ids=()
for name in $(grep -v '^#' "$root/scripts/published-recipes.txt" | tr -d '\r'); do
    catalog_ids+=("$(grep -o '"id": *"[^"]*"' "$root/recipes/$name" | head -1 | cut -d'"' -f4)")
done
echo "== catalog"
"$zigsaw" push --catalog "${catalog_ids[@]}"

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
if [ ${#skipped[@]} -gt 0 ]; then
    echo "Unchanged since $since, not built: ${skipped[*]}"
fi
case $registry in
ghcr.io/*)
    echo
    echo "New packages on ghcr.io are private, the catalog's too (\"catalog\"). Make each one public under"
    echo "https://github.com/orgs/${registry#ghcr.io/}/packages -> the package -> Package settings."
    ;;
esac
