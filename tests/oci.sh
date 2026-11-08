#!/usr/bin/env bash
# The OCI tools (recipes/oras.json, skopeo.json and cosign.json, built from
# source with Go's image), end to end against tests/zot.sh's two local
# registries, at the default sandbox (low), then a few runs in an
# AppContainer: ORAS pushes a file from the working directory and pulls it
# back; skopeo lists, inspects and copies an image zigsaw pushed, to the
# registry that wants a login and into an OCI layout; cosign makes a key
# pair, signs the image with it without the internet (a signing config with
# no services, and a proxy that goes nowhere), and verifies it, but not with
# another key; and zigsaw still pulls the signed image. Each tool logs in
# with its own login, kept in its own data, and logs out again. In an
# AppContainer, what writes to a path (oras pull, skopeo's oci: and dir:)
# fails, a known gap.
#
#   OCI_HOME=path\to\store bash tests/zot.sh bash tests/oci.sh [path\to\zigsaw.exe]
#
# The store (OCI_HOME, or BUILD_HOME as tests/published.sh leaves it, or a
# temporary one) gets the three unless it has them (built in about 3
# minutes, with Go's image, most of it cosign), and loses them afterwards if
# it didn't.
set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
temp_store=""
ZIGSAW_HOME=${OCI_HOME:-${BUILD_HOME:-}}
if [ -z "$ZIGSAW_HOME" ]; then
    ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
    temp_store=$ZIGSAW_HOME
fi
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
ORAS=land.oras.oras
SKOPEO=io.podman.skopeo
COSIGN=dev.sigstore.cosign
: "${AUTH_REGISTRY:?run this with tests/zot.sh}"
registry=localhost:5000

failures=0
# The output's last line, but not zigsaw's notes on what it granted.
last_line() { grep -v -e '^\s*$' -e '^granted ' -e '^revoked ' -e '^labelled ' <<<"$1" | tail -1 | cut -c1-110; }
check() {
    local label=$1
    shift
    local out
    if out=$("$@" 2>&1); then
        printf 'ok    %s\n' "$label"
    else
        printf 'FAIL  %s\n      %s\n' "$label" "$(last_line "$out")"
        failures=$((failures + 1))
    fi
}
# check_gap: check, but a failure is a known gap.
gaps=0
check_gap() {
    local label=$1
    shift
    local out
    if out=$("$@" 2>&1); then
        printf 'ok    %s  (a known gap that passes now)\n' "$label"
    else
        printf 'gap   %s  (known gap)\n      %s\n' "$label" "$(last_line "$out")"
        gaps=$((gaps + 1))
    fi
}

z() { "$zigsaw" "$@"; }
# r <app> [run options] -- <args>: a run of the app, cut off after two minutes.
r() {
    local app=$1 opts=()
    shift
    while [ $# -gt 0 ] && [ "$1" != -- ]; do opts+=("$1"); shift; done
    shift
    timeout 120 "$zigsaw" run "${opts[@]}" "$app" "$@"
}
installed_here=""
for recipe in busybox go oras skopeo cosign; do
    id=$(grep -o '"id": *"[^"]*"' "$root\\recipes\\$recipe.json" | head -1 | cut -d'"' -f4)
    [ -f "$ZIGSAW_HOME\\refs\\$id.json" ] && continue
    installed_here="$installed_here $id"
    z build "$root\\recipes\\$recipe.json" >"$work\\build-$recipe.log" 2>&1 || echo "building $recipe.json failed: $(tail -1 "$work\\build-$recipe.log")"
done

# Runs from the work directory, never the repository: the three have the
# cwd permission, which low runs label and AppContainer runs grant.
mkdir -p "$work\\cwd" && cd "$work\\cwd" || exit 1
printf 'hello from zigsaw\n' >hello.txt
image=$registry/oci/busybox
digest=$(z push net.frippery.busybox "$image:1" 2>&1 | grep -o 'manifest sha256:[0-9a-f]*' | cut -d' ' -f2)
[ -n "$digest" ] || echo "pushing BusyBox's image to $image:1 failed"

# --- ORAS -----------------------------------------------------------------------

check "oras version says 1.3.6" sh -c "\"\$0\" run $ORAS version | grep -q '^Version: *1.3.6'" "$zigsaw"
check "oras pushes a file from the working directory" r $ORAS -- push --plain-http "$registry/oci/files:v1" hello.txt
pulled() {
    r $ORAS -- pull --plain-http -o pulled "$registry/oci/files:v1" >/dev/null || return 1
    cmp hello.txt pulled/hello.txt
}
check "  and pulls it into another folder, the same bytes" pulled
oras_login() {
    printf '%s' "$AUTH_PASSWORD" | r $ORAS -- login --plain-http -u "$AUTH_USER" --password-stdin "$AUTH_REGISTRY" || return 1
    find "$(cygpath -u "$ZIGSAW_HOME\\data\\$ORAS")" -name config.json -path '*.docker*' -exec grep -l "$AUTH_REGISTRY" {} + | grep -q . ||
        { echo "no .docker\\config.json with the login in its data"; return 1; }
}
check "oras logs in to the registry that wants a login, in its own data" oras_login
check "  and pushes there" r $ORAS -- push --plain-http "$AUTH_REGISTRY/oci/files:v1" hello.txt
oras_logout() {
    r $ORAS -- logout "$AUTH_REGISTRY" || return 1
    ! r $ORAS -- push --plain-http "$AUTH_REGISTRY/oci/files:v2" hello.txt
}
check "  and logged out, it's refused there" oras_logout

# --- skopeo ---------------------------------------------------------------------

check "skopeo --version says 1.24.1" sh -c "\"\$0\" run $SKOPEO --version | grep -q 'version 1.24.1'" "$zigsaw"
check "skopeo lists the tags of zigsaw's image" sh -c "\"\$0\" run $SKOPEO list-tags --tls-verify=false docker://$image | grep -q '\"1\"'" "$zigsaw"
# Not plain `inspect`: skopeo takes zigsaw's images, whose config is
# zigsaw's own, for artifacts, and inspects only images.
check "  shows its manifest" sh -c "\"\$0\" run $SKOPEO inspect --raw --tls-verify=false docker://$image:1 | grep -q '\"org.opencontainers.image.title\": \"net.frippery.busybox\"'" "$zigsaw"
skopeo_copy() {
    printf '%s' "$AUTH_PASSWORD" | r $SKOPEO -- login --tls-verify=false -u "$AUTH_USER" --password-stdin "$AUTH_REGISTRY" || return 1
    r $SKOPEO -- copy --src-tls-verify=false --dest-tls-verify=false "docker://$image:1" "docker://$AUTH_REGISTRY/oci/busybox:1" || return 1
    curl -s -u "$AUTH_USER:$AUTH_PASSWORD" "http://$AUTH_REGISTRY/v2/oci/busybox/tags/list" | grep -q '"1"'
}
check "  copies it to the registry that wants a login, with its own login" skopeo_copy
check "  and logs out" r $SKOPEO -- logout "$AUTH_REGISTRY"
# Its default policy (accept anything) is the image's, as copying needs one.
check "  copies it into an OCI layout in the working directory" sh -c "\"\$0\" run $SKOPEO copy --src-tls-verify=false docker://$image:1 oci:layout >/dev/null && test -f layout/index.json" "$zigsaw"
# On Windows, its oci: transport takes a tag only after an absolute path.
check "  and into one with a tag, by its full path" sh -c "\"\$0\" run $SKOPEO copy --src-tls-verify=false docker://$image:1 'oci:$work\\cwd\\tagged:1' >/dev/null && grep -q '\"org.opencontainers.image.ref.name\":\"1\"' tagged/index.json" "$zigsaw"

# --- cosign ---------------------------------------------------------------------

# No internet for cosign: a proxy that goes nowhere, but the local registry
# directly.
offline=(--env=COSIGN_PASSWORD=zigsaw-test --env=HTTPS_PROXY=http://127.0.0.1:9 --env=HTTP_PROXY=http://127.0.0.1:9 --env=NO_PROXY=localhost,127.0.0.1)
check "cosign version says v3.1.4" sh -c "\"\$0\" run $COSIGN version 2>&1 | grep -q '^GitVersion: *v3.1.4'" "$zigsaw"
key_pair() {
    r $COSIGN "${offline[@]}" -- generate-key-pair >/dev/null || return 1
    test -f cosign.key && test -f cosign.pub
}
check "cosign makes a key pair in the working directory" key_pair
cosign_sign() {
    r $COSIGN "${offline[@]}" -- signing-config create --out signing-config.json || return 1
    r $COSIGN "${offline[@]}" -- sign --key cosign.key --signing-config signing-config.json --allow-http-registry --yes "$image@$digest"
}
check "  signs zigsaw's image with it, without the internet" cosign_sign
check "  verifies it with the public key" r $COSIGN "${offline[@]}" -- verify --key cosign.pub --insecure-ignore-tlog --allow-http-registry "$image:1"
other_key() {
    mkdir -p other && (cd other && r $COSIGN "${offline[@]}" -- generate-key-pair >/dev/null) || return 1
    ! r $COSIGN "${offline[@]}" -- verify --key other/cosign.pub --insecure-ignore-tlog --allow-http-registry "$image:1"
}
check "  but not with another key" other_key
check "zigsaw still pulls the signed image" env ZIGSAW_HOME="$work\\pulled" "$zigsaw" pull --yes "$image:1"

# zigsaw's signatures are cosign's: made by the real thing, and read by it.
signed="$registry/oci/signed"
cosign_program=$(find "$(cygpath -u "$ZIGSAW_HOME\\deploy")" -maxdepth 2 -iname cosign.exe | head -1)
signs_blob() {
    z push net.frippery.busybox "$signed:1" >/dev/null 2>&1 || return 1
    z signature payload "$signed:1" >"$work\\cwd\\signed.payload" || return 1
    # As scripts/sign-lib.sh's sign_blob does: with a key, and nothing logged.
    COSIGN_PASSWORD=zigsaw-test "$cosign_program" sign-blob --key "$work\\cwd\\cosign.key" --new-bundle-format=false \
        --use-signing-config=false --tlog-upload=false --yes --output-signature "$work\\cwd\\signed.sig" "$work\\cwd\\signed.payload" >/dev/null 2>&1 || return 1
    z signature push "$signed:1" "$work\\cwd\\signed.payload" "$work\\cwd\\signed.sig"
}
check "the real cosign signs zigsaw's payload with a key, and zigsaw pushes it" signs_blob
cosign_reads() { r $COSIGN "${offline[@]}" -- verify --key cosign.pub --insecure-ignore-tlog --allow-http-registry "$signed:1"; }
check "  stock cosign verify reads what zigsaw pushed" cosign_reads
zigsaw_reads() {
    local out
    ZIGSAW_HOME="$work\\checks" "$zigsaw" trust add "$registry/oci" cosign.pub >/dev/null 2>&1 || return 1
    out=$(ZIGSAW_HOME="$work\\checks" "$zigsaw" pull --yes "$signed:1" 2>&1) || { echo "$out"; return 1; }
    grep -q 'signed, by key' <<<"$out" || { echo "$out"; return 1; }
}
check "  and zigsaw's own check passes it" zigsaw_reads
other_refused() {
    local out
    ZIGSAW_HOME="$work\\checks2" "$zigsaw" trust add "$registry/oci" other/cosign.pub >/dev/null 2>&1 || return 1
    out=$(ZIGSAW_HOME="$work\\checks2" "$zigsaw" pull --yes "$signed:1" 2>&1) && { echo "it installed"; return 1; }
    grep -q 'not by any key that counts' <<<"$out"
}
check "  and with another cosign key, refuses it" other_refused
ZIGSAW_HOME="$work\\checks" "$zigsaw" rm --delete-data net.frippery.busybox >/dev/null 2>&1

# A release, with programs that only have to be the same bytes.
fake_release() { # <dir> <what the programs hold>
    mkdir -p "$1/files"
    for f in zigsaw.exe zigsaw-shim.exe zigsaw-shimw.exe zigsaw-relay.exe zigsaw-host.exe zigsaw-notify.exe; do printf '%s' "$2" >"$1/files/$f"; done
    powershell -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$1/files")\\*' -DestinationPath '$(cygpath -w "$1")\\zigsaw-x86_64-windows.zip'" || return 1
    printf '9.9.9\n' >"$1/VERSION"
    { printf '%s  zigsaw-x86_64-windows.zip\n' "$(sha256sum <"$1/zigsaw-x86_64-windows.zip" | cut -d' ' -f1)"
      printf '%s  VERSION\n' "$(sha256sum <"$1/VERSION" | cut -d' ' -f1)"; } >"$1/SHA256SUMS"
}
# The key as Git Bash writes it, which cosign can't read by itself.
sign_release() { env COSIGN_KEY="$(cygpath -u "$work\\cwd\\cosign.key")" COSIGN_PASSWORD=zigsaw-test COSIGN="$cosign_program" SIGN_RELEASE_FROM="$1" SIGN_RELEASE_REBUILT="$2" bash "$root\\scripts\\sign-release.sh" v9.9.9; }
fake_release rel same && fake_release rebuilt same && fake_release other-build different
release_signed() {
    sign_release rel rebuilt >/dev/null 2>&1 || return 1
    r $COSIGN "${offline[@]}" -- verify-blob --key cosign.pub --insecure-ignore-tlog --signature rel/SHA256SUMS.sig rel/SHA256SUMS
}
check "scripts/sign-release.sh signs a release a build here matches, as cosign checks" release_signed
release_differs() {
    rm -f rel/SHA256SUMS.sig
    local out
    out=$(sign_release rel other-build 2>&1) && { echo "it signed"; return 1; }
    grep -q "isn't what v9.9.9 builds here" <<<"$out" && [ ! -e rel/SHA256SUMS.sig ]
}
check "  and refuses one a build here doesn't" release_differs
release_mislabelled() {
    printf '9.9.8\n' >rel/VERSION
    local out
    out=$(sign_release rel rebuilt 2>&1) && { echo "it signed"; return 1; }
    grep -q "VERSION says" <<<"$out" && [ ! -e rel/SHA256SUMS.sig ]
}
check "  or one whose VERSION isn't the tag's" release_mislabelled
printf '9.9.9\n' >rel/VERSION
# The key, as the rescue's is named: scripts/sign-lib.sh, before anything's signed.
key_named_wrongly() { # <what COSIGN_KEY is> <what the error should say>
    local out
    out=$(env COSIGN_KEY="$1" COSIGN="$cosign_program" SIGN_RELEASE_FROM=rel SIGN_RELEASE_REBUILT=rebuilt bash "$root\\scripts\\sign-release.sh" v9.9.9 2>&1) && { echo "it went on"; return 1; }
    grep -qF "$2" <<<"$out" || { echo "$out"; return 1; }
}
check "  a key's path with its backslashes eaten says so" key_named_wrongly 'E:keyscosign.key' "Git Bash ate them"
check "  a key that's named otherwise says what's there" key_named_wrongly "$work\\cwd\\wrong.key" "cosign.key"
check "  a folder says to name the file" key_named_wrongly "$work\\cwd" "That's a folder"
wrong_passphrase() {
    rm -f rel/SHA256SUMS.sig
    local out
    out=$(env COSIGN_KEY="$work\\cwd\\cosign.key" COSIGN_PASSWORD=not-it COSIGN="$cosign_program" SIGN_RELEASE_FROM=rel SIGN_RELEASE_REBUILT=rebuilt bash "$root\\scripts\\sign-release.sh" v9.9.9 2>&1) && { echo "it went on"; return 1; }
    grep -qF "COSIGN_PASSWORD doesn't open" <<<"$out" || { echo "$out"; return 1; }
    [ ! -e rel/SHA256SUMS.sig ]
}
check "  a passphrase that doesn't open the key says so, and nothing's signed" wrong_passphrase

# --- In an AppContainer -----------------------------------------------------------

ac=(--sandbox=appcontainer)
check "in an AppContainer, oras pushes a file from the working directory" r $ORAS "${ac[@]}" -- push --plain-http "$registry/oci/files:ac" hello.txt
check "  skopeo lists the image's tags" sh -c "\"\$0\" run --sandbox=appcontainer $SKOPEO list-tags --tls-verify=false docker://$image | grep -q '\"1\"'" "$zigsaw"
ac_key_pair() {
    mkdir -p ac-key && (cd ac-key && r $COSIGN "${ac[@]}" "${offline[@]}" -- generate-key-pair >/dev/null) || return 1
    test -f ac-key/cosign.key
}
check "  cosign makes a key pair" ac_key_pair
check "  and verifies the signature" r $COSIGN "${ac[@]}" "${offline[@]}" -- verify --key cosign.pub --insecure-ignore-tlog --allow-http-registry "$image:1"
# Known gaps: writing to a path, both resolve it with Go's
# filepath.EvalSymlinks, which opens each folder from the drive's root down,
# and an AppContainer can't open the folders above its grants (the drive's
# root, your profile, D:\a on a runner).
ac_pull() {
    r $ORAS "${ac[@]}" -- pull --plain-http -o ac "$registry/oci/files:v1" >/dev/null || return 1
    cmp hello.txt ac/hello.txt
}
check_gap "  oras pulls into the working directory" ac_pull
check_gap "  skopeo copies into an OCI layout there" sh -c "\"\$0\" run --sandbox=appcontainer $SKOPEO copy --src-tls-verify=false docker://$image:1 oci:ac-layout >/dev/null && test -f ac-layout/index.json" "$zigsaw"

check "no run labelled or granted the repository" sh -c "! icacls '$root' | grep -q -e 'Mandatory Label' -e 'S-1-15-'"

cd "$root" || exit 1
ZIGSAW_HOME="$work\\pulled" "$zigsaw" rm --delete-data net.frippery.busybox >/dev/null 2>&1
for id in $installed_here; do z rm --delete-data "$id" >/dev/null 2>&1; done
if [ -n "$temp_store" ]; then
    z prune --downloads --data >/dev/null 2>&1
    rm -rf "$temp_store"
fi
rm -rf "$work"
echo
echo "$failures check(s) failed, and $gaps known gap(s)."
exit $((failures > 0))
