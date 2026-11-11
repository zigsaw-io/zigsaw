#!/usr/bin/env bash
# Builds recipes and everything that pins them, in an order where a recipe follows
# what it pins, and points each one's pins at what was just built.
#
#   scripts/rebuild.sh --plan <recipe.json>...     the order, building nothing
#   scripts/rebuild.sh <recipe.json>...            build, and rewrite pins in recipes/
#   scripts/rebuild.sh --no-pin <recipe.json>...   only build: a second store's run, to
#                                                  compare digests with the first
#
# Recipes are named as in scripts/published-recipes.txt (go.json). Change their
# sources by hand first: this doesn't look for new versions (scripts/check-upstream.sh
# does) or edit a source's URL or hash.
#
# Building needs ZIGSAW_HOME, the store to build in, set, so a forgetful run can't
# build into your own store, and ZIGSAW, the zigsaw to build with, which defaults to
# zig-out/bin/zigsaw.exe. A frozen copy keeps the build cache valid while you work:
# its keys include the program.
#
# After each build, every recipe that pins it gets "<id>:<built version>@sha256:<digest>",
# the version included, as a pin says which tag it came from. Equal ranks follow
# scripts/published-recipes.txt, as CI's builds do.
#
# It stops at the first failure, with the end of that build's log. To go on, fix it and
# run the same command: what's done is a cache hit.
#
# A recipe that isn't published (recipes/no-publish) isn't built, or re-pinned: those
# that pin something rebuilt are listed at the end. An image pinned elsewhere, such
# as by a test's fixture, isn't looked for.
#
# Each step prints the recipe, the digest's start, and how long it took. A run that
# re-pins ends with what to publish, as a command.
#
# Needs Git Bash (or any bash) and GNU sed. Build logs go to REBUILD_LOGS, or a
# temporary directory that's kept if a build fails. For the tests: REBUILD_RECIPES and
# REBUILD_PUBLISHED replace the recipes' directory and the list of published recipes.

set -u
export LC_ALL=C

mode=build
names=()
for arg in "$@"; do
    case $arg in
    --plan) mode=plan ;;
    --no-pin) mode=no-pin ;;
    --* | -*)
        echo "unknown option $arg" >&2
        exit 2
        ;;
    *) names+=("${arg%.json}") ;;
    esac
done
if [ "${#names[@]}" -eq 0 ]; then
    echo "usage: rebuild.sh [--plan | --no-pin] <recipe.json>..." >&2
    exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
recipes_dir=${REBUILD_RECIPES:-$root/recipes}
published=${REBUILD_PUBLISHED:-$root/scripts/published-recipes.txt}

die() {
    echo "$1" >&2
    exit 1
}

# Reads what recipes are, and who pins whom: "<id>:<version>@sha256:<digest>" in quotes.
shopt -s nullglob
cd "$recipes_dir" || exit 2
recipes_dir=$(pwd)
recipe_files=(*.json no-publish/*.json)
declare -A id_of recipe_of pins_of consumers is_published rank
for file in "${recipe_files[@]}"; do
    recipe=${file%.json}
    id=$(grep -o '"id": *"[^"]*"' "$file" | head -1 | cut -d'"' -f4)
    id_of[$recipe]=$id
    recipe_of[$id]=$recipe
done
while IFS=: read -r file pinned_id _; do
    recipe=${file%.json}
    # A recipe can pin the same image in its SDK and among its runtimes.
    case " ${consumers[$pinned_id]:-} " in
    *" $recipe "*) ;;
    *)
        consumers[$pinned_id]+=" $recipe"
        pins_of[$recipe]+=" $pinned_id"
        ;;
    esac
done < <(grep -oH '"[A-Za-z0-9_.-]*:[^"@ ]*@sha256:[0-9a-f]\{64\}"' "${recipe_files[@]}" | tr -d '"')
n=0
if [ -f "$published" ]; then
    while IFS= read -r line; do
        line=${line%$'\r'}
        case $line in '' | '#'*) continue ;; esac
        is_published[${line%.json}]=1
        rank[${line%.json}]=$n
        n=$((n + 1))
    done <"$published"
fi

for recipe in "${names[@]}"; do
    [ -n "${id_of[$recipe]:-}" ] || die "no recipe $recipe.json in $recipes_dir"
done

# The named recipes and all that pin them, and so on.
declare -A wanted
left_out=
todo=("${names[@]}")
while [ "${#todo[@]}" -gt 0 ]; do
    recipe=${todo[0]}
    todo=("${todo[@]:1}")
    [ -z "${wanted[$recipe]:-}" ] || continue
    wanted[$recipe]=1
    for next in ${consumers[${id_of[$recipe]}]:-}; do
        if [ -z "${wanted[$next]:-}" ]; then todo+=("$next"); fi
    done
done
for recipe in "${!wanted[@]}"; do
    if [ -z "${is_published[$recipe]:-}" ]; then
        unset "wanted[$recipe]"
        left_out+=" $recipe"
    fi
done

# Each round takes those whose pins among the wanted are done, by rank.
order=()
declare -A done_yet
remaining=${#wanted[@]}
while [ "$remaining" -gt 0 ]; do
    ready=
    for recipe in "${!wanted[@]}"; do
        [ -z "${done_yet[$recipe]:-}" ] || continue
        blocked=
        for pinned_id in ${pins_of[$recipe]:-}; do
            other=${recipe_of[$pinned_id]:-}
            # An image pinning its own older build isn't waiting for itself.
            if [ -n "$other" ] && [ "$other" != "$recipe" ] && [ -n "${wanted[$other]:-}" ] && [ -z "${done_yet[$other]:-}" ]; then
                blocked=1
            fi
        done
        [ -n "$blocked" ] || ready+="${rank[$recipe]:-999999} $recipe"$'\n'
    done
    [ -n "$ready" ] || die "the pins go in a circle among:$(for r in "${!wanted[@]}"; do [ -n "${done_yet[$r]:-}" ] || printf ' %s' "$r"; done)"
    next=$(printf '%s' "$ready" | sort -n -k1,1 -k2,2 | head -1 | cut -d' ' -f2)
    order+=("$next")
    done_yet[$next]=1
    remaining=$((remaining - 1))
done

note_left_out() {
    [ -n "$left_out" ] || return 0
    echo "not published, so not rebuilt, and still on the old pins:$(printf ' %s' $(printf '%s\n' $left_out | sort | sed 's|^no-publish/||'))"
}

if [ "$mode" = plan ]; then
    printf '%s\n' "${order[@]}"
    note_left_out
    exit 0
fi

[ -n "${ZIGSAW_HOME:-}" ] || die "set ZIGSAW_HOME to the store to build in"
zigsaw=${ZIGSAW:-$root/zig-out/bin/zigsaw.exe}
store=$(cygpath -u "$ZIGSAW_HOME" 2>/dev/null || echo "$ZIGSAW_HOME")
logs=${REBUILD_LOGS:-$(mktemp -d)}
mkdir -p "$logs"

# <recipe>: the digest its build left in the store's refs, without "sha256:".
built_digest() {
    sed -n 's/.*"manifest": *"sha256:\([0-9a-f]*\)".*/\1/p' "$store/refs/${id_of[$1]}.json"
}

for recipe in "${order[@]}"; do
    start=$SECONDS
    log="$logs/${recipe//\//-}.log"
    # zigsaw's a native program, so a path it understands. And from the logs' directory,
    # as nothing a build does should land among the recipes.
    file=$recipes_dir/$recipe.json
    if command -v cygpath >/dev/null; then file=$(cygpath -w "$file"); fi
    # Every module of it, whatever an earlier build of the recipe left: what's
    # pinned and published here mustn't rest on that.
    if ! (cd "$logs" && "$zigsaw" build --no-resume "$file") >"$log" 2>&1; then
        echo "$recipe FAILED after $((SECONDS - start))s, in $log:"
        tail -15 "$log"
        exit 1
    fi
    hex=$(built_digest "$recipe")
    [ "${#hex}" = 64 ] || die "$recipe built, but $store/refs/${id_of[$recipe]}.json has no digest"
    echo "$recipe ${hex:0:12} $((SECONDS - start))s"
    if [ "$mode" = build ]; then
        version=$(grep -o '"version": *"[^"]*"' "$recipe.json" | head -1 | cut -d'"' -f4)
        id_re=${id_of[$recipe]//./\\.}
        for next in ${consumers[${id_of[$recipe]}]:-}; do
            # An image with an older build of itself among its sources stays on it.
            [ "$next" != "$recipe" ] || continue
            [ -n "${is_published[$next]:-}" ] || continue
            sed -i "s/\"$id_re:[^\"@ ]*@sha256:[0-9a-f]\{64\}\"/\"${id_of[$recipe]}:$version@sha256:$hex\"/g" "$next.json"
        done
    fi
done

note_left_out
if [ "$mode" = build ]; then
    list=
    for recipe in "${order[@]}"; do list+=" $recipe.json"; done
    echo "to publish, in this order, before pushing:"
    echo "  ZIGSAW_HOME='$ZIGSAW_HOME' ZIGSAW='$zigsaw' scripts/publish.sh$list"
fi
