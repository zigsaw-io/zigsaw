#!/usr/bin/env bash
# The groups of scripts/published-groups.txt the Reproduce workflow checks in
# a run, and whether it runs GTK's suites (tests/gtk.sh, tests/gtk3.sh) and
# Qt's (tests/qt.sh):
#
#   scripts/ci-groups.sh [<commit>]
#
# prints, for $GITHUB_OUTPUT:
#
#   groups=<the groups, as a JSON list>
#   gtk=<true or false>
#   qt=<true or false>
#
# and, on stderr, why. GTK's family, Qt's, TeX Live's and GDAL's (the groups
# in `gtk_groups`, `qt_groups`, `texlive_groups` and `gdal_groups` below) are
# each checked only if a file it's built or tested from changed since
# <commit>, the last commit a Reproduce run passed on: its recipes and their
# directories, its suites and what they build, and what checks any group
# (tests/published.sh, this script, the workflow). Their builds take most of
# a run (GTK's SDK took 57 minutes on a runner in one build), and they change
# rarely; TeX Live's downloads 432 files from a mirror that replaces them as
# packages change, and GDAL's SDK is some 1,500 compiles.
# Without a commit, or one git can't compare with, every group is checked:
# as in the workflow's weekly run, which also catches a change to zigsaw
# that a GTK or Qt image no longer reproduces with.
set -euo pipefail
cd "$(dirname "$0")/.."

gtk_groups="gtk-tools gettext gtk-base gtk gtk-apps rnote gnumeric"
qt_groups="qt-base qt"
texlive_groups="texlive"
gdal_groups="gdal"

groups_file=scripts/published-groups.txt
all=$(grep -v -e '^#' -e '^\s*$' "$groups_file" | cut -d: -f1 | grep -vx skip | awk '!seen[$0]++')

# What checks any group: a change to one checks both families.
common_paths=(
    tests/published.sh tests/seed-store.sh tests/imports.zig scripts/ci-groups.sh
    "$groups_file" scripts/published-recipes.txt .github/workflows/reproduce.yml .gitattributes
)
# Paths whose change means a family is checked: a file, or a directory
# ending in /, or a prefix of a file name ending in -. Its groups' recipes,
# and their directories, are added below.
gtk_paths=(
    tests/gtk.sh tests/gtk3.sh tests/gtk/ tests/acprobe.sh tests/acprobe.zig
    recipes/gtk4-msvc.json recipes/no-publish/pinta.json recipes/no-publish/dotnet
    # What gtk-suites seeds its store with besides GTK's family.
    recipes/busybox.json recipes/llvm-mingw.json recipes/meson.json recipes/mingit.json
    "${common_paths[@]}"
)
qt_paths=(
    tests/qt.sh tests/qt/
    "${common_paths[@]}"
)
texlive_paths=(
    scripts/texlive-pins.sh recipes/gtk4-sdk/autotools-ld.sh
    "${common_paths[@]}"
)
gdal_paths=(
    tests/gdal.sh recipes/gtk4-sdk/autotools-mtimes.sh
    "${common_paths[@]}"
)
for group in $gtk_groups; do
    for recipe in $(grep "^$group:" "$groups_file" | cut -d: -f2-); do
        gtk_paths+=("recipes/$recipe" "recipes/${recipe%.json}/")
    done
done
for group in $qt_groups; do
    for recipe in $(grep "^$group:" "$groups_file" | cut -d: -f2-); do
        qt_paths+=("recipes/$recipe" "recipes/${recipe%.json}/")
    done
done
for group in $texlive_groups; do
    for recipe in $(grep "^$group:" "$groups_file" | cut -d: -f2-); do
        texlive_paths+=("recipes/$recipe" "recipes/${recipe%.json}/")
    done
done
for group in $gdal_groups; do
    for recipe in $(grep "^$group:" "$groups_file" | cut -d: -f2-); do
        gdal_paths+=("recipes/$recipe" "recipes/${recipe%.json}/")
    done
done

# changed_in <path>...: whether a file in $changed is one of the paths;
# prints it.
changed_in() {
    local file path
    while read -r file; do
        [ -n "$file" ] || continue
        for path in "$@"; do
            case $path in
            */) [[ $file == "$path"* ]] ;;
            *-) [[ $file == "$path"* ]] ;;
            *) [ "$file" = "$path" ] ;;
            esac && { echo "$file"; return 0; }
        done
    done <<<"$changed"
    return 1
}

gtk=true qt=true texlive=true gdal=true
why="every group: no commit to compare with"
if [ -n "${1:-}" ]; then
    if changed=$(git diff --name-only "$1" HEAD 2>/dev/null); then
        if file=$(changed_in "${gtk_paths[@]}"); then
            why="GTK's family: $file changed since ${1:0:12}"
        else
            gtk=false
            why="GTK's family left out: nothing it's built or tested from changed since ${1:0:12}"
        fi
        if file=$(changed_in "${qt_paths[@]}"); then
            why="$why; Qt's family: $file changed"
        else
            qt=false
            why="$why; Qt's family left out: nothing it's built or tested from changed"
        fi
        if file=$(changed_in "${texlive_paths[@]}"); then
            why="$why; TeX Live's: $file changed"
        else
            texlive=false
            why="$why; TeX Live's left out: nothing it's built from changed"
        fi
        if file=$(changed_in "${gdal_paths[@]}"); then
            why="$why; GDAL's: $file changed"
        else
            gdal=false
            why="$why; GDAL's left out: nothing it's built or tested from changed"
        fi
    else
        why="every group: git can't compare with $1"
    fi
fi

left_out=""
[ "$gtk" = true ] || left_out="$left_out $gtk_groups"
[ "$qt" = true ] || left_out="$left_out $qt_groups"
[ "$texlive" = true ] || left_out="$left_out $texlive_groups"
[ "$gdal" = true ] || left_out="$left_out $gdal_groups"
selected=$all
if [ -n "$left_out" ]; then
    selected=$(grep -vxF -f <(tr ' ' '
' <<<"${left_out# }") <<<"$all" || true)
fi
echo "$why" >&2
echo "groups=$(jq -Rnc '[inputs]' <<<"$selected")"
echo "gtk=$gtk"
echo "qt=$qt"
