#!/usr/bin/env bash
# Signs the images published recipes make, as the registry has them now: each recipe's
# own version and "latest". Those with a good signature are left alone, so that it can
# be run again after it stops. The images themselves don't change: a signature goes
# beside its image, under a tag of its own, and no digest moves.
#
#   scripts/sign-images.sh [recipe.json...]    (default: those in published-recipes.txt)
#
# COSIGN_KEY names the key: a cosign.key from scripts/signing-key.sh. Its passphrase is
# asked for once, unless COSIGN_PASSWORD has it. Older versions aren't signed: they're
# old for a reason, and pull warns about them.
#
# Needs Git Bash, a zigsaw built with the matching public key (zig build), with a login
# for the registry that may push (`zigsaw login ghcr.io`, or
# ZIGSAW_REGISTRY_USERNAME and ZIGSAW_REGISTRY_PASSWORD), and cosign in its store. The
# registry is the default one, or ZIGSAW_REGISTRY's.

set -eu
export MSYS_NO_PATHCONV=1

root=$(cd "$(dirname "$0")/.." && pwd)
root_w=$(cygpath -w "$root")
zigsaw=${ZIGSAW:-$root_w\\zig-out\\bin\\zigsaw.exe}
# shellcheck source=scripts/sign-lib.sh
. "$root/scripts/sign-lib.sh"

check_key
cosign=$(find_cosign)
ask_passphrase

if [ $# -eq 0 ]; then
    for name in $(grep -v '^#' "$root/scripts/published-recipes.txt" | tr -d '\r'); do set -- "$@" "$root/recipes/$name"; done
fi
field() { grep -o "\"$1\": *\"[^\"]*\"" "$2" | head -1 | cut -d'"' -f4; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
work_w=$(cygpath -w "$work")

signed=0
already=0
for recipe in "$@"; do
    id=$(field id "$recipe")
    version=$(field version "$recipe")
    for tag in "$version" latest; do
        image="$id:$tag"
        if "$zigsaw" signature check "$image" >/dev/null 2>&1; then
            already=$((already + 1))
            continue
        fi
        "$zigsaw" signature payload "$image" >"$work/payload" || { echo "error: $image isn't there to sign" >&2; exit 1; }
        sign_blob "$work_w\\payload" "$work_w\\signature"
        "$zigsaw" signature push "$image" "$work_w\\payload" "$work_w\\signature"
        signed=$((signed + 1))
    done
done
echo "$signed signed, $already signed already."
