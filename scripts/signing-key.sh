#!/usr/bin/env bash
# Makes a key pair for signing images and releases, with cosign, in a folder of your
# choosing, which must not be in a repository: cosign.key, encrypted with a passphrase
# you're asked for, and cosign.pub, which is what goes into src/trust.zig.
#
#   scripts/signing-key.sh <empty or new folder>
#
# zigsaw builds in two public keys: one that signs and one kept away from this machine,
# for the day the first is lost or stolen. Keep the second's cosign.key and passphrase
# on something you can lock away, and copy the first's there too. If both keys are lost,
# nobody can be sent an upgrade: every zigsaw would have to be installed again by hand.
#
# Needs Git Bash and cosign in the store (scripts/sign-lib.sh says how to name another).

set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/sign-lib.sh
. "$root/scripts/sign-lib.sh"

[ $# -eq 1 ] || { echo "usage: scripts/signing-key.sh <folder>" >&2; exit 2; }
mkdir -p "$1"
dir=$(cd "$1" && pwd)
if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: $dir is in a git repository, where a key could be committed. Choose a folder that isn't" >&2
    exit 1
fi
[ ! -e "$dir/cosign.key" ] || { echo "error: $dir already has a key; it stays" >&2; exit 1; }

cosign=$(find_cosign)
if [ -z "${COSIGN_PASSWORD:-}" ]; then
    IFS= read -rs -p "A passphrase for the new key: " first
    echo
    IFS= read -rs -p "Again: " second
    echo
    [ "$first" = "$second" ] || { echo "error: they weren't the same" >&2; exit 1; }
    [ -n "$first" ] || { echo "error: a key with no passphrase protects nothing" >&2; exit 1; }
    COSIGN_PASSWORD=$first
    export COSIGN_PASSWORD
fi
(cd "$dir" && "$cosign" generate-key-pair >/dev/null 2>&1) || { echo "error: cosign couldn't make a key" >&2; exit 1; }

echo "Made $(cygpath -w "$dir")\\cosign.key, which is secret, and cosign.pub, which isn't:"
echo
cat "$dir/cosign.pub"
