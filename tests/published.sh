#!/usr/bin/env bash
# Checks the published images: the app of every recipe listed in
# scripts/published-recipes.txt installs anonymously by its app id from the
# default registry (or ZIGSAW_REGISTRY), has the digest a local build of the
# recipe gives, runs, and is up to date.
#
#   tests/published.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and network access. Pulls into a temporary store. Builds the
# recipes in BUILD_HOME if set, e.g. a store that already has their downloads,
# otherwise in a temporary store.

set -u
export MSYS_NO_PATHCONV=1
unset ZIGSAW_REGISTRY_USERNAME ZIGSAW_REGISTRY_PASSWORD # Pulls must work anonymously.

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
work=$(cygpath -w "$(mktemp -d)")
pull_store="$work\\pulled"
build_store=${BUILD_HOME:-$work\\built}
zp() { ZIGSAW_HOME="$pull_store" "$zigsaw" "$@"; }
zb() { ZIGSAW_HOME="$build_store" "$zigsaw" "$@"; }

failures=0
check() {
    local label=$1
    shift
    local out
    if out=$("$@" 2>&1); then
        printf 'ok    %s\n' "$label"
    else
        printf 'FAIL  %s\n      %s\n' "$label" "$(grep -v '^\s*$' <<<"$out" | tail -1 | cut -c1-110)"
        failures=$((failures + 1))
    fi
}

# Arguments for a quick run of each app that exits 0.
smoke_args() {
    case $1 in
    net.frippery.busybox) printf '%s\n' true ;;
    org.nodejs.node) printf '%s\n' '-e 0' ;;
    org.python.python) printf '%s\n' '-c pass' ;;
    *) printf '%s\n' --version ;;
    esac
}
ref_digest() { grep -o 'sha256:[0-9a-f]*' "$1\\refs\\$2.json"; }

ids=()
for name in $(grep -v '^#' "$root/scripts/published-recipes.txt" | tr -d '\r'); do
    recipe="$root\\recipes\\$name"
    id=$(grep -o '"id": *"[^"]*"' "$recipe" | cut -d'"' -f4)
    ids+=("$id")
    zb build "$recipe" >/dev/null 2>&1 || { echo "FAIL  building $id"; failures=$((failures + 1)); continue; }
    want=$(ref_digest "$build_store" "$id")

    # Verbose, so the log shows where blob downloads were redirected.
    pull_logged() { zp -v pull "$id" >"$work\\$id.log" 2>&1 || { cat "$work\\$id.log"; return 1; }; }
    check "$id: pulls anonymously by app id" pull_logged
    same_digest() { [ "$(ref_digest "$pull_store" "$id")" = "$want" ] || { echo "pulled $(ref_digest "$pull_store" "$id"), built $want"; return 1; }; }
    check "$id: has the digest of a local build" same_digest
    # shellcheck disable=SC2046 # The arguments are meant to split.
    check "$id: runs" zp run "$id" $(smoke_args "$id")
    up_to_date() { zp update "$id" 2>&1 | grep -q 'up to date'; }
    check "$id: is up to date" up_to_date
done
redirected() { cat "$(cygpath -u "$work")"/*.log | grep -q 'redirected to .*, without the registry token'; }
check "blob downloads were redirected to another host, without the token" redirected

# Installed apps are protected against deletion, so remove them through zigsaw.
for id in "${ids[@]}"; do zp rm --delete-data "$id" >/dev/null 2>&1; done
zp prune --downloads >/dev/null 2>&1
if [ -z "${BUILD_HOME:-}" ]; then
    for id in "${ids[@]}"; do zb rm --delete-data "$id" >/dev/null 2>&1; done
    zb prune --downloads >/dev/null 2>&1
fi
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
