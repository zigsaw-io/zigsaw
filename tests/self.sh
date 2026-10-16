#!/usr/bin/env bash
# zigsaw built by zigsaw: `zigsaw build` in this checkout builds its
# zigsaw.json, a project's manifest at its root, from the checkout's own
# files, in zig's image. Its programs should be the same bytes as
# `zig build -Dstrip` makes outside zigsaw, as releases are built.
#
#   tests/self.sh [path\to\zigsaw.exe]
#
# Compares with a `zig build -Dstrip` of the checkout, or, when PACKAGE_DIR
# names the directory scripts/package.sh made, with the programs in its zip,
# which then build it too, as the Release workflow checks. Needs Git Bash,
# Zig 0.16.0 (without PACKAGE_DIR) and network access, for zig's image
# (88 MB from ghcr.io). Uses a temporary store, and deletes it afterwards.
# About 3 minutes.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
APP=io.github.zigsaw-io.zigsaw

if [ -n "${PACKAGE_DIR:-}" ]; then
    expected="$work\\package"
    powershell -NoProfile -Command "Expand-Archive -Path '$(cygpath -aw "$PACKAGE_DIR")\\zigsaw-x86_64-windows.zip' -DestinationPath '$expected'" ||
        { echo "unpacking the package failed"; exit 1; }
    what="the package's"
    zigsaw=${1:-$expected\\zigsaw.exe}
else
    zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
fi

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
z() { "$zigsaw" "$@"; }

version=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$root\\build.zig.zon")
same_version() { grep -q "^  \"version\": \"$version\",\$" "$root\\zigsaw.json"; }
check "zigsaw.json has build.zig.zon's version, $version" same_version

builds() { (cd "$root" && z build); }
start=$SECONDS
check "zigsaw build, in the checkout, builds it" builds
printf '      (%d s)\n' $((SECONDS - start))
manifest=$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\refs\\$APP.json" | cut -d: -f2)
layer=$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\blobs\\sha256\\$manifest" | tail -1 | cut -d: -f2)
built="$ZIGSAW_HOME\\deploy\\$layer\\bin"

if [ -z "${PACKAGE_DIR:-}" ]; then
    (cd "$root" && zig build -Dstrip -p "$work\\strip") || { echo "zig build -Dstrip failed"; exit 1; }
    expected="$work\\strip\\bin"
    what="zig build -Dstrip's"
fi
for program in zigsaw.exe zigsaw-shim.exe zigsaw-shimw.exe; do
    check "its $program is the same bytes as $what" cmp "$built\\$program" "$expected\\$program"
done
check "it runs, as an app" sh -c "\"\$0\" run $APP version | tr -d '\r' | grep -qx 'zigsaw $version'" "$zigsaw"

z rm --delete-data $APP >/dev/null 2>&1
z prune --downloads --data >/dev/null 2>&1
rm -rf "$ZIGSAW_HOME" "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
