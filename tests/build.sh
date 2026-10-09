#!/usr/bin/env bash
# End-to-end checks for building apps: runtimes, which an app runs with and
# whose layers travel in its image, and build commands, which build an app
# from source with SDK images (zig, busybox, CMake, Meson, Rust, and Go with and
# without C), tools' caches and aliases, and vendor steps.
#
#   tests/build.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and network access (busybox, Node, Prettier, zig, CMake,
# zlib, SQLite, Rust and Go downloads, and crates from crates.io). Always uses
# temporary stores, since it removes apps, and deletes them afterwards. To
# skip downloading what a store already has (zig's is 97 MB, Rust's 150 MB),
# set SEED_DOWNLOADS to its cache\downloads directory; its files are linked,
# or copied, into the temporary stores.
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
# tests/imports.zig: whether the loader binds every import of a program.
(cd "$root" && zig build imports) || { echo "building the import checker failed"; exit 1; }
imports="$root\\zig-out\\test\\zigsaw-imports.exe"

# seed <store>: puts SEED_DOWNLOADS's files into the store's download cache,
# as hard links if it's on the same drive.
seed() {
    [ -n "${SEED_DOWNLOADS:-}" ] || return 0
    local from to
    from=$(cygpath -u "$SEED_DOWNLOADS") to="$(cygpath -u "$1")/cache/downloads"
    mkdir -p "$to" && { cp -l "$from"/* "$to/" 2>/dev/null || cp -n "$from"/* "$to/"; }
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
own_layer() { grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of "$1" | cut -d: -f2)" | tail -1 | cut -d: -f2; }
config_of() { cat "$ZIGSAW_HOME\\blobs\\sha256\\$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of "$1" | cut -d: -f2)" | head -1 | cut -d: -f2)"; }
drive_free() { ! subst | grep -q '^B:'; }
no_build_root() { ! ls "$ZIGSAW_HOME\\tmp" | grep -q '^zigsaw-build-'; }

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

# --- images as sources -------------------------------------------------------------

# A runtime made from its SDK without building again: a module takes the SDK
# image's own files, and cleanup leaves out what only builds need. The SDK
# here is busybox with a header, a library and a pkg-config file.
SDK=test.image.sdk
RT=test.image.runtime
mkdir -p "$work\\sdk\\include" "$work\\sdk\\lib\\pkgconfig" && cp "$ZIGSAW_HOME\\deploy\\$(own_layer $BB)\\busybox.exe" "$work\\sdk\\" &&
    echo '#define X 1' >"$work\\sdk\\include\\x.h" && echo lib >"$work\\sdk\\lib\\libx.a" && echo 'Name: x' >"$work\\sdk\\lib\\pkgconfig\\x.pc"
printf '{ "id": "%s", "version": "1", "command": "bin/busybox.exe", "exports": {},\n  "modules": [{ "name": "m", "sources": [{ "path": "busybox.exe", "dest": "bin/busybox.exe" }, { "path": "include/x.h", "dest": "include/x.h" }, { "path": "lib/libx.a", "dest": "lib/libx.a" }, { "path": "lib/pkgconfig/x.pc", "dest": "lib/pkgconfig/x.pc" }] }] }\n' \
    $SDK >"$work\\sdk\\sdk.json"
check "an SDK image builds" z build "$work\\sdk\\sdk.json"
sdk_digest=$(manifest_of $SDK)
image_recipe() {
    printf '{ "id": "%s", "version": "1", "command": "bin/busybox.exe", "exports": {}, "cleanup": ["/include", "/lib"],\n  "modules": [{ "name": "files", "sources": [{ "image": "%s" }] }] }\n' $RT "$1"
}
image_recipe "$SDK@$sdk_digest" >"$work\\sdk\\runtime.json"
check "a runtime takes the SDK image's files" z build "$work\\sdk\\runtime.json"
rt_digest=$(manifest_of $RT)
rt_files() {
    local dir="$ZIGSAW_HOME\\deploy\\$(own_layer $RT)"
    [ -f "$dir\\bin\\busybox.exe" ] && [ ! -e "$dir\\include" ] && [ ! -e "$dir\\lib" ] || { echo "files: $(cd "$dir" && find .)"; return 1; }
    [ "$(z run $RT echo from the sdk | tr -d '\r')" = "from the sdk" ]
}
check "it has the SDK's program without its headers and libraries, and runs it" rt_files
records_image() { config_of $RT | tr -d ' \r\n' | grep -q "\"images\":\[\"$sdk_digest\"\]"; }
check "its config records the SDK image's digest" records_image
check "the same recipe builds the same image" same_image "$work\\sdk\\runtime.json" "$rt_digest"
image_recipe "$SDK" >"$work\\sdk\\unpinned.json"
check "an unpinned image source names the digest to pin" sh -c "\"\$0\" build '$work\\sdk\\unpinned.json' 2>&1 | grep -qF '\"image\": \"$SDK@$sdk_digest\"'" "$zigsaw"
# A module with build commands gets the image's files in its directory, under
# dest. As an SDK, an image with pkg-config files is where pkg-config and
# CMake look, after the prefix.
printf '{ "id": "test.image.built", "version": "1", "command": "x.h", "exports": {}, "sdk": { "busybox": "%s@%s", "x": "%s@%s" },\n  "modules": [{ "name": "m", "sources": [{ "image": "%s@%s", "dest": "sdk" }], "build": ["cp sdk/include/x.h \\"$PREFIX/\\"", "echo \\"$PKG_CONFIG_PATH\\" > \\"$PREFIX/pc.txt\\"", "echo \\"$CMAKE_PREFIX_PATH\\" > \\"$PREFIX/cmake.txt\\"", "echo \\"$PATH\\" > \\"$PREFIX/path.txt\\""] }] }\n' \
    $BB "$bb_digest" $SDK "$sdk_digest" $SDK "$sdk_digest" >"$work\\sdk\\built.json"
search_paths() {
    z build "$work\\sdk\\built.json" >/dev/null 2>&1 || { z build "$work\\sdk\\built.json" 2>&1 | tail -1; return 1; }
    local dir="$ZIGSAW_HOME\\deploy\\$(own_layer test.image.built)" sdk_dir="$ZIGSAW_HOME\\deploy\\$(own_layer $SDK)"
    [ -f "$dir\\x.h" ] || { echo "no x.h"; return 1; }
    [ "$(tr -d '\r' <"$dir\\pc.txt" | tr '/' '\\')" = "B:\\prefix\\lib\\pkgconfig;B:\\prefix\\share\\pkgconfig;$sdk_dir\\lib\\pkgconfig" ] || { echo "PKG_CONFIG_PATH: $(cat "$dir\\pc.txt")"; return 1; }
    [ "$(tr -d '\r' <"$dir\\cmake.txt" | tr '/' '\\')" = "B:\\prefix;$sdk_dir" ] || { echo "CMAKE_PREFIX_PATH: $(cat "$dir\\cmake.txt")"; return 1; }
    case "$(tr -d '\r' <"$dir\\path.txt" | tr '/' '\\')" in
    "B:\\prefix\\bin;"*) ;;
    *) echo "PATH: $(cat "$dir\\path.txt")"; return 1 ;;
    esac
}
check "a building module gets them under dest; PATH starts with B:\\prefix\\bin, PKG_CONFIG_PATH and CMAKE_PREFIX_PATH name the prefix, then the SDK" search_paths

# --- aliases in runs, and SDKs with runtimes ------------------------------------------

# A tool image with aliases, all BusyBox: greet echoes "tool:", ar echoes
# (over BusyBox's own ar applet), fail exits 7, shout drops --quiet. An app
# that has it as a runtime and an alias greet of its own, and runs BusyBox's
# sh from the runtime. And an SDK that has the tool as its runtime.
TOOL=test.alias.tool
AAPP=test.alias.app
ASDK=test.alias.sdk
mkdir -p "$work\\alias" && cp "$ZIGSAW_HOME\\deploy\\$(own_layer $BB)\\busybox.exe" "$work\\alias\\" &&
    echo '#define Y 1' >"$work\\alias\\y.h"
tool_recipe() {
    local version=${1:-1}
    cat <<EOF
{ "id": "$TOOL", "version": "$version", "command": "busybox.exe", "exports": {},
  "env": { "ALIAS_TOOL": "\${app}" },
  "aliases": {
    "greet": { "command": "busybox.exe", "args": ["echo", "tool:"] },
    "ar": { "command": "busybox.exe", "args": ["echo", "tool ar"] },
    "fail": { "command": "busybox.exe", "args": ["sh", "-c", "exit 7"] },
    "shout": { "command": "busybox.exe", "args": ["echo", "shout"], "drop": ["--quiet"] }
  },
  "modules": [{ "name": "m", "sources": [{ "path": "busybox.exe" }, { "path": "y.h", "dest": "v$version.txt" }] }] }
EOF
}
tool_recipe >"$work\\alias\\tool.json"
check "a tool image with aliases builds" z build "$work\\alias\\tool.json"
tool_digest=$(manifest_of $TOOL)
alias_app_recipe() {
    local aliases='"aliases": { "greet": { "command": "busybox.exe", "args": ["echo", "app:"] } },'
    [ "${2:-}" = none ] && aliases=''
    cat <<EOF
{ "id": "$AAPP", "version": "1", "command": "\${tool}/busybox.exe", "args": ["sh"], "exports": {},
  $aliases
  "runtimes": { "tool": "$1" },
  "modules": [{ "name": "m", "sources": [{ "path": "busybox.exe" }] }] }
EOF
}
alias_app_recipe "$TOOL@$tool_digest" >"$work\\alias\\app.json"
check "an app with it as a runtime builds" z build "$work\\alias\\app.json"
alias_app_digest=$(manifest_of $AAPP)
check "the app's alias wins over its runtime's" sh -c '[ "$("$0" run '$AAPP' -c "greet hi" | tr -d "\r")" = "app: hi" ]' "$zigsaw"
check "a runtime's alias runs, dropping what it drops" sh -c '[ "$("$0" run '$AAPP' -c "shout --quiet x" | tr -d "\r")" = "shout x" ]' "$zigsaw"
check "an alias wins over BusyBox's applet of the same name" sh -c '[ "$("$0" run '$AAPP' -c ar | tr -d "\r")" = "tool ar" ]' "$zigsaw"
check "an alias's exit code comes through" sh -c '[ "$("$0" run '$AAPP' -c "fail; echo \$?" | tr -d "\r")" = 7 ]' "$zigsaw"
check "--command finds an alias" sh -c '[ "$("$0" run --command=greet '$AAPP' there | tr -d "\r")" = "app: there" ]' "$zigsaw"
check "the runtime's variables come with it" sh -c '[ "$("$0" run '$AAPP' -c "echo \$ALIAS_TOOL" | tr -d "\r" | tr / \\\\)" = "$1\\deploy\\$2" ]' "$zigsaw" "$ZIGSAW_HOME" "$(own_layer $TOOL)"
records_aliases() { config_of $AAPP | tr -d ' \r\n' | grep -q '"runtimes":{"tool":{.*"aliases":{"greet":{"command":"busybox.exe","args":\["echo","tool:"\]}'; }
check "the app's config records the runtime's aliases" records_aliases
unchanged_shims() {
    local dir="$ZIGSAW_HOME\\aliases\\$AAPP" before after
    before=$(cd "$dir" && ls -l --time-style=full-iso)
    z run $AAPP -c true && after=$(cd "$dir" && ls -l --time-style=full-iso)
    [ "$before" = "$after" ] && [ "$(ls "$dir" | wc -l)" -eq 8 ] || { echo "$after"; return 1; }
}
check "a second run rewrites none of the 8 shim files (4 aliases)" unchanged_shims
check "aliases work under --sandbox=low, the last of sh -c's commands too" sh -c '[ "$("$0" run --sandbox=low '$AAPP' -c "greet x; shout --quiet y" | tr -d "\r" | tr "\n" " ")" = "app: x shout y " ]' "$zigsaw"
# In an AppContainer, BusyBox's sh doesn't see zigsaw, takes itself for an
# orphan, and doesn't wait for its last command (README's known gaps).
check "aliases work under --sandbox=appcontainer" sh -c '[ "$("$0" run --sandbox=appcontainer '$AAPP' -c "greet x; shout --quiet y; true" | tr -d "\r" | tr "\n" " ")" = "app: x shout y " ]' "$zigsaw"
check "and in --ephemeral runs" sh -c '[ "$("$0" run --ephemeral '$AAPP' -c "greet e" | tr -d "\r")" = "app: e" ]' "$zigsaw"
check "the same recipe builds the same image" same_image "$work\\alias\\app.json" "$alias_app_digest"
no_aliases_left() {
    alias_app_recipe "$BB@$bb_digest" none | sed 's/\${tool}/${bb}/; s/"tool"/"bb"/' >"$work\\alias\\plain.json"
    z build "$work\\alias\\plain.json" >/dev/null 2>&1 && z run $AAPP -c true && [ ! -e "$ZIGSAW_HOME\\aliases\\$AAPP" ]
}
check "a version without aliases leaves no alias shims after its run" no_aliases_left
rm_aliases() {
    z build "$work\\alias\\app.json" >/dev/null 2>&1 && z run $AAPP -c true && [ -e "$ZIGSAW_HOME\\aliases\\$AAPP\\greet.exe" ] &&
        z rm $AAPP >/dev/null 2>&1 && [ ! -e "$ZIGSAW_HOME\\aliases\\$AAPP" ]
}
check "rm removes the app's alias shims" rm_aliases
prune_aliases() {
    mkdir -p "$ZIGSAW_HOME\\aliases\\test.gone" && echo x >"$ZIGSAW_HOME\\aliases\\test.gone\\x.shim" &&
        z prune >/dev/null 2>&1 && [ ! -e "$ZIGSAW_HOME\\aliases\\test.gone" ]
}
check "prune removes alias shims of apps that aren't installed" prune_aliases

# The SDK: the tool is its runtime. A recipe that builds with it gets the
# tool too, its aliases and variables, without naming it.
cat >"$work\\alias\\sdk.json" <<EOF
{ "id": "$ASDK", "version": "1", "command": "\${tool}/busybox.exe", "exports": {},
  "runtimes": { "tool": "$TOOL@$tool_digest" },
  "modules": [{ "name": "m", "sources": [{ "path": "y.h", "dest": "include/y.h" }] }] }
EOF
check "an SDK with the tool as its runtime builds" z build "$work\\alias\\sdk.json"
asdk_digest=$(manifest_of $ASDK)
with_sdk_recipe() {
    local extra=${1:-}
    printf '{ "id": "test.alias.built", "version": "1", "command": "b.txt", "exports": {}, "sdk": { "s": "%s@%s"%s },\n  "modules": [{ "name": "m", "build": ["greet built > \\"$PREFIX/b.txt\\"", "echo \\"$ALIAS_TOOL\\" > \\"$PREFIX/t.txt\\"", "echo \\"$PATH\\" > \\"$PREFIX/p.txt\\""] }] }\n' \
        $ASDK "$asdk_digest" "$extra"
}
sdk_brings_tool() {
    with_sdk_recipe >"$work\\alias\\built.json"
    z build "$work\\alias\\built.json" >/dev/null 2>&1 || { z build "$work\\alias\\built.json" 2>&1 | tail -1; return 1; }
    local dir="$ZIGSAW_HOME\\deploy\\$(own_layer test.alias.built)"
    [ "$(tr -d '\r' <"$dir\\b.txt")" = "tool: built" ] || { echo "b.txt: $(cat "$dir\\b.txt")"; return 1; }
    [ "$(tr -d '\r' <"$dir\\t.txt" | tr '/' '\\')" = "$ZIGSAW_HOME\\deploy\\$(own_layer $TOOL)" ] || { echo "t.txt: $(cat "$dir\\t.txt")"; return 1; }
}
check "a build with the SDK gets its runtime's aliases and variables" sdk_brings_tool
tool_once() {
    with_sdk_recipe ", \"t\": \"$TOOL@$tool_digest\"" >"$work\\alias\\both.json"
    z build "$work\\alias\\both.json" >/dev/null 2>&1 || { z build "$work\\alias\\both.json" 2>&1 | tail -1; return 1; }
    local n
    n=$(tr -d '\r' <"$ZIGSAW_HOME\\deploy\\$(own_layer test.alias.built)\\p.txt" | tr '/;' '\\\n' | grep -cF "$(own_layer $TOOL)")
    [ "$n" -eq 1 ] || { echo "the tool is $n times on PATH"; return 1; }
}
check "naming the SDK's runtime too uses it once" tool_once
two_versions() {
    tool_recipe 2 >"$work\\alias\\tool2.json" && z build "$work\\alias\\tool2.json" >/dev/null 2>&1 || return 1
    with_sdk_recipe ", \"t\": \"$TOOL@$(manifest_of $TOOL)\"" >"$work\\alias\\two.json"
    z build "$work\\alias\\two.json" 2>&1 | grep -q "a build can't use two versions of $TOOL"
}
check "another version of the SDK's runtime is refused" two_versions
image_recipe "$ASDK@$asdk_digest" | sed "s/$RT/test.alias.files/; s/\"cleanup\": \[\"\/include\", \"\/lib\"\],//; s|bin/busybox.exe|include/y.h|" >"$work\\alias\\files.json"
sdk_files_only() {
    z build "$work\\alias\\files.json" >/dev/null 2>&1 || { z build "$work\\alias\\files.json" 2>&1 | tail -1; return 1; }
    local dir="$ZIGSAW_HOME\\deploy\\$(own_layer test.alias.files)"
    [ -f "$dir\\include\\y.h" ] && [ ! -e "$dir\\busybox.exe" ] || { echo "files: $(cd "$dir" && find .)"; return 1; }
}
check "an image source takes the SDK's own files, not its runtime's" sdk_files_only

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

# The C app, built with zig's aliases: module greet installs a library of C
# and C++, module app links it with a resource, and module notes runs
# cmd.exe. Its ar is zig's, not BusyBox's applet of the same name. Built in
# <dir>, a copy of tests\build\c.
hello_recipe() {
    mkdir -p "$1" && cp "$(cygpath -u "$root")"/tests/build/c/*.{c,h,cpp,rc} "$(cygpath -u "$1")" &&
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

start=$SECONDS
check "a recipe with build commands builds with zig's aliases (cc, c++, ar, ranlib, rc) and busybox" z build "$work\\c\\hello.json"
hello_time=$((SECONDS - start))
hello_digest=$(manifest_of $HELLO)
hello_runs() {
    local out
    out=$(z run $HELLO zigsaw | tr -d '\r')
    [ "$out" = "hello, zigsaw
built from B:/src/app/main.c
twice 21 is 42
a string from its resources" ] || { echo "got: $out"; return 1; }
}
check "it runs: its app module linked what the greet module installed (C and C++), and its resources, on B:" hello_runs
hello_files() {
    local dir="$ZIGSAW_HOME\\deploy\\$(own_layer $HELLO)"
    [ ! -e "$dir\\include" ] && [ ! -e "$dir\\lib" ] && [ "$(tr -d '\r' <"$dir\\notes.txt")" = "built by cmd" ]
}
check "cleanup left out include and lib, and the cmd module ran" hello_files
# The app's own layer is a gzip-compressed tar that other tools read too.
gzip_layer() {
    local manifest="$ZIGSAW_HOME\\blobs\\sha256\\$(manifest_of $HELLO | cut -d: -f2)"
    tr -d ' \r\n' <"$manifest" | grep -q "\"mediaType\":\"application/vnd.oci.image.layer.v1.tar+gzip\",\"digest\":\"sha256:$(own_layer $HELLO)\"" &&
        tar -tzf "$(cygpath -u "$ZIGSAW_HOME\\blobs\\sha256\\$(own_layer $HELLO)")" | grep -q '^notes.txt$'
}
check "its layer is a gzip-compressed tar, which tar lists" gzip_layer
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

# The C app's sources again, built with CMake and Ninja from CMake's image:
# zig's image tells CMake its compilers (CC, CXX, RC) and how to link
# reproducibly (LDFLAGS). Its program links as C++, with zig's libc++.
CMAKEAPP=test.build.cmake
check "cmake.json builds CMake's image, with Ninja" z build "$root\\recipes\\cmake.json"
mkdir -p "$work\\cmake" && cp "$(cygpath -u "$root")"/tests/build/c/*.{c,h,cpp,rc} "$(cygpath -u "$root")"/tests/build/cmake/CMakeLists.txt "$(cygpath -u "$work")/cmake/" &&
    sed -e "s/@CMAKE@/$(manifest_of org.cmake.cmake)/" -e "s/@ZIG@/$zig_digest/" -e "s/@BUSYBOX@/$bb_digest/" \
        "$root\\tests\\build\\cmake\\hello.json.in" >"$work\\cmake\\hello.json"
start=$SECONDS
check "a CMake project of C, C++ and resources builds with CMake's and zig's images" z build "$work\\cmake\\hello.json"
cmake_time=$((SECONDS - start))
cmake_app_digest=$(manifest_of $CMAKEAPP)
cmake_runs() {
    local out
    out=$(z run $CMAKEAPP zigsaw | tr -d '\r')
    [ "$out" = "hello, zigsaw
built from B:/src/hello/main.c
twice 21 is 42
a string from its resources" ] || { echo "got: $out"; return 1; }
    [ ! -e "$ZIGSAW_HOME\\deploy\\$(own_layer $CMAKEAPP)\\lib" ] || { echo "cleanup left lib"; return 1; }
}
check "it runs, as cmake --install installed it" cmake_runs
start=$SECONDS
cmake_again() { [ "$(rebuilt_manifest "$work\\cmake\\hello.json")" = "$cmake_app_digest" ]; }
check "built again, it's the same image" cmake_again
printf '      (%d s; the first build took %d s)\n' $((SECONDS - start)) "$cmake_time"

# The same sources with Meson, from meson's image (Python, Meson, Ninja,
# pkgconf), and zig's compilers: one module installs a DLL of C and C++ with a
# pkg-config file, and the next finds it with pkg-config, in B:\prefix, and
# links it into a program with resources (zig's rc, which Meson takes for
# Microsoft's).
MESONAPP=test.build.meson
check "meson.json builds Meson's image, with Ninja and pkgconf" z build "$root\\recipes\\meson.json"
mkdir -p "$work\\meson\\greet" "$work\\meson\\hello" &&
    cp "$(cygpath -u "$root")"/tests/build/c/*.{c,h,cpp,rc} "$(cygpath -u "$work")/meson/" &&
    cp "$(cygpath -u "$root")/tests/build/meson/greet/meson.build" "$(cygpath -u "$work")/meson/greet/" &&
    cp "$(cygpath -u "$root")/tests/build/meson/hello/meson.build" "$(cygpath -u "$work")/meson/hello/" &&
    sed -e "s/@MESON@/$(manifest_of com.mesonbuild.meson)/" -e "s/@ZIG@/$zig_digest/" -e "s/@BUSYBOX@/$bb_digest/" \
        "$root\\tests\\build\\meson\\hello.json.in" >"$work\\meson\\hello.json"
start=$SECONDS
check "a Meson project linking an earlier module's DLL through pkg-config builds" z build "$work\\meson\\hello.json"
meson_time=$((SECONDS - start))
meson_app_digest=$(manifest_of $MESONAPP)
meson_runs() {
    local out dir="$ZIGSAW_HOME\\deploy\\$(own_layer $MESONAPP)"
    out=$(z run $MESONAPP zigsaw | tr -d '\r')
    [ "$out" = "hello, zigsaw
built from ../main.c
twice 21 is 42
a string from its resources" ] || { echo "got: $out"; return 1; }
    [ -f "$dir\\bin\\libgreet.dll" ] && [ ! -e "$dir\\lib" ] || { echo "want bin\\libgreet.dll and no lib"; return 1; }
}
check "it runs, with the DLL next to it" meson_runs
start=$SECONDS
meson_again() { [ "$(rebuilt_manifest "$work\\meson\\hello.json")" = "$meson_app_digest" ]; }
check "built again, it's the same image" meson_again
printf '      (%d s; the first build took %d s)\n' $((SECONDS - start)) "$meson_time"

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
# Rust's image keeps cargo's home in its data directory, whose bin is on its
# PATH, so what `cargo install` installs gets a shim.
mkdir -p "$work\\tiny\\src" &&
    printf '[package]\nname = "zigsaw-tiny"\nversion = "1.0.0"\nedition = "2021"\n' >"$work\\tiny\\Cargo.toml" &&
    printf 'fn main() { println!("tiny {}", std::env::args().nth(1).unwrap_or_default()); }\n' >"$work\\tiny\\src\\main.rs"
cargo_installed() {
    local out
    out=$(cd "$work\\tiny" && z run --command=cargo org.rust-lang.rust install --offline --quiet --path . 2>&1)
    grep -q 'added zigsaw-tiny to' <<<"$out" || { echo "$out" | tail -3; return 1; }
    [ "$("$bin\\zigsaw-tiny.exe" hi | tr -d '\r')" = "tiny hi" ]
}
check "cargo install gives what it installs a shim" cargo_installed
# A program whose windows-sys crate needs dlltool, which Rust's image
# provides, and whose build.rs compiles C with the cc crate, which finds
# zig's cc through the variables zig's image sets; its crates come from
# crates.io through a vendor step.
RUST=test.build.rust
mkdir -p "$work\\rust" && cp "$(cygpath -u "$root")"/tests/build/rust/{Cargo.toml,Cargo.lock,build.rs,greet.c,main.rs} "$(cygpath -u "$work")/rust/" &&
    sed -e "s/@RUST@/$(manifest_of org.rust-lang.rust)/" -e "s/@ZIG@/$zig_digest/" -e "s/@BUSYBOX@/$bb_digest/" \
        "$root\\tests\\build\\rust\\hello.json.in" >"$work\\rust\\hello.json"
check "a Rust program builds, its crates vendored, with GNU dlltool and zig's as, and C through zig's cc" z build "$work\\rust\\hello.json"
rust_app_digest=$(manifest_of $RUST)
rust_runs() {
    local out
    out=$(z run $RUST zigsaw | tr -d '\r')
    [ "$out" = "hello, zigsaw, from Rust
hello from C, zigsaw (42)
Windows is up: true" ] || { echo "got: $out"; return 1; }
    # C's stderr, from zig's headers and Rust's C runtime.
    [ "$(z run --env=GREET_DEBUG=1 $RUST x 2>&1 >/dev/null | tr -d '\r')" = "greet_c(x)" ]
}
check "it runs, calling its C, and Windows through windows-sys" rust_runs
# windows-sys's raw-dylib imports come from import libraries rustc makes
# with dlltool: Rust's own (GNU), whose libraries GNU ld links correctly;
# llvm-dlltool's left imports unbound (docs/iteration-12.md).
rust_bound() { "$imports" "$ZIGSAW_HOME\\deploy\\$(own_layer $RUST)\\hello.exe"; }
check "the loader binds all its imports" rust_bound
# Each build root has a new random name, so a real path or a time in the
# executable would show.
rust_again() { [ "$(rebuilt_manifest "$work\\rust\\hello.json")" = "$rust_app_digest" ]; }
check "built again, from the vendored crates in the cache, it's the same image" rust_again

# --- Go from source -----------------------------------------------------------------

check "go.json builds the Go SDK image" z build "$root\\recipes\\go.json"
# Go's image keeps GOPATH in its data directory, whose bin is on its PATH, so
# what `go install` installs gets a shim.
mkdir -p "$work\\gotiny" &&
    printf 'module zigsaw.test/zigsaw-gotiny\n\ngo 1.27\n' >"$work\\gotiny\\go.mod" &&
    printf 'package main\n\nimport (\n\t"fmt"\n\t"os"\n)\n\nfunc main() { fmt.Println("gotiny", os.Args[1]) }\n' >"$work\\gotiny\\main.go"
go_installed() {
    local out
    out=$(cd "$work\\gotiny" && z run --command=go org.golang.go install . 2>&1)
    grep -q 'added zigsaw-gotiny to' <<<"$out" || { echo "$out" | tail -3; return 1; }
    [ "$("$bin\\zigsaw-gotiny.exe" hi | tr -d '\r')" = "gotiny hi" ]
}
check "go install gives what it installs a shim" go_installed
# A program built with Go's image, whose GOFLAGS trim paths: it says where
# it was built from, as module paths, and calls Windows.
GOAPP=test.build.go
mkdir -p "$work\\go" && cp "$(cygpath -u "$root")"/tests/build/go/{go.mod,main.go} "$(cygpath -u "$work")/go/" &&
    sed -e "s/@GO@/$(manifest_of org.golang.go)/" -e "s/@BUSYBOX@/$bb_digest/" \
        "$root\\tests\\build\\go\\hello.json.in" >"$work\\go\\hello.json"
check "a Go program builds with Go's image" z build "$work\\go\\hello.json"
go_app_digest=$(manifest_of $GOAPP)
go_runs() {
    local out
    out=$(z run $GOAPP zigsaw | tr -d '\r')
    [ "$out" = "hello, zigsaw, from Go
built from zigsaw.test/hello/main.go
Windows is up: true" ] || { echo "got: $out"; return 1; }
}
check "it runs, with its paths trimmed, and calls Windows" go_runs
go_again() { [ "$(rebuilt_manifest "$work\\go\\hello.json")" = "$go_app_digest" ]; }
check "built again, with Go's kept cache, it's the same image" go_again
# A Go program with C, built with zig's image too, whose variables make zig's
# cc Go's C compiler, so cgo is on, and its links reproducible. The recipe
# leaves Go's build ID out: zig's cc can't tell Go its version, and the
# error Go hashes instead names a temporary file and the store.
CGO=test.build.cgo
mkdir -p "$work\\cgo" && cp "$(cygpath -u "$root")"/tests/build/cgo/{go.mod,main.go,greet.c,greet.h} "$(cygpath -u "$work")/cgo/" &&
    sed -e "s/@GO@/$(manifest_of org.golang.go)/" -e "s/@ZIG@/$zig_digest/" -e "s/@BUSYBOX@/$bb_digest/" \
        "$root\\tests\\build\\cgo\\hello.json.in" >"$work\\cgo\\hello.json"
check "a Go program with C builds with Go's and zig's images, cgo on by itself" z build "$work\\cgo\\hello.json"
cgo_app_digest=$(manifest_of $CGO)
cgo_runs() {
    local out
    out=$(z run $CGO zigsaw | tr -d '\r')
    [ "$out" = "hello, zigsaw, from Go and C
twice 21 is 42
built from zigsaw.test/cgo/main.go
C sees this process: true" ] || { echo "got: $out"; return 1; }
}
check "it runs, calling its C, which calls Windows" cgo_runs
cgo_again() { [ "$(rebuilt_manifest "$work\\cgo\\hello.json")" = "$cgo_app_digest" ]; }
check "built again, it's the same image" cgo_again

# Removing the apps also deletes their AppContainer profiles. The images
# builds use stay until prune --downloads, and only zigsaw can delete their
# protected deployments.
for id in $APP $SDK $RT test.image.built $AAPP $ASDK $TOOL test.alias.built test.alias.files io.prettier.prettier org.nodejs.node $BB $HELLO org.ziglang.zig org.cmake.cmake $CMAKEAPP com.mesonbuild.meson $MESONAPP org.sqlite.sqlite3 \
    test.build.online test.build.ok test.build.slow test.build.msvc test.build.noted test.tool.cachey test.build.cached \
    test.build.vendored org.rust-lang.rust $RUST org.golang.go $GOAPP $CGO; do z rm --delete-data $id >/dev/null 2>&1; done
z prune --downloads --data >/dev/null 2>&1
check "prune --downloads deletes tools' caches" sh -c "[ -z \"\$(ls '$ZIGSAW_HOME\\cache\\tools')\" ]"
rm -rf "$ZIGSAW_HOME" "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
