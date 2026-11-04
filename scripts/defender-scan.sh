#!/usr/bin/env bash
# What Microsoft Defender makes of a package's programs (scripts/package.sh's zip).
# Its machine learning has flagged builds of zigsaw by their exact bytes, as
# `Trojan:Win32/Bearfoos.A!ml` (docs/findings.md): the same code with another
# version string scanned clean. A user's Windows then won't start the program, so
# this runs before a release is published, on the bytes that would be.
#
#   scripts/defender-scan.sh [package directory]     (default: zig-out/release)
#
# Exits 1 if Defender finds something, naming it. Where it can't scan at all, as
# where it's turned off, this says so and exits 0: that isn't a finding about the
# programs. Needs no administrator. A scan like this leaves the file alone, but
# what Defender finds shows in the machine's Windows Security history.

set -u
export MSYS_NO_PATHCONV=1

root=$(cd "$(dirname "$0")/.." && pwd)
package=$(cygpath -aw "${1:-$root/zig-out/release}")
zip="$package\\zigsaw-x86_64-windows.zip"
[ -f "$zip" ] || { echo "no $zip: run scripts/package.sh first"; exit 2; }

scanner="${PROGRAMFILES:-C:\\Program Files}\\Windows Defender\\MpCmdRun.exe"
if [ ! -f "$scanner" ]; then
    echo "note: this machine has no $scanner; nothing was scanned"
    exit 0
fi

dir=$(cygpath -aw "$(mktemp -d)")
trap 'rm -rf "$(cygpath -u "$dir")" 2>/dev/null' EXIT
powershell -NoProfile -Command "Expand-Archive -LiteralPath '$zip' -DestinationPath '$dir'" || { echo "couldn't unpack $zip"; exit 2; }

flagged=0
for program in zigsaw.exe zigsaw-shim.exe zigsaw-shimw.exe zigsaw-relay.exe zigsaw-host.exe; do
    out=$("$scanner" -Scan -ScanType 3 -File "$dir\\$program" -DisableRemediation 2>&1 | tr -d '\r')
    if grep -q 'found no threats' <<<"$out"; then
        echo "ok    $program"
    elif grep -qE 'found [0-9]+ threats' <<<"$out"; then
        echo "FOUND $program: $(grep -E '^Threat +:' <<<"$out" | head -1 | sed 's/^Threat *: *//')"
        flagged=1
    else
        echo "note: Defender didn't scan $program: $(grep -v '^\s*$' <<<"$out" | tail -1 | cut -c1-120)"
    fi
done
exit "$flagged"
