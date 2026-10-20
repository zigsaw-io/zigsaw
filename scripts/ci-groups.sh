#!/usr/bin/env bash
# The groups of scripts/published-groups.txt the Reproduce workflow checks in
# a run, and whether it runs GTK's suites (tests/gtk.sh, tests/gtk3.sh):
#
#   scripts/ci-groups.sh [<commit>]
#
# prints, for $GITHUB_OUTPUT:
#
#   groups=<the groups, as a JSON list>
#   gtk=<true or false>
#
# and, on stderr, why. GTK's family (the groups in `changed_only` below) is
# checked only if a file it's built or tested from changed since <commit>,
# the last commit a Reproduce run passed on: its recipes and their
# directories, GTK's suites and what they build, and what checks any group
# (tests/published.sh, this script, the workflow). Its builds take most of a
# run (GTK's SDK alone is 55 minutes on a runner), and they change rarely.
# Without a commit, or one git can't compare with, every group is checked:
# as in the workflow's weekly run, which also catches a change to zigsaw
# that a GTK image no longer reproduces with.
set -euo pipefail
cd "$(dirname "$0")/.."

changed_only="gtk-tools gtk gtk-apps rnote gnumeric"

groups_file=scripts/published-groups.txt
all=$(grep -v -e '^#' -e '^\s*$' "$groups_file" | cut -d: -f1 | grep -vx skip | awk '!seen[$0]++')

# Paths whose change means GTK's family is checked: a file, or a directory
# ending in /, or a prefix of a file name ending in -.
gtk_paths=(
    tests/gtk.sh tests/gtk3.sh tests/gtk/ tests/acprobe.sh tests/acprobe.zig
    recipes/gtk4-msvc.json recipes/no-publish/pinta.json recipes/no-publish/dotnet
    # What gtk-suites seeds its store with besides GTK's family.
    recipes/busybox.json recipes/zig.json recipes/meson.json recipes/mingit.json
    # What checks any group.
    tests/published.sh tests/seed-store.sh tests/imports.zig scripts/ci-groups.sh
    "$groups_file" scripts/published-recipes.txt .github/workflows/reproduce.yml .gitattributes
)
for group in $changed_only; do
    for recipe in $(grep "^$group:" "$groups_file" | cut -d: -f2-); do
        gtk_paths+=("recipes/$recipe" "recipes/${recipe%.json}/")
    done
done

gtk=true
why="every group: no commit to compare with"
if [ -n "${1:-}" ]; then
    if changed=$(git diff --name-only "$1" HEAD 2>/dev/null); then
        gtk=false
        why="GTK's family left out: nothing it's built or tested from changed since ${1:0:12}"
        while read -r file; do
            [ -n "$file" ] || continue
            for path in "${gtk_paths[@]}"; do
                case $path in
                */) [[ $file == "$path"* ]] ;;
                *-) [[ $file == "$path"* ]] ;;
                *) [ "$file" = "$path" ] ;;
                esac && { gtk=true; why="every group: $file changed since ${1:0:12}"; break 2; }
            done
        done <<<"$changed"
    else
        why="every group: git can't compare with $1"
    fi
fi

selected=$all
if [ "$gtk" = false ]; then
    selected=$(grep -vxF -f <(tr ' ' '\n' <<<"$changed_only") <<<"$all")
fi
echo "$why" >&2
echo "groups=$(jq -Rnc '[inputs]' <<<"$selected")"
echo "gtk=$gtk"
