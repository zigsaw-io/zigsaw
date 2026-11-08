#!/usr/bin/env bash
# Refreshes src/sigstore-root.json, the trusted root of Sigstore's that zigsaw builds in
# (src/sigstore.zig), from Sigstore's TUF repository, through cosign's own TUF client:
# that checks the repository's metadata from the root cosign has built in, which this
# doesn't do itself. Then it says what changed.
#
#   scripts/sigstore-root.sh
#
# A change is worth a release soon: a zigsaw without Fulcio's or Rekor's new keys refuses
# what's signed with them (docs/gaps.md). Needs Git Bash and cosign in the store
# (scripts/sign-lib.sh says how to name another); it reaches tuf-repo-cdn.sigstore.dev.

set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/sign-lib.sh
. "$root/scripts/sign-lib.sh"
cosign=$(find_cosign)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

TUF_ROOT=$(cygpath -w "$work") "$cosign" initialize >"$work/log" 2>&1 ||
    { echo "error: cosign couldn't read Sigstore's TUF repository: $(tail -1 "$work/log")" >&2; exit 1; }
new="$work/tuf-repo-cdn.sigstore.dev/targets/trusted_root.json"
[ -s "$new" ] || { echo "error: cosign left no trusted_root.json" >&2; exit 1; }
if cmp -s "$new" "$root/src/sigstore-root.json"; then
    echo "src/sigstore-root.json is Sigstore's trusted root as it is now."
    exit 0
fi
cp "$new" "$root/src/sigstore-root.json"
echo "src/sigstore-root.json changed. What it has now:"
summary='{logs: [.tlogs[] | "\(.baseUrl) \(.publicKey.keyDetails) from \(.publicKey.validFor.start) to \(.publicKey.validFor.end // "-")"], authorities: [.certificateAuthorities[] | "\(.uri) from \(.validFor.start) to \(.validFor.end // "-")"]}'
if command -v jq >/dev/null; then jq "$summary" "$root/src/sigstore-root.json"; fi
echo "Run zig build test: its first sigstore test names Rekor's key it expects."
