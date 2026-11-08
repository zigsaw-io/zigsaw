#!/usr/bin/env bash
# Signs, keyless, the images tests/published.sh has just shown to be what their
# recipes build: the lines of its compared.txt, "<id> <version> <digest>". The
# Reproduce workflow's published jobs run it, on main only. There GitHub gives the job
# an identity token: cosign trades it with Sigstore's Fulcio for a certificate naming
# the workflow (.../reproduce.yml@refs/heads/main), signs with that certificate's key,
# and logs the signature in Sigstore's Rekor. zigsaw then puts the bundle beside the
# image (`zigsaw signature push-bundle`), having checked it as pull would. Nothing
# here holds a key, and nobody's asked anything.
#
#   scripts/sign-images.sh <compared.txt>
#
# Images signed keyless already are left alone, so a run that stopped, or Sigstore
# having a bad day (rekor.sigstore.dev answered 500 on 2026-11-07), leaves the rest
# to the next run. It goes on past an image it couldn't sign, and fails at the end.
#
# Needs Git Bash, a built zigsaw (ZIGSAW names another), a login that may push to the
# registry (ZIGSAW_REGISTRY_USERNAME and ZIGSAW_REGISTRY_PASSWORD), and cosign: COSIGN
# names it, or zigsaw's own image of it is pulled into a temporary store. The
# registry is the default one, or ZIGSAW_REGISTRY's.

set -eu
export MSYS_NO_PATHCONV=1

[ $# -eq 1 ] || { echo "usage: scripts/sign-images.sh <compared.txt>" >&2; exit 2; }
root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${ZIGSAW:-$root\\zig-out\\bin\\zigsaw.exe}
signer=https://github.com/zigsaw-io/zigsaw/.github/workflows/reproduce.yml@refs/heads/main
work=$(cygpath -w "$(mktemp -d)")
trap 'rm -rf "$(cygpath -u "$work")"' EXIT

if [ ! -s "$1" ]; then
    echo "Nothing to sign: no image was shown to be what its recipe builds."
    exit 0
fi

cosign=${COSIGN:-}
if [ -z "$cosign" ]; then
    # Its program as it is in the store, not `zigsaw run`: nothing here needs a sandbox,
    # and the identity token goes through the environment.
    ZIGSAW_HOME="$work\\store" ZIGSAW_USER_FOLDERS="$work\\no-folders" "$zigsaw" pull --yes dev.sigstore.cosign >/dev/null
    cosign=$(find "$(cygpath -u "$work\\store\\deploy")" -maxdepth 2 -iname cosign.exe | head -1)
    [ -n "$cosign" ] || { echo "error: cosign's image has no cosign.exe" >&2; exit 1; }
fi

signed=0
already=0
failed=0
while read -r id version digest; do
    [ -n "$id" ] || continue
    image="$id@$digest"
    if "$zigsaw" signature check "$image" 2>&1 | grep -qF "signed, by $signer"; then
        already=$((already + 1))
        continue
    fi
    payload="$work\\$id.payload"
    bundle="$work\\$id.bundle.json"
    if ! "$zigsaw" signature payload "$image" >"$payload"; then
        echo "FAIL  $id $version: no payload for $image"
        failed=$((failed + 1))
        continue
    fi
    ok=false
    for try in 1 2 3; do
        if "$cosign" sign-blob --yes --bundle "$bundle" "$payload" >"$work\\cosign.log" 2>&1; then
            ok=true
            break
        fi
        echo "      $id $version: cosign failed (try $try): $(tail -1 "$work\\cosign.log")"
        sleep $((try * 20))
    done
    if $ok && "$zigsaw" signature push-bundle "$image" "$payload" "$bundle"; then
        echo "ok    $id $version: signed $digest"
        signed=$((signed + 1))
    else
        echo "FAIL  $id $version: not signed"
        failed=$((failed + 1))
    fi
done <"$1"
echo "$signed signed, $already signed already, $failed not signed."
[ "$failed" = 0 ]
