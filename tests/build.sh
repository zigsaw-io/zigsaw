#!/usr/bin/env bash
# End-to-end checks for building apps: runtimes, which an app runs with and
# whose layers travel in its image, and build commands, which build an app
# from source with SDK images (zig, busybox and Rust), tools' caches and
# aliases, and vendor steps.
#
#   tests/build.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and network access (busybox, Node, Prettier, zig, zlib,
# SQLite and Rust downloads, and crates from crates.io). Always uses
# temporary stores, since it removes apps, and deletes them afterwards. To
# skip downloading what a store already has (zig's is 97 MB, Rust's 150 MB),
# set SEED_DOWNLOADS to its cache\downloads directory; its files are copied
# into the temporary stores.
#
# The build commands' checks map B:, as every build does, and briefly map it
# themselves with subst. Don't run this while B: is in use.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
bin="$ZIGSAW_HOME\\bin"

# seed <store>: copies SEED_DOWNLOADS into the store's download cache.
seed() {
    [ -n "${SEED_DOWNLOADS:-}" ] || return 0
    mkdir -p "$1\\cache\\downloads" && cp "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$1")/cache/downloads/"
}
seed "$ZIGSAW_HOME"

BB=net.frippery.busybox
APP=test.runtime.app

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

z() { "$zigsaw" "$@"; }
deployments() { find "$ZIGSAW_HOME/deploy" -mindepth 1 -maxdepth 1 -type d | wc -l; }
expect_count() { local got; got=$("$1"); [ "$got" -eq "$2" ] || { echo "$1: got $got, want $2"; return 1; }; }
manifest_of() { grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\refs\\$1.json"; }
# Builds a recipe and prints its manifest digest.
built_manifest() { z build "$1" 2>&1 | grep -o 'manifest sha256:[0-9a-f]*' | cut -d' ' -f2; }
same_image() { [ "$(built_manifest "$1")" = "$2" ]; }

# --- runtimes ---------------------------------------------------------------------

z build "$root\\recipes\\busybox.json" >/dev/null 2>&1 || { echo "building busybox failed"; exit 1; }
bb_digest=$(manifest_of $BB)

# An app whose command is busybox's sh, from a busybox runtime, running a
# script of its own. <runtime> is the runtime reference, <command> its command.
app_recipe() {
    local runtime=$1 command=${2:-busybox.exe} id=${3:-$APP}
    cat <<EOF
{
  "id": "$id",
  "version": "1",
  "command": "\${bb}\\\\$command",
  "args": ["sh", "\${app}\\\\hello.sh"],
  "path": ["tools"],
  "runtimes": { "bb": "$runtime" },
  "exports": {
    "rt-hello": { "command": "\${bb}\\\\$command", "args": ["sh", "\${app}\\\\hello.sh"] },
    "rt-bb": { "command": "\${bb}\\\\$command" }
  },
  "modules": [{ "name": "scripts", "sources": [{ "path": "hello.sh" }, { "path": "hello.sh", "dest": "tools/x.txt" }] }]
}
EOF
}
cp "$root\\tests\\build\\hello.sh" "$work\\hello.sh"
app_recipe "$BB@$bb_digest" >"$work\\app.json"

check "an app with a runtime builds" z build "$work\\app.json"
app_digest=$(manifest_of $APP)
runs() { z run $APP a "b c" | grep -q "^args: a b c" && z run $APP | grep -q "^hello from $APP"; }
check "it runs its command from the runtime" runs
check "it runs through its export shim" sh -c "\"$bin\\\\rt-hello.exe\" x | grep -q '^args: x'"
path_order() {
    local path
    # (BusyBox shows PATH with '/'.)
    path=$(z run --command=rt-bb $APP sh -c 'echo "$PATH"' | tr -d '\r' | tr '/' '\\')
    case "$path" in
    "$ZIGSAW_HOME\\deploy\\"*"\\tools;$ZIGSAW_HOME\\deploy\\"*";"*System32*) ;;
    *) echo "PATH is $path"; return 1 ;;
    esac
}
check "PATH has the app's directories, then the runtime's" path_order
check "the runtime's layer is deployed once" expect_count deployments 2
check "list shows the runtime" sh -c "\"\$0\" list | grep '^$APP ' | grep -q '(runtime $BB FRP-'" "$zigsaw"
check "the same recipe builds the same image" same_image "$work\\app.json" "$app_digest"
check "--sandbox=appcontainer runs it from the runtime" sh -c "\"\$0\" run --sandbox=appcontainer $APP y | grep -q '^args: y'" "$zigsaw"

removed_runtime_app() {
    z rm $BB >/dev/null 2>&1 && z prune >/dev/null 2>&1 && runs && expect_count deployments 2
}
check "removing the runtime's app leaves the app working, and prune keeps the layer" removed_runtime_app
check "prune keeps the runtime's image for builds" sh -c "\"\$0\" prune --dry-run 2>&1 | grep -q 'kept 1 image(s) that builds use'" "$zigsaw"
check "rebuilding uses the kept image" same_image "$work\\app.json" "$app_digest"

app_recipe "$BB" >"$work\\unpinned.json"
z build "$root\\recipes\\busybox.json" >/dev/null 2>&1
check "an unpinned runtime names the digest to pin" sh -c "\"\$0\" build '$work\\unpinned.json' 2>&1 | grep -q '\"bb\": \"$BB@$bb_digest\"'" "$zigsaw"
app_recipe "$BB@$bb_digest" nope.exe >"$work\\missing.json"
check "a command the runtime doesn't have fails the build" sh -c "\"\$0\" build '$work\\missing.json' 2>&1 | grep -q 'not a file in that runtime'" "$zigsaw"
app_recipe "$APP@$app_digest" busybox.exe test.runtime.nested >"$work\\nested.json"
check "a runtime with runtimes of its own is refused" sh -c "\"\$0\" build '$work\\nested.json' 2>&1 | grep -q 'has runtimes of its own'" "$zigsaw"

# --- prettier on node --------------------------------------------------------------

z build "$root\\recipes\\node.json" >/dev/null 2>&1 || { echo "building node failed"; exit 1; }
check "prettier builds on the node runtime its recipe pins" z build "$root\\recipes\\prettier.json"
formats() {
    printf 'const   x={a:1,\n  b:[1,2,3]}\n' >"$work\\ugly.js"
    (cd "$work" && "$bin\\prettier.exe" --write ugly.js >/dev/null) && [ "$(tr -d '\r' <"$work\\ugly.js")" = "const x = { a: 1, b: [1, 2, 3] };" ]
}
check "prettier formats a file in the working directory" formats
npm_prefix() {
    [ "$(z run --command=node io.prettier.prettier -e 'console.log(process.env.NPM_CONFIG_PREFIX)' | tr -d '\r')" = "$ZIGSAW_HOME\\data\\io.prettier.prettier\\npm" ]
}
check "node's variables point into prettier's data directory" npm_prefix

# --- build commands ---------------------------------------------------------------

HELLO=test.build.hello
z build "$root\\recipes\\zig.json" >/dev/null 2>&1 || { echo "building zig failed"; exit 1; }
zig_digest=$(manifest_of org.ziglang.zig)

# The C app: module greet installs a library, module app links it, and
# module notes runs cmd.exe. Built in <dir>, a copy of tests\build\c.
hello_recipe() {
    mkdir -p "$1" && cp "$(cygpath -u "$root")"/tests/build/c/*.[ch] "$(cygpath -u "$1")" &&
        sed -e "s/@ZIG@/$zig_digest/" -e "s/@BUSYBOX@/$bb_digest/" "$root\\tests\\build\\c\\hello.json.in" >"$1\\hello.json"
}
hello_recipe "$work\\c"
# A recipe whose only module runs busybox <commands> (a JSON array's
# contents), with more module settings in <extra>, e.g. "network": true.
sh_recipe() {
    local id=$1 commands=$2 extra=${3:-}
    printf '{ "id": "%s", "version": "1", "command": "x.txt", "exports": {}, "sdk": { "busybox": "%s@%s" },\n  "modules": [{ "name": "m", %s "build": [%s] }] }\n' \
        "$id" $BB "$bb_digest" "$extra" "$commands"
}
own_layer() { grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of "$1" | cut -d: -f2)" | tail -1 | cut -d: -f2; }
config_of() { cat "$ZIGSAW_HOME\\blobs\\sha256\\$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of "$1" | cut -d: -f2)" | head -1 | cut -d: -f2)"; }
drive_free() { ! subst | grep -q '^B:'; }
no_build_root() { ! ls "$ZIGSAW_HOME\\tmp" | grep -q '^zigsaw-build-'; }

start=$SECONDS
check "a recipe with build commands builds with the zig and busybox SDK" z build "$work\\c\\hello.json"
hello_time=$((SECONDS - start))
hello_digest=$(manifest_of $HELLO)
hello_runs() {
    local out
    out=$(z run $HELLO zigsaw | tr -d '\r')
    [ "$out" = "hello, zigsaw
built from B:/src/app/main.c" ] || { echo "got: $out"; return 1; }
}
check "it runs: its app module linked what the greet module installed, on B:" hello_runs
hello_files() {
    local dir="$ZIGSAW_HOME\\deploy\\$(own_layer $HELLO)"
    [ ! -e "$dir\\include" ] && [ ! -e "$dir\\lib" ] && [ "$(tr -d '\r' <"$dir\\notes.txt")" = "built by cmd" ]
}
check "cleanup left out include and lib, and the cmd module ran" hello_files
records_sdk() { config_of $HELLO | tr -d ' \r\n' | grep -q "\"sdk\":{\"zig\":\"$zig_digest\",\"busybox\":\"$bb_digest\"}"; }
check "the config records the SDK" records_sdk
free_afterwards() { drive_free && no_build_root; }
check "the build drive is free afterwards, and the build root gone" free_afterwards

# zig's image puts its cache in ${cache}, which builds keep: building again
# doesn't build zig's C runtime again, and makes the same image.
rebuilt_manifest() { z build --rebuild "$1" 2>&1 | grep -o 'manifest sha256:[0-9a-f]*' | cut -d' ' -f2; }
warm_hello() {
    [ -d "$ZIGSAW_HOME\\cache\\tools\\org.ziglang.zig" ] || { echo "no cache\\tools\\org.ziglang.zig"; return 1; }
    [ "$(rebuilt_manifest "$work\\c\\hello.json")" = "$hello_digest" ]
}
start=$SECONDS
check "a rebuild with zig's kept cache makes the same image" warm_hello
printf '      (%d s; the first build took %d s)\n' $((SECONDS - start)) "$hello_time"
check "zig run as an app has its cache in its data directory" sh -c "\"\$0\" run org.ziglang.zig env | grep '\.global_cache_dir' | grep -qF 'data\\\\org.ziglang.zig\\\\cache\"'" "$zigsaw"

# A tool of our own whose image declares a cache: each build sees what
# earlier ones left there. It also gives builds a command, greet, which
# runs its copy of busybox's echo.
mkdir -p "$work\\cachey" && echo tool >"$work\\cachey\\tool.txt" && cp "$ZIGSAW_HOME\\deploy\\$(own_layer $BB)\\busybox.exe" "$work\\cachey\\"
printf '{ "id": "test.tool.cachey", "version": "1", "command": "tool.txt", "exports": {}, "env": { "CACHEDIR": "${cache}" },\n  "aliases": { "greet": { "command": "busybox.exe", "args": ["echo", "hello from an alias:"] } },\n  "modules": [{ "name": "m", "sources": [{ "path": "tool.txt" }, { "path": "busybox.exe" }] }] }\n' >"$work\\cachey\\tool.json"
z build "$work\\cachey\\tool.json" >/dev/null 2>&1
printf '{ "id": "test.build.cached", "version": "1", "command": "x.txt", "exports": {}, "sdk": { "busybox": "%s@%s", "cachey": "test.tool.cachey@%s" },\n  "modules": [{ "name": "m", "build": ["echo built >> \\"$CACHEDIR/n\\"", "echo \\"$CACHEDIR\\" > \\"$PREFIX/dir.txt\\"", "cp \\"$CACHEDIR/n\\" \\"$PREFIX/x.txt\\"", "greet \\"a  b\\" c > \\"$PREFIX/greet.txt\\""] }] }\n' \
    $BB "$bb_digest" "$(manifest_of test.tool.cachey)" >"$work\\cachey\\cached.json"
kept_cache() {
    z build "$work\\cachey\\cached.json" >/dev/null 2>&1 && z build --rebuild "$work\\cachey\\cached.json" >/dev/null 2>&1 || return 1
    local dir="$ZIGSAW_HOME\\deploy\\$(own_layer test.build.cached)"
    # (BusyBox's sh shows paths in variables with '/'.)
    [ "$(tr -d '\r' <"$dir\\dir.txt" | tr '/' '\\')" = 'B:\cache\test.tool.cachey' ] || { echo "\${cache} was $(cat "$dir\\dir.txt")"; return 1; }
    [ "$(grep -c built "$dir\\x.txt")" -eq 2 ] || { echo "the second build saw: $(cat "$dir\\x.txt")"; return 1; }
    [ -f "$ZIGSAW_HOME\\cache\\tools\\test.tool.cachey\\n" ] && drive_free && no_build_root
}
check "a tool's \${cache} is B:\\cache\\<id>, kept between builds in the store" kept_cache
aliased() {
    local got
    got=$(tr -d '\r' <"$ZIGSAW_HOME\\deploy\\$(own_layer test.build.cached)\\greet.txt")
    [ "$got" = "hello from an alias: a  b c" ] || { echo "greet said: $got"; return 1; }
}
check "a tool's alias runs its command with its arguments, then the caller's" aliased
check "prune keeps tools' caches, and says so" sh -c "\"\$0\" prune --dry-run 2>&1 | grep -q 'kept the caches of 2 build tool(s)'" "$zigsaw"

# Builds are reused when nothing they depend on changed.
reused() {
    local out
    out=$(z -v build "$1" 2>&1)
    grep -q 'built before from the same inputs' <<<"$out" && ! grep -q '^\[' <<<"$out"
}
check "an unchanged recipe isn't built again" reused "$work\\c\\hello.json"
# A quick one, with a local source: busybox copies note.txt.
mkdir -p "$work\\noted" && echo one >"$work\\noted\\note.txt"
printf '{ "id": "test.build.noted", "version": "1", "command": "x.txt", "exports": {}, "sdk": { "busybox": "%s@%s" },\n  "modules": [{ "name": "m", "sources": [{ "path": "note.txt" }], "build": ["cp note.txt \\"$PREFIX/x.txt\\""] }] }\n' \
    $BB "$bb_digest" >"$work\\noted\\noted.json"
z build "$work\\noted\\noted.json" >/dev/null 2>&1
noted_digest=$(manifest_of test.build.noted)
rebuilt() {
    local out
    out=$(z -v build --rebuild "$work\\noted\\noted.json" 2>&1)
    ! grep -q 'built before' <<<"$out" && grep -q '^\[m 1/1\]' <<<"$out" && grep -q "manifest $noted_digest" <<<"$out"
}
check "--rebuild builds it anyway, to the same image" rebuilt
local_source_changed() {
    echo two >"$work\\noted\\note.txt"
    ! z -v build "$work\\noted\\noted.json" 2>&1 | grep -q 'built before' &&
        [ "$(tr -d '\r' <"$ZIGSAW_HOME\\deploy\\$(own_layer test.build.noted)\\x.txt")" = two ]
}
check "a changed local source is built again" local_source_changed

# The same recipe in another store, at another path.
other_store=$(cygpath -w "$(mktemp -d)")\\a-store-at-another-path
seed "$other_store"
zo() { ZIGSAW_HOME="$other_store" "$zigsaw" "$@"; }
other_build() {
    zo build "$root\\recipes\\zig.json" >/dev/null 2>&1 && zo build "$root\\recipes\\busybox.json" >/dev/null 2>&1 &&
        [ "$(zo build "$work\\c\\hello.json" 2>&1 | grep -o 'manifest sha256:[0-9a-f]*' | cut -d' ' -f2)" = "$hello_digest" ]
}
check "the same recipe builds the same image in another store, at another path" other_build
for id in $HELLO org.ziglang.zig $BB; do zo rm --delete-data $id >/dev/null 2>&1; done
zo prune --downloads >/dev/null 2>&1
rm -rf "$(dirname "$other_store")"

sh_recipe test.build.broken '"true", "exit 3", "echo never"' >"$work\\broken.json"
broken() {
    local out
    out=$(z build "$work\\broken.json" 2>&1)
    grep -q 'module m: build command 2 exited with code 3' <<<"$out" && ! grep -q '\[m 3/3\]' <<<"$out" &&
        ! z list | grep -q '^test.build.broken ' && drive_free && no_build_root
}
check "a failing command is reported, and the build stops and leaves nothing behind" broken
kept() {
    local dir
    dir=$(z build --keep-build-dir "$work\\broken.json" 2>&1 | grep -o 'kept the build directory: .*' | cut -d' ' -f5-)
    [ -n "$dir" ] && [ -d "$dir\\src\\m" ] && [ -d "$dir\\prefix" ] && drive_free &&
        z prune >/dev/null 2>&1 && [ ! -e "$dir" ]
}
check "--keep-build-dir keeps the build root, until prune" kept

# A local web server, which build steps can reach only with network access.
mkdir -p "$work\\www" && echo served >"$work\\www\\hello.txt"
"$ZIGSAW_HOME\\deploy\\$(own_layer $BB)\\busybox.exe" httpd -f -p 127.0.0.1:18099 -h "$work\\www" &
httpd=$!
sh_recipe test.build.offline '"wget -O \"$PREFIX/x.txt\" http://127.0.0.1:18099/hello.txt"' >"$work\\offline.json"
sh_recipe test.build.online '"wget -O \"$PREFIX/x.txt\" http://127.0.0.1:18099/hello.txt"' '"network": true,' >"$work\\online.json"
check "build steps can't reach the network by default" sh -c "! \"\$0\" build '$work\\offline.json' >/dev/null 2>&1" "$zigsaw"
online() {
    z build "$work\\online.json" 2>&1 | grep -q 'warning: a build step used the network' &&
        [ "$(tr -d '\r' <"$ZIGSAW_HOME\\deploy\\$(own_layer test.build.online)\\x.txt")" = served ] &&
        config_of test.build.online | grep -q '"network": true'
}
check "a module with \"network\": true can, and the image records it" online

# A vendor step fetches with network access; its result is pinned by hash,
# so the build itself stays offline and the image hermetic. Its commands
# also leave junk.txt, which the build mustn't see. <vendor extra> goes into
# "vendor", e.g. a "sha256".
vendor_recipe() {
    printf '{ "id": "test.build.vendored", "version": "1", "command": "x.txt", "exports": {}, "sdk": { "busybox": "%s@%s" },\n  "modules": [{ "name": "m",\n    "vendor": { "commands": ["mkdir -p deps && wget -O deps/hello.txt http://127.0.0.1:18099/hello.txt", "echo junk > junk.txt"], "dir": "deps"%s },\n    "build": ["[ ! -e junk.txt ]", "cp deps/hello.txt \\"$PREFIX/x.txt\\"", "! wget -q -O x http://127.0.0.1:18099/hello.txt"] }] }\n' \
        $BB "$bb_digest" "${1:-}"
}
vendor_recipe >"$work\\unpinned-vendor.json"
vendor_hash=$(z build "$work\\unpinned-vendor.json" 2>&1 | grep -A1 'Pin what its commands made' | grep -o '"sha256": "[0-9a-f]*"' | cut -d'"' -f4)
check "an unpinned vendor step fails, naming the hash to pin" test -n "$vendor_hash"
vendor_recipe ", \"sha256\": \"$vendor_hash\"" >"$work\\vendored.json"
vendored() {
    local out
    # The unpinned build kept what it fetched; this one is to fetch again.
    rm "$ZIGSAW_HOME\\cache\\downloads\\$vendor_hash" || return 1
    out=$(z build "$work\\vendored.json" 2>&1) || { echo "$out" | tail -3; return 1; }
    grep -q '^\[m vendor 1/2\]' <<<"$out" && ! grep -q 'used the network' <<<"$out" &&
        [ "$(tr -d '\r' <"$ZIGSAW_HOME\\deploy\\$(own_layer test.build.vendored)\\x.txt")" = served ] &&
        config_of test.build.vendored | tr -d ' \r\n' | grep -q "\"vendor\":{\"m\":\"$vendor_hash\"},\"network\":false"
}
check "pinned, it builds offline from what the step fetched, and the config records it" vendored
vendor_recipe ", \"sha256\": \"$(printf '0%.0s' $(seq 64))\"" >"$work\\misvendored.json"
check "a vendor step that makes something else fails, naming both hashes" sh -c "\"\$0\" build '$work\\misvendored.json' 2>&1 | grep -A2 'sha256 mismatch for what module m.s vendor commands made in deps' | grep -q 'got      $vendor_hash'" "$zigsaw"
kill $httpd 2>/dev/null
vendored_from_cache() {
    local out
    out=$(z -v build --rebuild "$work\\vendored.json" 2>&1) || { echo "$out" | tail -3; return 1; }
    grep -q 'vendored files from the cache' <<<"$out" && ! grep -q '^\[m vendor' <<<"$out" &&
        [ "$(tr -d '\r' <"$ZIGSAW_HOME\\deploy\\$(own_layer test.build.vendored)\\x.txt")" = served ]
}
check "with the server gone, a rebuild takes the vendored files from the cache" vendored_from_cache

printf '{ "id": "test.build.nosh", "version": "1", "command": "x", "exports": {}, "sdk": { "zig": "org.ziglang.zig@%s" }, "modules": [{ "name": "m", "build": ["true"] }] }\n' "$zig_digest" >"$work\\nosh.json"
check "sh modules without busybox in the SDK fail, saying so" sh -c "\"\$0\" build '$work\\nosh.json' 2>&1 | grep -q 'add busybox to'" "$zigsaw"

# B:, in use by something else, and left behind by a build that crashed.
mkdir -p "$work\\other" "$work\\tmp\\zigsaw-build-stale"
subst B: "$work\\other"
check "a B: zigsaw didn't map fails the build" sh -c "\"\$0\" build '$work\\broken.json' 2>&1 | grep -q 'B: is in use'" "$zigsaw"
subst B: /D
subst B: "$work\\tmp\\zigsaw-build-stale"
sh_recipe test.build.ok '"echo ok > \"$PREFIX/x.txt\""' >"$work\\ok.json"
check "a stale B: from an earlier build is replaced" sh -c "\"\$0\" build '$work\\ok.json' >/dev/null 2>&1 && ! subst | grep -q '^B:'" "$zigsaw"
subst B: /D >/dev/null 2>&1

# Two builds at once take turns with B:.
sh_recipe test.build.slow '"sleep 4", "echo slow > \"$PREFIX/x.txt\""' >"$work\\slow.json"
z build "$work\\slow.json" >"$work\\slow.log" 2>&1 &
slow=$!
for _ in $(seq 150); do grep -q 'm 1/2' "$work\\slow.log" 2>/dev/null && break; sleep 0.2; done
check "a second build waits for the first to finish with B:" sh -c "\"\$0\" build --rebuild '$work\\ok.json' 2>&1 | grep -q 'waiting for another zigsaw build'" "$zigsaw"
wait $slow
check "and the first finishes normally" grep -q 'installed test.build.slow' "$work\\slow.log"

# Output piped into a command that stops reading, as `| head` does, mustn't
# end a build half way, leaving B: mapped.
closed_pipe() {
    z build --rebuild "$work\\ok.json" 2>&1 | head -c 0
    local status=${PIPESTATUS[0]}
    [ "$status" -eq 0 ] || { echo "zigsaw exited with $status"; return 1; }
    drive_free && no_build_root
}
check "a build whose output nobody reads any more still finishes, and cleans up" closed_pipe

# A link in the prefix can't go into a layer.
printf '{ "id": "test.build.link", "version": "1", "command": "x", "exports": {}, "modules": [{ "name": "m", "shell": "cmd", "build": ["mkdir %%PREFIX%%\\\\d && mklink /J %%PREFIX%%\\\\link %%PREFIX%%\\\\d"] }] }\n' >"$work\\link.json"
refused_link() {
    local out
    out=$(z build "$work\\link.json" 2>&1)
    grep -q 'can only be files and directories' <<<"$out" || { echo "$out"; return 1; }
    drive_free || { echo "B: is still mapped: $(subst)"; return 1; }
    no_build_root || { echo "left in tmp: $(ls "$ZIGSAW_HOME\\tmp" | tr '\n' ' ')"; return 1; }
}
check "a link left in the prefix fails the build" refused_link

# --- MSVC, if Visual Studio is installed ----------------------------------------------

vswhere="$(cygpath -u "$(printenv 'ProgramFiles(x86)')")/Microsoft Visual Studio/Installer/vswhere.exe"
if [ -f "$vswhere" ]; then
    MSVC=test.build.msvc
    check "a recipe with \"host\": [\"msvc\"] builds with Visual Studio" sh -c "\"\$0\" build '$root\\tests\\build\\msvc\\hello.json' 2>&1 | grep -q 'warning: built with the host.s msvc'" "$zigsaw"
    check "it runs" sh -c "\"\$0\" run $MSVC | grep -q '^hello from MSVC'" "$zigsaw"
    records_host() { config_of $MSVC | tr -d ' \r\n' | grep -q '"host":{"msvc":"[0-9.]*","windows-sdk":"[0-9.]*"}'; }
    check "the config records the MSVC and Windows SDK versions" records_host
    check "MSVC builds aren't reused" sh -c "! \"\$0\" -v build '$root\\tests\\build\\msvc\\hello.json' 2>&1 | grep -q 'built before'" "$zigsaw"
    check "and leave nothing behind" free_afterwards
else
    echo "skip  MSVC: no Visual Studio installer ($vswhere)"
fi

# --- SQLite from source ------------------------------------------------------------

check "sqlite.json builds SQLite and zlib from source" z build "$root\\recipes\\sqlite.json"
check "sqlite3 runs, with zlib" sh -c "[ \"\$(\"\$0\" run org.sqlite.sqlite3 :memory: 'select sqlite_version(), length(sqlar_uncompress(sqlar_compress(zeroblob(1000)), 1000))' | tr -d '\r')\" = '3.53.4|1000' ]" "$zigsaw"

# --- Rust from source ---------------------------------------------------------------

check "rust.json builds the Rust SDK image" z build "$root\\recipes\\rust.json"
# A program whose windows-sys crate needs dlltool, which zig's image
# provides; its crates come from crates.io through a vendor step.
RUST=test.build.rust
mkdir -p "$work\\rust" && cp "$(cygpath -u "$root")"/tests/build/rust/{Cargo.toml,Cargo.lock,main.rs} "$(cygpath -u "$work")/rust/" &&
    sed -e "s/@RUST@/$(manifest_of org.rust-lang.rust)/" -e "s/@ZIG@/$zig_digest/" -e "s/@BUSYBOX@/$bb_digest/" \
        "$root\\tests\\build\\rust\\hello.json.in" >"$work\\rust\\hello.json"
check "a Rust program builds, its crates vendored, with zig's dlltool" z build "$work\\rust\\hello.json"
rust_app_digest=$(manifest_of $RUST)
rust_runs() {
    local out
    out=$(z run $RUST zigsaw | tr -d '\r')
    [ "$out" = "hello, zigsaw, from Rust
Windows is up: true" ] || { echo "got: $out"; return 1; }
}
check "it runs, calling Windows through windows-sys" rust_runs
# Each build root has a new random name, so a real path or a time in the
# executable would show.
rust_again() { [ "$(rebuilt_manifest "$work\\rust\\hello.json")" = "$rust_app_digest" ]; }
check "built again, from the vendored crates in the cache, it's the same image" rust_again

# Removing the apps also deletes their AppContainer profiles. The images
# builds use stay until prune --downloads, and only zigsaw can delete their
# protected deployments.
for id in $APP io.prettier.prettier org.nodejs.node $BB $HELLO org.ziglang.zig org.sqlite.sqlite3 \
    test.build.online test.build.ok test.build.slow test.build.msvc test.build.noted test.tool.cachey test.build.cached \
    test.build.vendored org.rust-lang.rust $RUST; do z rm --delete-data $id >/dev/null 2>&1; done
z prune --downloads --data >/dev/null 2>&1
check "prune --downloads deletes tools' caches" sh -c "[ -z \"\$(ls '$ZIGSAW_HOME\\cache\\tools')\" ]"
rm -rf "$ZIGSAW_HOME" "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
