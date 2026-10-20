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
# Then builds a copy of the checkout's files three times: once, after a
# change in the work directory the first build left, and with --clean.
# About 6 minutes.

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

# Built again after a change, the module starts in the work directory the
# last build left, with zig's .zig-cache in it. This is done on a copy of the
# checkout's files (which a build of the checkout would have reused), where
# one of zigsaw's messages then changes. The result should be what a --clean
# build of the copy makes, and a `zig build -Dstrip` of it.
copy="$work\\copy"
mkdir -p "$copy" && (cd "$root" && git ls-files -co --exclude-standard -z | tar --null -T - -cf - | tar -xf - -C "$(cygpath -u "$copy")") ||
    { echo "copying the checkout failed"; exit 1; }
# --rebuild, as its files are the checkout's, whose image it would take.
copy_builds() { (cd "$copy" && z build --rebuild); }
start=$SECONDS
check "a copy of it builds, with a work directory of its own" copy_builds
printf '      (%d s)\n' $((SECONDS - start))
# A POSIX path, so sed writes its temporary file beside it, not in the
# working directory (which may be on another volume than TMP).
sed -i 's/find apps in the default registry'"'"'s catalog/find apps in the catalog of the default registry/' "$(cygpath -u "$copy\\src\\main.zig")"
start=$SECONDS
incremental() { (cd "$copy" && z -v build 2>&1) | grep -q "module zigsaw: its work directory from the last build, 1 file(s) rewritten"; }
check "changed, it builds again in the work directory the last build left" incremental
printf '      (%d s)\n' $((SECONDS - start))
own_bin() {
    local m l
    m=$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\refs\\$APP.json" | cut -d: -f2)
    l=$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\blobs\\sha256\\$m" | tail -1 | cut -d: -f2)
    echo "$ZIGSAW_HOME\\deploy\\$l\\bin"
}
mkdir -p "$work\\incremental" && cp "$(own_bin)"/*.exe "$work\\incremental\\"
grep -q 'catalog of the default registry' "$work\\incremental\\zigsaw.exe" || { echo "the change isn't in what it built"; failures=$((failures + 1)); }
start=$SECONDS
check "with --clean, it builds the copy afresh" sh -c "cd '$copy' && \"\$0\" build --clean" "$zigsaw"
printf '      (%d s)\n' $((SECONDS - start))
for program in zigsaw.exe zigsaw-shim.exe zigsaw-shimw.exe; do
    check "the incremental build's $program is the same bytes as --clean's" cmp "$work\\incremental\\$program" "$(own_bin)\\$program"
done
if [ -z "${PACKAGE_DIR:-}" ]; then
    (cd "$copy" && zig build -Dstrip -p "$work\\copy-strip") || { echo "zig build -Dstrip of the copy failed"; exit 1; }
    check "and as zig build -Dstrip's of the copy" cmp "$work\\incremental\\zigsaw.exe" "$work\\copy-strip\\bin\\zigsaw.exe"
fi

z rm --delete-data $APP >/dev/null 2>&1
z prune --downloads --data >/dev/null 2>&1
rm -rf "$ZIGSAW_HOME" "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
