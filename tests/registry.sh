#!/usr/bin/env bash
# End-to-end checks for `zigsaw push` and `zigsaw pull` against a real
# registry: apps round-trip between two stores through it, byte for byte,
# builds take sources that are gone from their URLs from next to images, and
# `search` and `info` find apps through the registry's catalog.
#
#   tests/registry.sh [registry-host] [path\to\zigsaw.exe]
#
# The registry defaults to localhost:5000 and must already be running with no
# authentication, for example zot (https://zotregistry.dev). Also makes
# read-only requests to ghcr.io and Docker Hub.
#
# To also check registry logins, run a second registry that requires one and
# set AUTH_REGISTRY (e.g. localhost:5001), AUTH_USER and AUTH_PASSWORD. The
# checks save a login for AUTH_REGISTRY in Windows Credential Manager and
# remove it at the end, so use a registry on localhost. tests/zot.sh starts
# both registries and sets these:
#   tests/zot.sh bash tests/registry.sh
#
# Set SEED_DOWNLOADS to another store's cache\downloads to take the busybox
# and Node downloads from there.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
registry=${1:-localhost:5000}
zigsaw=${2:-$root/zig-out/bin/zigsaw.exe}
if ! curl -sf "http://${registry/localhost/127.0.0.1}/v2/" >/dev/null; then
    echo "no registry answers at $registry; start one first (see the top of this script)"
    exit 1
fi

work=$(cygpath -w "$(mktemp -d)")
repo="$registry/zigsaw-test-$RANDOM"
# Docker's logins are the test's own (none, until the checks write some),
# not those of whoever runs it.
export DOCKER_CONFIG="$work\\docker"
mkdir -p "$DOCKER_CONFIG"

# Two stores: apps are built in one, pushed, and pulled into the other.
store_a="$work\\a"
store_b="$work\\b"
za() { ZIGSAW_HOME="$store_a" "$zigsaw" "$@"; }
zb() { ZIGSAW_HOME="$store_b" "$zigsaw" "$@"; }
# SEED_DOWNLOADS: another store's cache\downloads, whose files are linked, or
# copied, into store a's, so as not to download them again.
if [ -n "${SEED_DOWNLOADS:-}" ]; then
    mkdir -p "$store_a\\cache\\downloads"
    cp -l "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$store_a")/cache/downloads/" 2>/dev/null ||
        cp -n "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$store_a")/cache/downloads/"
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
fails() { ! "$@"; }

za build "$root/recipes/busybox.json" >/dev/null 2>&1 || { echo "building busybox failed"; exit 1; }
digest=$(za list | awk '$1 == "net.frippery.busybox" { print $3 }')

tags_list() { curl -s "http://${registry/localhost/127.0.0.1}/v2/${repo#*/}/busybox/tags/list" | grep -q FRP-6075-g169694ebd; }
second_push() { [ "$(za -v push net.frippery.busybox "$repo/busybox" 2>&1 | grep -c ' upload ')" -eq 0 ]; }
pulled_runs() { [ "$(zb run net.frippery.busybox echo pulled | tr -d '\r')" = pulled ]; }
same_digest() { [ "$(zb list | awk '$1 == "net.frippery.busybox" { print $3 }')" = "$digest" ]; }
missing_tag() { zb pull "$repo/busybox:nope" 2>&1 | grep -q 'not found'; }
# Container images, as found on real registries, are refused, not installed.
refused() { zb pull "$1" 2>&1 | grep -qE 'not a zigsaw app|none for windows/amd64'; }

check "push" za push net.frippery.busybox "$repo/busybox"
check "the tag defaults to the app's version" tags_list
check "pushing again uploads nothing" second_push
check "pull into an empty store" zb pull "$repo/busybox:FRP-6075-g169694ebd"
check "the pulled app runs" pulled_runs
check "the pulled image has the pushed digest" same_digest
full_digest=$(grep -o 'sha256:[0-9a-f]*' "$store_a\\refs\\net.frippery.busybox.json")
check "pull by digest" zb pull "$repo/busybox@$full_digest"
check "a digest that doesn't match is refused" fails zb pull "$repo/busybox@sha256:$(printf '0%.0s' {1..64})"
check "a missing tag is reported" missing_tag
check "the pulled app's commands are installed" test -f "$store_b\\bin\\busybox.exe"

# Blobs bigger than a chunk go up in chunks (64 KiB here, 64 MiB unless
# ZIGSAW_UPLOAD_CHUNK_SIZE says), and one that breaks off goes on from where
# the registry got to.
pulls_back() { # <repository>: into a fresh store, the pushed digest
    ZIGSAW_HOME="$work\\chunks" "$zigsaw" pull "$1:FRP-6075-g169694ebd" >/dev/null 2>&1 &&
        [ "$(ZIGSAW_HOME="$work\\chunks" "$zigsaw" list | awk '$1 == "net.frippery.busybox" { print $3 }')" = "$digest" ]
}
in_chunks() {
    local out
    out=$(ZIGSAW_UPLOAD_CHUNK_SIZE=65536 za -v push net.frippery.busybox "$repo/busybox-chunks" 2>&1) || { echo "$out"; return 1; }
    grep -q "sent .* in [0-9]* chunks" <<<"$out" || { echo "$out"; return 1; }
    pulls_back "$repo/busybox-chunks"
}
broken_chunk() {
    local out
    out=$(ZIGSAW_UPLOAD_CHUNK_SIZE=65536 ZIGSAW_TEST_UPLOAD_BREAK=3 za push net.frippery.busybox "$repo/busybox-broken" 2>&1) || { echo "$out"; return 1; }
    grep -qE "broke off .*(at [0-9]* of [0-9]* bytes; resuming|starting it again)" <<<"$out" || { echo "$out"; return 1; }
    ZIGSAW_HOME="$work\\chunks" "$zigsaw" rm net.frippery.busybox >/dev/null 2>&1
    pulls_back "$repo/busybox-broken"
}
# A chunk that doesn't start where the registry got to
# (ZIGSAW_TEST_UPLOAD_SKIP) gets an error (HTTP 416); asked, zot says how
# much it has, and the upload goes on from there. A registry that can't say,
# as ghcr.io couldn't (ZIGSAW_TEST_UPLOAD_LOST asks after an upload zot
# doesn't know), gets the blob in one request. An upload the registry has
# lost (ZIGSAW_TEST_UPLOAD_LOSE sends a chunk to one zot doesn't know) goes
# again from the start, in chunks if it broke off before (zot drops one
# that broke off a moment after it may still have answered for it), and
# otherwise in one request.
failed_chunk() {
    local out
    out=$(ZIGSAW_UPLOAD_CHUNK_SIZE=65536 ZIGSAW_TEST_UPLOAD_SKIP=2 za push net.frippery.busybox "$repo/busybox-skip" 2>&1) || { echo "$out"; return 1; }
    grep -qE "failed \(HTTP 416\) at [0-9]* of [0-9]* bytes; resuming" <<<"$out" || { echo "$out"; return 1; }
    ZIGSAW_HOME="$work\\chunks" "$zigsaw" rm net.frippery.busybox >/dev/null 2>&1
    pulls_back "$repo/busybox-skip"
}
lost_chunk() {
    local out
    out=$(ZIGSAW_UPLOAD_CHUNK_SIZE=65536 ZIGSAW_TEST_UPLOAD_SKIP=2 ZIGSAW_TEST_UPLOAD_LOST=1 za push net.frippery.busybox "$repo/busybox-lost" 2>&1) || { echo "$out"; return 1; }
    grep -q "failed a chunk of .* (HTTP 416) and can't say how much of it it has (HTTP 404); uploading it in one request" <<<"$out" || { echo "$out"; return 1; }
    ZIGSAW_HOME="$work\\chunks" "$zigsaw" rm net.frippery.busybox >/dev/null 2>&1
    pulls_back "$repo/busybox-lost"
}
lost_upload() { # <repository> <expected note> <test hooks...>
    local repository=$1 note=$2 out
    shift 2
    out=$(env ZIGSAW_UPLOAD_CHUNK_SIZE=65536 "$@" ZIGSAW_HOME="$store_a" "$zigsaw" push net.frippery.busybox "$repository" 2>&1) || { echo "$out"; return 1; }
    grep -q "$note" <<<"$out" || { echo "$out"; return 1; }
    ZIGSAW_HOME="$work\\chunks" "$zigsaw" rm net.frippery.busybox >/dev/null 2>&1
    pulls_back "$repository"
}
check "push in chunks, which pull back as pushed" in_chunks
check "  a chunk that breaks off goes again from where the registry got to" broken_chunk
check "  so does one the registry fails" failed_chunk
check "  and if it can't say how much it has, the blob goes in one request" lost_chunk
check "  an upload the registry lost after a break goes again in chunks" lost_upload "$repo/busybox-lose" \
    "lost the upload of .*, which broke off, at [0-9]* of [0-9]* bytes (HTTP 404); starting it again" ZIGSAW_TEST_UPLOAD_BREAK=3 ZIGSAW_TEST_UPLOAD_LOSE=4
check "  and one it lost otherwise, in one request" lost_upload "$repo/busybox-lose2" \
    "lost the upload of .* at [0-9]* of [0-9]* bytes (HTTP 404); uploading it in one request" ZIGSAW_TEST_UPLOAD_LOSE=3

# Images built before iteration 7 have plain tar layers. One made here from
# busybox's (its layer decompressed and uploaded, its manifest rewritten)
# still pulls into an empty store, runs, and pushes.
plain_image() {
    local host=${registry/localhost/127.0.0.1} manifest old_hex old_size tar hex size location
    local api="http://$host/v2/${repo#*/}/busybox"
    manifest=$(cygpath -u "$store_a\\blobs\\sha256\\${full_digest#sha256:}")
    old_hex=$(grep -o 'sha256:[0-9a-f]*' "$manifest" | tail -1 | cut -d: -f2)
    old_size=$(stat -c %s "$(cygpath -u "$store_a\\blobs\\sha256\\$old_hex")")
    # A Windows path: curl, not an MSYS program, gets its arguments as they
    # are (MSYS_NO_PATHCONV), so no /dev/null either.
    tar="$work\\plain.tar"
    gzip -dc "$(cygpath -u "$store_a\\blobs\\sha256\\$old_hex")" >"$tar" || return 1
    # From stdin: given a name with backslashes, sha256sum escapes it, and
    # starts its line with a backslash.
    hex=$(sha256sum <"$tar" | cut -d' ' -f1)
    size=$(stat -c %s "$tar")
    # The POST's answer has headers only.
    location=$(curl -sf -X POST -D - "$api/blobs/uploads/" | tr -d '\r' | sed -n 's/^[Ll]ocation: //p')
    case $location in /*) location="http://$host$location" ;; esac
    case $location in *\?*) location="$location&digest=sha256%3A$hex" ;; *) location="$location?digest=sha256%3A$hex" ;; esac
    curl -sf -X PUT -H 'Content-Type: application/octet-stream' --data-binary @"$tar" "$location" >/dev/null || { echo "uploading the plain layer failed"; return 1; }
    sed -e 's/layer\.v1\.tar+gzip/layer.v1.tar/' -e "s/$old_hex/$hex/" -e "s/\"size\": $old_size\$/\"size\": $size/" "$manifest" >"$tar.json"
    curl -sf -X PUT -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' --data-binary @"$tar.json" "$api/manifests/plain" >/dev/null || { echo "uploading the manifest failed"; return 1; }
    ZIGSAW_HOME="$work\\plain" "$zigsaw" pull "$repo/busybox:plain" >/dev/null 2>&1 || { echo "pull failed"; return 1; }
    [ "$(ZIGSAW_HOME="$work\\plain" "$zigsaw" run net.frippery.busybox echo plain | tr -d '\r')" = plain ] || { echo "it doesn't run"; return 1; }
    ZIGSAW_HOME="$work\\plain" "$zigsaw" push net.frippery.busybox "$repo/busybox-plain" >/dev/null 2>&1 || { echo "push failed"; return 1; }
}
check "an image with a plain tar layer pulls, runs and pushes" plain_image

# `update` follows the tag an app was pulled by, and leaves a digest alone.
za push net.frippery.busybox "$repo/busybox:latest" >/dev/null 2>&1
zb pull "$repo/busybox:latest" >/dev/null 2>&1
update_up_to_date() { zb update net.frippery.busybox 2>&1 | grep -q 'up to date'; }
update_moved_tag() {
    sed 's/"version": "[^"]*"/"version": "reg-2"/' "$root/recipes/busybox.json" >"$work\\busybox-2.json" &&
        za build "$work\\busybox-2.json" >/dev/null 2>&1 &&
        za push net.frippery.busybox "$repo/busybox:latest" >/dev/null 2>&1 &&
        zb update net.frippery.busybox >/dev/null 2>&1 &&
        zb list | grep -q '^net.frippery.busybox  *reg-2 '
}
update_pinned() { zb pull "$repo/busybox@$full_digest" >/dev/null 2>&1 && zb update net.frippery.busybox 2>&1 | grep -q pinned; }
check "update: an unmoved tag is up to date" update_up_to_date
check "update: a moved tag is pulled again" update_moved_tag
check "update: an app pulled by digest is pinned" update_pinned
# Back to the recipe's version, which the checks below push and pull.
za build "$root/recipes/busybox.json" >/dev/null 2>&1

# Multi-platform indexes, made here from the two busybox images in the
# repository: the recipe's as windows/amd64, and reg-2 as linux/arm64.
index_api="http://${registry/localhost/127.0.0.1}/v2/${repo#*/}/busybox"
reg2=$(curl -sf -I -H 'Accept: application/vnd.oci.image.manifest.v1+json' "$index_api/manifests/latest" | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: //p')
entry() { # <digest> <os> <architecture>
    local size
    size=$(curl -sf -H 'Accept: application/vnd.oci.image.manifest.v1+json' "$index_api/manifests/$1" | wc -c)
    printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s","size":%d,"platform":{"architecture":"%s","os":"%s"}}' "$1" "$size" "$3" "$2"
}
put_index() { # <tag> <entries...>: prints the index's digest
    local tag=$1 file="$work\\index-$1.json"
    shift
    local IFS=,
    printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[%s]}' "$*" >"$file"
    curl -sf -X PUT -H 'Content-Type: application/vnd.oci.image.index.v1+json' --data-binary @"$file" "$index_api/manifests/$tag" >/dev/null || return 1
    echo "sha256:$(sha256sum <"$file" | cut -d' ' -f1)"
}
index_digest=$(put_index multi "$(entry "$reg2" linux arm64)" "$(entry "$full_digest" windows amd64)")
put_index linux-only "$(entry "$reg2" linux arm64)" >/dev/null
zi() { ZIGSAW_HOME="$work\\idx" "$zigsaw" "$@"; }
index_pull() {
    local out
    out=$(zi pull "$repo/busybox:multi" 2>&1) || { echo "$out"; return 1; }
    grep -q "is a multi-platform index" <<<"$out" || { echo "$out"; return 1; }
    [ "$(zi list | awk '$1 == "net.frippery.busybox" { print $3 }')" = "$digest" ]
}
index_pinned() {
    zi pull "$repo/busybox@$index_digest" >/dev/null 2>&1 &&
        [ "$(zi list | awk '$1 == "net.frippery.busybox" { print $3 }')" = "$digest" ]
}
index_info() { zi info "$repo/busybox:multi" | grep -q "index .*$index_digest"; }
linux_only() { zi pull "$repo/busybox:linux-only" 2>&1 | grep -q 'with images for linux/arm64; none for windows/amd64'; }
check "pull from a multi-platform index takes its image for windows/amd64" index_pull
check "  update: an unchanged index is up to date" sh -c "ZIGSAW_HOME='$work\\idx' \"\$0\" update net.frippery.busybox 2>&1 | grep -q 'up to date'" "$zigsaw"
check "  pull by the index's digest" index_pinned
check "  info shows the index" index_info
check "an index without an image for windows/amd64 is refused, naming its platforms" linux_only

# App ids name images in the default registry, here the test registry.
sza() { ZIGSAW_REGISTRY="$repo" ZIGSAW_HOME="$store_a" "$zigsaw" "$@"; }
szb() { ZIGSAW_REGISTRY="$repo" ZIGSAW_HOME="$store_b" "$zigsaw" "$@"; }
check "push by app id" sza push net.frippery.busybox
short_pull() {
    szb pull net.frippery.busybox:FRP-6075-g169694ebd >/dev/null 2>&1 &&
        grep -q "\"source\": \"$repo/net.frippery.busybox:FRP-6075-g169694ebd\"" "$store_b\\refs\\net.frippery.busybox.json"
}
check "pull by app id; the ref records the full reference" short_pull
check "pull by app id defaults to :latest" sh -c "ZIGSAW_REGISTRY='$repo' ZIGSAW_HOME='$store_a' \"\$0\" push net.frippery.busybox net.frippery.busybox:latest && ZIGSAW_REGISTRY='$repo' ZIGSAW_HOME='$store_b' \"\$0\" pull net.frippery.busybox" "$zigsaw"
other_app_image() {
    za push net.frippery.busybox "$repo/org.example.other:1" >/dev/null 2>&1 &&
        szb pull org.example.other:1 2>&1 | grep -q 'holds net.frippery.busybox, not org.example.other'
}
check "pull by app id refuses an image of another app" other_app_image
check "push by app id refuses another app's image" sh -c "ZIGSAW_REGISTRY='$repo' ZIGSAW_HOME='$store_a' \"\$0\" push net.frippery.busybox org.example.other:2 2>&1 | grep -q 'is the image of org.example.other'" "$zigsaw"

# The catalog: push --catalog lists apps as the registry has them at their
# latest tag, and search and info read it. A second app has a name, a summary
# and a kind of file of its own.
CAT=test.registry.catalog
sed -e "s/\"net.frippery.busybox\"/\"$CAT\"/" \
    -e 's|"command": "busybox.exe",|&\n  "name": "Catalog Shell",\n  "summary": "A shell for the catalog checks",\n  "license": "GPL-2.0-only",\n  "homepage": "https://example.com/catalog",\n  "permissions": { "filesystem": ["documents"] },\n  "associations": { ".zct": { "command": "busybox", "description": "Zigsaw catalog test" } },|' \
    "$root/recipes/busybox.json" >"$work\\catalog-app.json"
za build "$work\\catalog-app.json" >/dev/null 2>&1 || echo "building $CAT failed"
sza push $CAT >/dev/null 2>&1 && sza push $CAT $CAT:latest >/dev/null 2>&1
catalog_pushed() { sza push --catalog net.frippery.busybox $CAT 2>&1 | grep -q 'pushed the catalog of 2 app(s)'; }
search_all() {
    local out
    out=$(szb search) && grep -q '^net.frippery.busybox .*commands: busybox' <<<"$out" &&
        grep -q "^$CAT .*Catalog Shell: A shell for the catalog checks" <<<"$out"
}
search_words() {
    local out
    out=$(szb search catalog SHELL) && grep -q "^$CAT " <<<"$out" && ! grep -q '^net.frippery' <<<"$out"
}
search_kind() { szb search .zct | grep -q "^$CAT "; }
no_match() { ! szb search no-such-app-anywhere >/dev/null 2>&1; }
info_catalog_app() {
    local out
    out=$(szb info $CAT) && grep -q 'Catalog Shell' <<<"$out" && grep -q 'permits *your Documents' <<<"$out" &&
        grep -q 'license *GPL-2.0-only' <<<"$out" && grep -q 'opens *.zct' <<<"$out" && grep -q 'installed *no' <<<"$out"
}
info_any_image() { szb info "$repo/busybox:FRP-6075-g169694ebd" | grep -q '^net.frippery.busybox FRP-6075-g169694ebd'; }
unknown_app() { ! sza push --catalog net.frippery.busybox org.example.none >/dev/null 2>&1; }
told_first() {
    local out told installed
    out=$(szb pull $CAT 2>&1) || return 1
    told=$(grep -n 'permits  your Documents' <<<"$out" | cut -d: -f1)
    installed=$(grep -n '^installed' <<<"$out" | cut -d: -f1)
    [ -n "$told" ] && [ -n "$installed" ] && [ "$told" -lt "$installed" ] && ! grep -q '^  permits' <<<"$(sed -n "$installed,\$p" <<<"$out")"
}
# The copy kept in the cache, when the registry can't be reached: the same
# catalog, as another registry's.
offline() {
    local cache="$store_b\\cache\\catalog" name="${repo//[^A-Za-z0-9.-]/_}_catalog_latest"
    local other="localhost:5999/${repo#*/}"
    local other_name="${other//[^A-Za-z0-9.-]/_}_catalog_latest" out
    cp "$cache\\$name.json" "$cache\\$other_name.json" && cp "$cache\\$name.digest" "$cache\\$other_name.digest" || return 1
    out=$(ZIGSAW_REGISTRY="$other" ZIGSAW_HOME="$store_b" "$zigsaw" search catalog 2>&1) &&
        grep -q "using the catalog of $other fetched on" <<<"$out" && grep -q "^$CAT " <<<"$out"
}
check "push --catalog lists apps as the registry has them" catalog_pushed
check "search lists them all, by name and summary, or commands" search_all
check "search finds what has every word, ignoring case" search_words
check "search finds the kinds of file an app opens" search_kind
check "search fails when nothing matches" no_match
check "info shows an app's name, licence, permissions and kinds of file" info_catalog_app
check "info shows any image, in the catalog or not" info_any_image
check "push --catalog refuses an app the registry doesn't have" unknown_app
check "pull tells what the app may reach before downloading it" told_first
check "search uses the catalog kept from earlier when the registry can't be reached" offline
check "an app can't have the id catalog" sh -c "sed 's/\"net.frippery.busybox\"/\"catalog\"/' '$root/recipes/busybox.json' > '$work\\catalog-id.json' && ! ZIGSAW_HOME='$store_a' \"\$0\" build '$work\\catalog-id.json' >/dev/null 2>&1" "$zigsaw"

# Sources next to images: push --sources keeps the files an app was built
# from in its image's repository, and a build whose pinned source can't be
# had from its URL takes it from there, by its sha256. Each build below is in
# a fresh store, against a local web server: busybox's httpd.
pushed_sources() { sza push --sources net.frippery.busybox 2>&1 | grep -q 'pushed its 1 source file(s) next to it, as sha256-[0-9a-f]*.sources'; }
check "push --sources keeps busybox's source next to its image" pushed_sources
bb_exe=$(find "$(cygpath -u "$store_a")/deploy" -name busybox.exe | head -1)
mkdir -p "$work\\www"
"$bb_exe" httpd -f -p 127.0.0.1:18098 -h "$work\\www" &
httpd=$!
bb_file=busybox-w64-FRP-6075-g169694ebd.exe
sed "s|https://frippery.org/files/busybox/$bb_file|http://127.0.0.1:18098/$bb_file|" "$root\\recipes\\busybox.json" >"$work\\busybox-local.json"
# from_sources <recipe> <store>: builds it in the new store <store>, which
# must take its source from next to the image, and make the same image as
# store_a's.
from_sources() {
    local out
    out=$(ZIGSAW_REGISTRY="$repo" ZIGSAW_HOME="$work\\$2" "$zigsaw" build "$1" 2>&1) || { echo "$out" | tail -2; return 1; }
    grep -q "fetching sha256 07bb1e5b095b from the sources next to $repo/net.frippery.busybox" <<<"$out" && grep -q "manifest $full_digest" <<<"$out"
}
check "a source whose URL is gone comes from next to its image" from_sources "$work\\busybox-local.json" fresh1
echo "not busybox" >"$work\\www\\$bb_file"
check "and one whose URL serves other bytes" from_sources "$work\\busybox-local.json" fresh2
missing_everywhere() {
    sed 's/"net.frippery.busybox"/"test.registry.nosources"/' "$work\\busybox-local.json" >"$work\\nosources.json"
    ZIGSAW_REGISTRY="$repo" ZIGSAW_HOME="$work\\fresh-none" "$zigsaw" build "$work\\nosources.json" 2>&1 |
        grep -q "and the sources next to $repo/test.registry.nosources don't have it"
}
check "without sources next to the image, the build fails, saying so" missing_everywhere
kill $httpd 2>/dev/null

# A vendor step's result is kept with the sources too, and taken from there
# when its commands fail.
VENDORED=test.registry.vendored
vendor_recipe() {
    printf '{ "id": "%s", "version": "1", "command": "x.txt", "exports": {}, "sdk": { "busybox": "net.frippery.busybox@%s" },\n  "modules": [{ "name": "m", "vendor": { "commands": ["%s"], "dir": "deps"%s }, "build": ["cp deps/x.txt \\"$PREFIX/x.txt\\""] }] }\n' \
        $VENDORED "$full_digest" "$1" "${2:-}"
}
vendor_recipe 'mkdir -p deps && echo vendored > deps/x.txt' >"$work\\vendor-unpinned.json"
vendor_hash=$(za build "$work\\vendor-unpinned.json" 2>&1 | grep -o '"sha256": "[0-9a-f]*"' | cut -d'"' -f4)
vendor_recipe 'mkdir -p deps && echo vendored > deps/x.txt' ", \"sha256\": \"$vendor_hash\"" >"$work\\vendor.json"
vendor_recipe 'exit 3' ", \"sha256\": \"$vendor_hash\"" >"$work\\vendor-failing.json"
za build "$work\\vendor.json" >/dev/null 2>&1
vendored_digest=$(grep -o 'sha256:[0-9a-f]*' "$store_a\\refs\\$VENDORED.json")
vendor_from_sources() {
    local out
    sza push --sources $VENDORED >/dev/null 2>&1 || { echo "push --sources failed"; return 1; }
    out=$(ZIGSAW_REGISTRY="$repo" ZIGSAW_HOME="$work\\fresh-vendor" "$zigsaw" build "$work\\vendor-failing.json" 2>&1) || { echo "$out" | tail -2; return 1; }
    grep -q "module m's vendored files: its vendor commands failed; fetching sha256 ${vendor_hash:0:12}" <<<"$out" &&
        grep -q "manifest $vendored_digest" <<<"$out"
}
check "a vendor step whose commands fail takes what they make from next to the image" vendor_from_sources

# A large app: its 100 MB layer streams both ways.
za build "$root\\recipes\\node.json" >/dev/null 2>&1 || { echo "building node failed"; exit 1; }
node_chunks() { ZIGSAW_UPLOAD_CHUNK_SIZE=16777216 za -v push org.nodejs.node "$repo/node" 2>&1 | grep -q "sent .* in 3 chunks"; }
check "push node (100 MB, 38 MB compressed), in 16 MiB chunks" node_chunks
check "pull node" zb pull "$repo/node:24.21.0"
check "the pulled node runs" zb run org.nodejs.node -e 'process.exit(0)'

# An app with a runtime: the runtime's layer travels in the app's image, and
# a pull brings it without installing the runtime as an app.
za build "$root\\recipes\\prettier.json" >/dev/null 2>&1 || { echo "building prettier (on node) failed"; exit 1; }
store_d="$work\\d"
zd() { ZIGSAW_HOME="$store_d" "$zigsaw" "$@"; }
check "push an app with a runtime" za push io.prettier.prettier "$repo/prettier"
check "pull it into an empty store" zd pull "$repo/prettier:3.9.9"
check "it runs on the runtime its image brought" sh -c "ZIGSAW_HOME='$store_d' \"\$0\" run io.prettier.prettier --version | grep -q '^3.9.9'" "$zigsaw"
check "the runtime isn't installed as an app" sh -c "! ZIGSAW_HOME='$store_d' \"\$0\" list | grep -q '^org.nodejs.node '" "$zigsaw"

# Mounts. Pushed by app id, a runtime's image is where pushing an app on it
# by app id looks for the runtime's layer, and mounts it from there instead
# of uploading it.
mounted_runtime() {
    local node_layer out
    node_layer=$(grep -o 'sha256:[0-9a-f]*' "$store_a\\blobs\\sha256\\$(grep -o 'sha256:[0-9a-f]*' "$store_a\\refs\\org.nodejs.node.json" | cut -d: -f2)" | tail -1)
    sza push org.nodejs.node >/dev/null 2>&1 || { echo "pushing node failed"; return 1; }
    out=$(sza -v push io.prettier.prettier 2>&1) || { echo "$out" | tail -1; return 1; }
    grep -q "^mounted $node_layer ([0-9]* bytes) from ${repo#*/}/org.nodejs.node$" <<<"$out" && ! grep -q " upload $node_layer" <<<"$out"
}
check "pushing an app by id mounts its runtime's layer from the runtime's repository" mounted_runtime
# An app pulled from one repository, pushed to another on the same registry:
# all of it is mounted from where it came from.
remounted() {
    local out
    out=$(zd -v push io.prettier.prettier "$repo/prettier-copy" 2>&1) || { echo "$out" | tail -1; return 1; }
    ! grep -q ' upload ' <<<"$out" && [ "$(grep -c ' mount sha256:' <<<"$out")" -eq 3 ] || { echo "$out" | grep -E 'upload|mount' | tail -3; return 1; }
}
check "pushing a pulled app to another repository mounts all of it" remounted

# Real registries, read-only: the token flow works.
check "ghcr.io: token, container image refused" refused ghcr.io/oras-project/oras:v1.2.0
# Credentials in the environment are for the default registry (ghcr.io), so
# Docker Hub never sees them; if it did, it would refuse these.
docker_hub() { ZIGSAW_REGISTRY_USERNAME=zigsaw-nobody ZIGSAW_REGISTRY_PASSWORD=wrong refused docker.io/library/alpine:3.20; }
check "Docker Hub: anonymous token despite credentials for ghcr.io" docker_hub

if [ -n "${AUTH_REGISTRY:-}" ]; then
    auth_repo="$AUTH_REGISTRY/zigsaw-test-$RANDOM/busybox"
    auth_tag="$auth_repo:FRP-6075-g169694ebd"
    # Logins are per user, not per store: start and end logged out.
    za logout "$AUTH_REGISTRY" >/dev/null 2>&1
    # A fresh store, so the pulls below really fetch from the login registry.
    store_c="$work\c"
    zc() { ZIGSAW_HOME="$store_c" "$zigsaw" "$@"; }
    asks_for_login() { "$@" 2>&1 | grep -q "zigsaw login $AUTH_REGISTRY"; }
    # The right credentials, in the environment: they only go to the default registry.
    env_login() { ZIGSAW_REGISTRY_USERNAME="$AUTH_USER" ZIGSAW_REGISTRY_PASSWORD="$AUTH_PASSWORD" "$@"; }
    env_default() { ZIGSAW_REGISTRY="$AUTH_REGISTRY/zigsaw-test" env_login "$@"; }
    env_refused() {
        ZIGSAW_REGISTRY="$AUTH_REGISTRY/zigsaw-test" ZIGSAW_REGISTRY_USERNAME="$AUTH_USER" ZIGSAW_REGISTRY_PASSWORD=wrong \
            za push net.frippery.busybox "$auth_repo" 2>&1 | grep -q 'refused the credentials in ZIGSAW_REGISTRY_USERNAME'
    }
    check "login registry: the environment's credentials don't go to another registry" asks_for_login env_login za push net.frippery.busybox "$auth_repo"
    check "login registry: they go to the default registry" env_default za push net.frippery.busybox "$auth_repo"
    check "login registry: a wrong password there is refused" env_refused
    check "login registry: pull without credentials asks for a login" asks_for_login zc pull "$auth_tag"

    # From here on, nothing in the environment applies.
    no_env() { (unset ZIGSAW_REGISTRY_USERNAME ZIGSAW_REGISTRY_PASSWORD ZIGSAW_REGISTRY && "$@"); }
    login_refused() { echo wrong | za login --username="$AUTH_USER" --password-stdin "$AUTH_REGISTRY" 2>&1 | grep -q 'refused the credentials; nothing was saved'; }
    login_saved() { printf '%s\n' "$AUTH_PASSWORD" | za login --username="$AUTH_USER" --password-stdin "$AUTH_REGISTRY"; }
    login_used() { no_env zc -v pull "$auth_tag" 2>&1 | grep -q "credentials for $AUTH_REGISTRY: $AUTH_USER, saved by .zigsaw login."; }
    logged_out() { za logout "$AUTH_REGISTRY" 2>&1 | grep -q 'removed the login'; }
    check "login: a wrong password is refused" login_refused
    check "login: a refused login isn't saved" asks_for_login no_env za push net.frippery.busybox "$auth_repo"
    check "login: the right password is saved" login_saved
    check "login: push with the saved login" no_env za push net.frippery.busybox "$auth_repo"
    check "login: pull with the saved login" no_env zc pull "$auth_tag"
    check "login: -v says where the credentials came from" login_used
    # Its config and layer, mounted from where they were pulled from.
    login_mounts() { [ "$(no_env zc -v push net.frippery.busybox "$auth_repo-copy" 2>&1 | grep -c ' mount sha256:')" -eq 2 ]; }
    check "login: a pulled app pushed to another repository there is mounted" login_mounts
    check "logout" logged_out
    check "logout: pull asks for a login again" asks_for_login no_env zc pull "$auth_tag"

    # Docker's logins: a config.json of the test's own, and a credential
    # helper that answers from the environment (tests/credhelper.zig).
    (cd "$root" && zig build cred-helper >/dev/null 2>&1) || echo "building the credential helper failed"
    helper_dir=$(cygpath -u "$root\\zig-out\\test")
    docker_config() { printf '%s' "$1" >"$DOCKER_CONFIG\\config.json"; }
    with_helper() {
        PATH="$helper_dir:$PATH" ZIGSAW_TEST_HELPER_SERVER="$1" ZIGSAW_TEST_HELPER_USER="$AUTH_USER" ZIGSAW_TEST_HELPER_SECRET="$AUTH_PASSWORD" \
            "${@:2}"
    }
    pulls_with() { # <origin> <command...>: pulls, with the credentials from there
        local origin=$1 out
        shift
        out=$("$@" -v pull "$auth_tag" 2>&1) || { echo "$out"; return 1; }
        grep -qF "credentials for $AUTH_REGISTRY: $AUTH_USER, $origin" <<<"$out" || { echo "$out"; return 1; }
    }
    auth=$(printf '%s:%s' "$AUTH_USER" "$AUTH_PASSWORD" | base64 -w0)
    docker_auths() { docker_config "{\"auths\": {\"$AUTH_REGISTRY\": {\"auth\": \"$auth\"}}}" && pulls_with "in Docker's config.json" no_env zc; }
    docker_url_key() { docker_config "{\"auths\": {\"http://$AUTH_REGISTRY/v2/\": {\"auth\": \"$auth\"}}}" && pulls_with "in Docker's config.json" no_env zc; }
    docker_cred_helpers() {
        docker_config "{\"credHelpers\": {\"$AUTH_REGISTRY\": \"zigsaw-test\"}}" &&
            with_helper "$AUTH_REGISTRY" pulls_with "from docker-credential-zigsaw-test" no_env zc
    }
    docker_creds_store() {
        docker_config "{\"credsStore\": \"zigsaw-test\", \"auths\": {\"$AUTH_REGISTRY\": {}}}" &&
            with_helper "$AUTH_REGISTRY" pulls_with "from docker-credential-zigsaw-test" no_env zc
    }
    docker_helper_none() { docker_config '{"credsStore": "zigsaw-test"}' && with_helper other.example asks_for_login no_env zc pull "$auth_tag"; }
    zigsaw_login_wins() {
        local wrong
        wrong=$(printf '%s:wrong' "$AUTH_USER" | base64 -w0)
        docker_config "{\"auths\": {\"$AUTH_REGISTRY\": {\"auth\": \"$wrong\"}}}" && login_saved >/dev/null 2>&1 || return 1
        pulls_with "saved by \`zigsaw login\`" no_env zc
        local status=$?
        za logout "$AUTH_REGISTRY" >/dev/null 2>&1
        return $status
    }
    docker_refused() {
        local wrong
        wrong=$(printf '%s:wrong' "$AUTH_USER" | base64 -w0)
        docker_config "{\"auths\": {\"$AUTH_REGISTRY\": {\"auth\": \"$wrong\"}}}" &&
            no_env zc pull "$auth_tag" 2>&1 | grep -q "refused the credentials in Docker's config.json"
    }
    check "docker: a login in config.json's auths" docker_auths
    check "  under a URL there" docker_url_key
    check "docker: a login a credential helper keeps for the registry (credHelpers)" docker_cred_helpers
    check "  or for every registry (credsStore)" docker_creds_store
    check "  a helper without one asks for a login" docker_helper_none
    check "docker: a login zigsaw saved comes first" zigsaw_login_wins
    check "docker: a wrong password in config.json is refused, saying where it came from" docker_refused
    docker_config '{}'
    za logout "$AUTH_REGISTRY" >/dev/null 2>&1
fi

# Installed apps are protected against deletion, so remove them through
# zigsaw, and the images builds use with prune --downloads.
for store in "$work\a" "$work\b" "$work\c" "$work\d" "$work\idx" "$work\chunks" "$work\plain" "$work\fresh1" "$work\fresh2" "$work\fresh-none" "$work\fresh-vendor"; do
    for id in net.frippery.busybox org.nodejs.node io.prettier.prettier test.registry.vendored test.registry.catalog; do ZIGSAW_HOME="$store" "$zigsaw" rm --delete-data "$id" >/dev/null 2>&1; done
    ZIGSAW_HOME="$store" "$zigsaw" prune --downloads >/dev/null 2>&1
done
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
