#!/usr/bin/env bash
# Signs a release the Release workflow published, after finding out it's what it should
# be. A release is on GitHub before this, and nobody is told about it until this has
# run: `zigsaw upgrade` and the daily check want SHA256SUMS.sig, and a key that isn't
# on GitHub is the point of it.
#
#   scripts/sign-release.sh [--anyway] <tag>
#
# It refuses unless:
# - Reproduce passed on the tag's commit. --anyway goes on without that, and says so:
#   v0.73.0 went out on a run that had failed.
# - the release's six programs are the same bytes as a build of the tag here, from a
#   clean worktree. There's no way past this one: if they differ, what's on GitHub
#   isn't what the tag says.
# - VERSION says the tag's version, and SHA256SUMS lists what's there.
# Then it signs SHA256SUMS, checks that with cosign, and uploads SHA256SUMS.sig.
#
# COSIGN_KEY names the key: a cosign.key from scripts/signing-key.sh. Its passphrase is
# asked for, unless COSIGN_PASSWORD has it. Needs Git Bash, git, gh, Zig, and cosign in
# the store. Tests name their own files: SIGN_RELEASE_FROM the release's, instead of
# GitHub's and with no upload, and SIGN_RELEASE_REBUILT a package instead of a build.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/sign-lib.sh
. "$root/scripts/sign-lib.sh"

anyway=false
if [ "${1:-}" = --anyway ]; then
    anyway=true
    shift
fi
[ $# -eq 1 ] || { echo "usage: scripts/sign-release.sh [--anyway] <tag>" >&2; exit 2; }
tag=$1
version=${tag#v}
check_key
cosign=$(find_cosign)

work=$(mktemp -d)
worktree=
cleanup() {
    [ -z "$worktree" ] || git -C "$root" worktree remove --force "$worktree" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

# --- The tag's run --------------------------------------------------------------------
if [ -z "${SIGN_RELEASE_FROM:-}" ]; then
    commit=$(git -C "$root" rev-list -n 1 "$tag")
    result=$(gh run list --repo zigsaw-io/zigsaw --workflow Reproduce --commit "$commit" --status completed --limit 1 --json conclusion --jq '.[0].conclusion // "none"')
    if [ "$result" != success ]; then
        if ! $anyway; then
            echo "error: Reproduce on $tag's commit (${commit:0:7}) says: $result. Nothing was signed. --anyway signs it regardless" >&2
            exit 1
        fi
        echo "warning: Reproduce on $tag's commit (${commit:0:7}) says: $result, and this goes on, as told"
    fi
fi

# --- What's on GitHub ------------------------------------------------------------------
release="$work/release"
mkdir -p "$release"
if [ -n "${SIGN_RELEASE_FROM:-}" ]; then
    cp "$SIGN_RELEASE_FROM/zigsaw-x86_64-windows.zip" "$SIGN_RELEASE_FROM/SHA256SUMS" "$SIGN_RELEASE_FROM/VERSION" "$release/"
else
    gh release download "$tag" --repo zigsaw-io/zigsaw --dir "$release" --pattern zigsaw-x86_64-windows.zip --pattern SHA256SUMS --pattern VERSION
fi
[ "$(tr -d '\r\n' <"$release/VERSION")" = "$version" ] ||
    { echo "error: the release's VERSION says $(cat "$release/VERSION"), not $version. Nothing was signed" >&2; exit 1; }
for f in zigsaw-x86_64-windows.zip VERSION; do
    want=$(sed -n "s/^\([0-9a-f]\{64\}\) .*$f\$/\1/p" "$release/SHA256SUMS")
    got=$(sha256sum <"$release/$f" | cut -d' ' -f1)
    [ "$want" = "$got" ] || { echo "error: SHA256SUMS lists ${want:-nothing} for $f, which is $got. Nothing was signed" >&2; exit 1; }
done

# --- A build of the tag, here ------------------------------------------------------------
if [ -n "${SIGN_RELEASE_REBUILT:-}" ]; then
    rebuilt=$SIGN_RELEASE_REBUILT
else
    worktree="$work/tree"
    git -C "$root" worktree add --quiet --detach "$worktree" "$tag"
    git -C "$worktree" submodule --quiet update --init
    rebuilt="$work/rebuilt"
    echo "Building $tag, which takes a minute."
    (cd "$worktree" && bash scripts/package.sh "$rebuilt") >"$work/package.log" 2>&1 ||
        { echo "error: building $tag failed: $(tail -1 "$work/package.log"). Nothing was signed" >&2; exit 1; }
fi
unpack() { powershell -NoProfile -Command "Expand-Archive -LiteralPath '$(cygpath -w "$1")' -DestinationPath '$(cygpath -w "$2")'"; }
unpack "$release/zigsaw-x86_64-windows.zip" "$work/theirs"
unpack "$rebuilt/zigsaw-x86_64-windows.zip" "$work/ours"
for f in zigsaw.exe zigsaw-shim.exe zigsaw-shimw.exe zigsaw-relay.exe zigsaw-host.exe zigsaw-notify.exe; do
    cmp -s "$work/theirs/$f" "$work/ours/$f" ||
        { echo "error: the release's $f isn't what $tag builds here. Nothing was signed" >&2; exit 1; }
done
echo "All six programs are the same bytes as a build of $tag here."

# --- The signature ---------------------------------------------------------------------
ask_passphrase
sign_blob "$(cygpath -w "$release/SHA256SUMS")" "$(cygpath -w "$release/SHA256SUMS.sig")"
if [ -n "${SIGN_RELEASE_FROM:-}" ]; then
    cp "$release/SHA256SUMS.sig" "$SIGN_RELEASE_FROM/"
    echo "Signed $tag's SHA256SUMS: $(cygpath -w "$SIGN_RELEASE_FROM")\\SHA256SUMS.sig"
else
    gh release upload "$tag" "$release/SHA256SUMS.sig" --repo zigsaw-io/zigsaw
    echo "Signed $tag, and uploaded SHA256SUMS.sig. zigsaw's daily check can tell people now."
fi
