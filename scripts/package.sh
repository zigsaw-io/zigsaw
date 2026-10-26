#!/usr/bin/env bash
# Builds zigsaw and lays out a release's files, as the Release workflow
# (.github/workflows/release.yml) publishes them and scripts/install.ps1
# installs them:
#
#   zigsaw-x86_64-windows.zip   zigsaw.exe, zigsaw-shim.exe, zigsaw-shimw.exe,
#                               zigsaw-relay.exe, LICENSE, and Zig's licence
#                               (its standard library is compiled into them)
#   install.ps1                 scripts/install.ps1
#   SHA256SUMS                  of the two
#   notes.md                    the release's notes: the programs' own hashes
#
#   scripts/package.sh [output directory]     (default: zig-out/release)
#
# Needs Git Bash and Zig. zigsaw.exe is built without debug information
# (-Dstrip), which would name the directory it was built in: the four
# programs are then the same bytes from any checkout of the same commit, with
# the same Zig, so anyone can check a release against a build of their own.
# The zip itself isn't: it records when it was made.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$root/zig-out/release}
cd "$root"

rm -rf "$out"
mkdir -p "$out/files"
# Into a prefix of its own: zig-out/bin keeps the build with debug information.
zig build -Dstrip -p "$(cygpath -w "$out/build")"
version=$("$out/build/bin/zigsaw.exe" version | tr -d '\r' | cut -d' ' -f2)
cp "$out/build/bin/zigsaw.exe" "$out/build/bin/zigsaw-shim.exe" "$out/build/bin/zigsaw-shimw.exe" "$out/build/bin/zigsaw-relay.exe" LICENSE "$out/files/"
rm -rf "$out/build"
# Zig's licence is next to its lib directory.
zig_lib=$(zig env | tr -d '\r' | sed -n 's/^ *\.lib_dir = "\(.*\)",$/\1/p' | sed 's/\\\\/\\/g')
cp "$(dirname "$(cygpath -u "$zig_lib")")/LICENSE" "$out/files/LICENSE-zig.txt"

powershell -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$out/files")\\*' -DestinationPath '$(cygpath -w "$out")\\zigsaw-x86_64-windows.zip'"
cp scripts/install.ps1 "$out/"

sum() { sha256sum <"$1" | cut -d' ' -f1; }
(
    cd "$out"
    for f in zigsaw-x86_64-windows.zip install.ps1; do printf '%s  %s\n' "$(sum "$f")" "$f"; done >SHA256SUMS
    {
        printf 'Install or upgrade, in PowerShell:\n\n'
        printf '```powershell\nirm https://github.com/zigsaw-io/zigsaw/releases/download/v%s/install.ps1 | iex\n```\n\n' "$version"
        printf 'Built with Zig %s by `zig build -Dstrip`. A build of this tag has the same programs:\n\n' "$(zig version | tr -d '\r')"
        printf '| Program | SHA-256 |\n|---|---|\n'
        for f in zigsaw.exe zigsaw-shim.exe zigsaw-shimw.exe zigsaw-relay.exe; do printf '| `%s` | `%s` |\n' "$f" "$(sum "files/$f")"; done
    } >notes.md
)
rm -rf "$out/files"

echo "zigsaw $version packaged in $(cygpath -w "$out"):"
cat "$out/SHA256SUMS"
