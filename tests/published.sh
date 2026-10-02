#!/usr/bin/env bash
# Checks that the published images are what the recipes build. For every
# recipe listed in scripts/published-recipes.txt, it builds the recipe, then
# pulls the image tagged with the recipe's version, anonymously and by app id,
# from the default registry (or ZIGSAW_REGISTRY):
# - The image must have the digest of the build. If it doesn't, either the
#   build isn't reproducible, or the recipe changed without a new version.
# - A version that isn't published yet is reported, but isn't a failure:
#   publishing is manual (scripts/publish.sh).
# - The pulled app must run, `latest` must be the same image, and the app must
#   then be up to date.
# CI runs this on a fresh Windows runner (.github/workflows/reproduce.yml), so
# it also shows that the recipes build the same images on another machine.
#
#   tests/published.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and network access. Pulls into a temporary store. Builds the
# recipes in BUILD_HOME if set, e.g. a store that already has their downloads,
# otherwise in a temporary store. Keeps the build and pull logs in LOG_DIR if
# set.

set -u
export MSYS_NO_PATHCONV=1
unset ZIGSAW_REGISTRY_USERNAME ZIGSAW_REGISTRY_PASSWORD # Pulls must work anonymously.

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
work=$(cygpath -w "$(mktemp -d)")
logs=${LOG_DIR:-$work\\logs}
mkdir -p "$logs"
pull_store="$work\\pulled"
build_store=${BUILD_HOME:-$work\\built}
zp() { ZIGSAW_HOME="$pull_store" "$zigsaw" "$@"; }
zb() { ZIGSAW_HOME="$build_store" "$zigsaw" "$@"; }

failures=0
unpublished=0
pulled=0
pass() { printf 'ok    %s\n' "$1"; }
# fail <label> [<detail line>...]
fail() {
    printf 'FAIL  %s\n' "$1"
    shift
    for line in "$@"; do printf '      %s\n' "$line"; done
    failures=$((failures + 1))
}
check() {
    local label=$1
    shift
    local out
    if out=$("$@" 2>&1); then
        pass "$label"
    else
        fail "$label" "$(grep -v '^\s*$' <<<"$out" | tail -1 | cut -c1-110)"
    fi
}
last_line() { grep -v '^\s*$' "$1" | tail -1 | cut -c1-110; }

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
manifest() { cat "$1\\blobs\\sha256\\${2#sha256:}"; }
# The digests a manifest lists: <store> <manifest digest> config|layers
listed() { manifest "$1" "$2" | tr -d ' \r\n' | grep -o "\"$3\":[{[][^]}]*" | grep -o 'sha256:[0-9a-f]*'; }

ids=()
for name in $(grep -v '^#' "$root/scripts/published-recipes.txt" | tr -d '\r'); do
    recipe="$root\\recipes\\$name"
    id=$(grep -o '"id": *"[^"]*"' "$recipe" | cut -d'"' -f4)
    ids+=("$id")
    if ! zb build "$recipe" >"$logs\\$id.build.log" 2>&1; then
        fail "$id: builds" "$(last_line "$logs\\$id.build.log")"
        continue
    fi
    built=$(ref_digest "$build_store" "$id")
    version=$(zb list | awk -v id="$id" '$1 == id { print $2 }')

    # Verbose, so the log shows where blob downloads were redirected.
    pull_log="$logs\\$id.pull.log"
    if ! zp -v pull "$id:$version" >"$pull_log" 2>&1; then
        # Registries answer "not found" for a missing tag, and refuse an
        # anonymous token for a package that doesn't exist (or is private).
        if grep -qE "not found|doesn't exist, or needs credentials" "$pull_log"; then
            printf 'new   %s %s is not published yet\n' "$id" "$version"
            unpublished=$((unpublished + 1))
        else
            fail "$id $version: pulls anonymously by app id" "$(last_line "$pull_log")"
        fi
        continue
    fi
    pulled=$((pulled + 1))
    pass "$id $version: pulls anonymously by app id"

    published=$(ref_digest "$pull_store" "$id")
    if [ "$published" = "$built" ]; then
        pass "$id $version: has the digest of a fresh build"
    else
        manifest "$build_store" "$built" >"$logs\\$id.built-manifest.json"
        manifest "$pull_store" "$published" >"$logs\\$id.published-manifest.json"
        differ=""
        [ "$(listed "$build_store" "$built" config)" = "$(listed "$pull_store" "$published" config)" ] ||
            differ="the config (the recipe's settings)"
        [ "$(listed "$build_store" "$built" layers)" = "$(listed "$pull_store" "$published" layers)" ] ||
            differ="${differ:+$differ and }the files"
        details=(
            "published $published"
            "built     $built"
            "They differ in ${differ:-the manifest alone}."
            "Either the build isn't reproducible, or the recipe changed without a new version."
        )
        [ -n "${LOG_DIR:-}" ] && details+=("Both manifests are in $LOG_DIR.")
        fail "$id $version: has the digest of a fresh build" "${details[@]}"
    fi

    # shellcheck disable=SC2046 # The arguments are meant to split.
    check "$id: runs" zp run "$id" $(smoke_args "$id")
    latest_is_version() {
        zp -v pull "$id" >>"$pull_log" 2>&1 || { last_line "$pull_log"; return 1; }
        local latest
        latest=$(ref_digest "$pull_store" "$id")
        [ "$latest" = "$published" ] || { echo "latest is $latest, $version is $published"; return 1; }
    }
    check "$id: latest is $version" latest_is_version
    up_to_date() { zp update "$id" 2>&1 | grep -q 'up to date'; }
    check "$id: is up to date" up_to_date
done
if [ $pulled -gt 0 ]; then
    redirected() { cat "$(cygpath -u "$logs")"/*.pull.log | grep -q 'redirected to .*, without the registry token'; }
    check "blob downloads were redirected to another host, without the token" redirected
fi

# Installed apps are protected against deletion, so remove them through zigsaw.
for id in "${ids[@]}"; do zp rm --delete-data "$id" >/dev/null 2>&1; done
zp prune --downloads >/dev/null 2>&1
if [ -z "${BUILD_HOME:-}" ]; then
    for id in "${ids[@]}"; do zb rm --delete-data "$id" >/dev/null 2>&1; done
    zb prune --downloads >/dev/null 2>&1
fi
rm -rf "$work"
echo
echo "$failures check(s) failed; $unpublished version(s) not published yet."
exit $((failures > 0))
