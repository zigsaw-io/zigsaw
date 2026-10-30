#!/usr/bin/env bash
# End-to-end checks for building apps: runtimes, which an app runs with and
# whose layers travel in its image, and build commands, which build an app
# from source with SDK images (zig, busybox, CMake, Meson, Rust, Go with and
# without C, .NET, and Java with Maven and Gradle), tools' caches and
# aliases, and vendor steps; 7-Zip
# unpacks a source zigsaw doesn't; projects with a zigsaw.json, whose own
# files are a source.
#
#   tests/build.sh [path\to\zigsaw.exe]
#   GROUP=<group> tests/build.sh [path\to\zigsaw.exe]
#   tests/build.sh --groups
#
# GROUP runs only that group's sections (see groups below), as each of the
# Reproduce workflow's build jobs does; --groups lists the groups.
#
# Needs Git Bash (and its git) and network access (busybox, Node, Prettier, zig, CMake,
# zlib, SQLite, Rust, Go, .NET, OpenJDK, Maven and Gradle downloads, crates
# from crates.io, a package from nuget.org, and packages and plugins from
# Maven Central and Gradle's plugin portal). Always uses temporary stores, since it removes
# apps, and deletes them afterwards. To skip downloading what a store already
# has (zig's is 97 MB, Rust's 150 MB, .NET's SDK 300 MB),
# set SEED_DOWNLOADS to its cache\downloads directory; its files are linked,
# or copied, into the temporary stores.
#
# The build commands' checks map B:, as every build does, and briefly map it
# themselves with subst. Don't run this while B: is in use.

set -u
export MSYS_NO_PATHCONV=1

# The sections below (`if section <name>`), in the groups the Reproduce
# workflow runs in parallel jobs, one job a group. A group runs its sections
# in this file's order, each in exactly one group. The minutes are what the
# sections took on a runner in iteration 33, without the setup every group
# has (BusyBox's image), and with zig's image where a group builds with it.
groups=(
    "base: runtimes images extensions aliases projects prettier msvc sevenzip" # 2
    "zig: commands sqlite"                                                     # 7
    "cmake-meson: cmake llvm meson make"                                       # 7
    "langs: rust go dotnet java php"                                           # 9
)
if [ "${1:-}" = --groups ]; then
    printf '%s\n' "${groups[@]%%:*}"
    exit 0
fi
sections=$(grep -oE '^if section [a-z-]+' "${BASH_SOURCE[0]}" | cut -d' ' -f3)
grouped=$(printf '%s\n' "${groups[@]#*:}" | tr ' ' '\n' | grep -v '^$')
problems=$({ printf '%s\n' $sections $grouped | sort | uniq -u; printf '%s\n' $grouped | sort | uniq -d; } | tr '\n' ' ')
[ -z "$problems" ] || { echo "sections in no group, in two, or not in this file: $problems"; exit 1; }
[ -z "${GROUP:-}" ] || printf '%s\n' "${groups[@]%%:*}" | grep -qx "$GROUP" || { echo "no group $GROUP"; exit 1; }
# section <name>: whether this run checks that section: all do without GROUP.
section() {
    [ -n "${GROUP:-}" ] || return 0
    local g
    for g in "${groups[@]}"; do
        [ "${g%%:*}" = "$GROUP" ] && [[ " ${g#*:} " == *" $1 "* ]] && return 0
    done
    return 1
}

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
bin="$ZIGSAW_HOME\\bin"
# Apps that may use the user's folders, as 7-Zip's Documents, find none here,
# rather than yours.
export ZIGSAW_USER_FOLDERS="$work\\no-folders"
# tests/imports.zig: whether the loader binds every import of a program.
(cd "$root" && zig build imports) || { echo "building the import checker failed"; exit 1; }
imports="$root\\zig-out\\test\\zigsaw-imports.exe"
# Apps run from the work directory: a low run labels the directory of an app
# with cwd, and the repository's programs, zigsaw too, would start at low
# integrity after that.
cd "$work" || exit 1

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
free_afterwards() { drive_free && no_build_root; }
# Builds a recipe again, even if nothing changed, and prints its digest.
rebuilt_manifest() { z build --rebuild "$1" 2>&1 | grep -o 'manifest sha256:[0-9a-f]*' | cut -d' ' -f2; }
# need_zig: builds zig's image, once, for the sections that build with it.
zig_digest=
need_zig() {
    [ -z "$zig_digest" ] || return 0
    z build "$root\\recipes\\zig.json" >/dev/null 2>&1 || { echo "building zig failed"; exit 1; }
    zig_digest=$(manifest_of org.ziglang.zig)
}

# Every section but a few builds with BusyBox's image, or runs it.
z build "$root\\recipes\\busybox.json" >/dev/null 2>&1 || { echo "building busybox failed"; exit 1; }
bb_digest=$(manifest_of $BB)

# --- runtimes ---------------------------------------------------------------------

if section runtimes; then

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
fi

# --- images as sources -------------------------------------------------------------

if section images; then
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
fi

# --- extension points -----------------------------------------------------------------

if section extensions; then
# A runtime, BusyBox, with an extension point that joins EXT_DIRS; images
# that extend it, each adding its directory: a, b (which needs c), c, and old
# (for another version of the point); an app with the runtime that adds a
# directory of its own; another that lists a as a runtime itself.
XRT=test.ext.rt
XAPP=test.ext.app
mkdir -p "$work\\ext" && cp "$ZIGSAW_HOME\\deploy\\$(own_layer $BB)\\busybox.exe" "$work\\ext\\" &&
    for x in a b c old app; do echo "marker $x" >"$work\\ext\\marker-$x.txt"; done
cat >"$work\\ext\\rt.json" <<EOF
{ "id": "$XRT", "version": "1", "command": "busybox.exe", "exports": {},
  "env": { "EXT_DIRS": "\${app}\\\\base" },
  "extensions": { "$XRT": { "version": "1", "join": ["EXT_DIRS"] } },
  "modules": [{ "name": "m", "sources": [{ "path": "busybox.exe" }] }] }
EOF
# ext_recipe <name> <point version> [<needs>]
ext_recipe() {
    local needs=""
    [ -n "${3:-}" ] && needs=", \"needs\": [\"$3\"]"
    cat <<EOF
{ "id": "test.ext.$1", "version": "1", "command": "marker.txt", "exports": {},
  "env": { "EXT_DIRS": "\${app}", "EXT_$(echo "$1" | tr a-z A-Z)": "\${app}" },
  "extends": { "point": "$XRT", "version": "$2"$needs },
  "modules": [{ "name": "m", "sources": [{ "path": "marker-$1.txt", "dest": "marker.txt" }] }] }
EOF
}
ext_recipe a 1 >"$work\\ext\\a.json"
ext_recipe b 1 test.ext.c >"$work\\ext\\b.json"
ext_recipe c 1 >"$work\\ext\\c.json"
ext_recipe old 0 >"$work\\ext\\old.json"
builds_ext() {
    local r
    for r in rt a b c old; do z build "$work\\ext\\$r.json" >/dev/null 2>&1 || { z build "$work\\ext\\$r.json" 2>&1 | tail -1; return 1; }; done
}
check "a runtime with an extension point and four extensions build" builds_ext
xrt_digest=$(manifest_of $XRT)
xa_digest=$(manifest_of test.ext.a)
cat >"$work\\ext\\app.json" <<EOF
{ "id": "$XAPP", "version": "1", "command": "\${rt}\\\\busybox.exe", "exports": {},
  "env": { "EXT_DIRS": "\${app}\\\\own" },
  "runtimes": { "rt": "$XRT@$xrt_digest" },
  "modules": [{ "name": "m", "sources": [{ "path": "marker-app.txt", "dest": "marker.txt" }] }] }
EOF
check "an app with the runtime builds" z build "$work\\ext\\app.json"
dir_of() { echo "$ZIGSAW_HOME\\deploy\\$(own_layer "$1")"; }
# ext_dirs <run args...>: EXT_DIRS as a run of BusyBox's sh shows it, with '\'.
ext_dirs() { z run "$@" sh -c 'echo "$EXT_DIRS"' 2>/dev/null | tr -d '\r' | tr '/' '\\'; }
expect_dirs() {
    local want=$1 got
    shift
    got=$(ext_dirs "$@")
    [ "$got" = "$want" ] || { echo "EXT_DIRS is $got"; return 1; }
}
xa=$(dir_of test.ext.a) xb=$(dir_of test.ext.b) xc=$(dir_of test.ext.c)
# Run itself, the runtime is the app, whose own entries come last.
check "a run of the runtime has its extensions, each after those it needs, the old one left out" \
    expect_dirs "$xa;$xc;$xb;$(dir_of $XRT)\\base" $XRT
check "it says why the old one doesn't join" sh -c "\"\$0\" run $XRT true 2>&1 | grep -qF 'test.ext.old doesn'\''t join this run: it was built for $XRT 0, and this is 1'" "$zigsaw"
check "an app with the runtime has them too, then its own entry" \
    expect_dirs "$(dir_of $XRT)\\base;$xa;$xc;$xb;$(dir_of $XAPP)\\own" $XAPP
check "list shows the point and what extends it" sh -c "\"\$0\" list | grep '^$XRT ' | grep -q '(extension point $XRT)' && \"\$0\" list | grep '^test.ext.a ' | grep -q '(extends $XRT 1)'" "$zigsaw"
ext_var() { [ "$(z run $XAPP sh -c 'cat "$EXT_A/marker.txt"' 2>/dev/null | tr -d '\r')" = "marker a" ]; }
check "an extension's own variables are set, with \${app} its directory" ext_var
check "--noextension leaves one out, and what needs it" \
    expect_dirs "$(dir_of $XRT)\\base;$xa;$(dir_of $XAPP)\\own" --noextension=test.ext.c $XAPP
overridden() {
    z override --noextension=test.ext.a $XAPP >/dev/null 2>&1 &&
        expect_dirs "$(dir_of $XRT)\\base;$xc;$xb;$(dir_of $XAPP)\\own" $XAPP &&
        expect_dirs "$(dir_of $XRT)\\base;$xa;$xc;$xb;$(dir_of $XAPP)\\own" --extension=test.ext.a $XAPP &&
        z override --extension=test.ext.a $XAPP 2>&1 | grep -q 'has no overrides now' &&
        z override $XAPP 2>&1 | grep -q 'has no overrides'
}
check "an override leaves one out; --extension has it join again, and saves nothing" overridden
# An app with a as a runtime of its own: that one, not the installed one.
sed -e "s/\"id\": \"$XAPP\"/\"id\": \"test.ext.app2\"/" -e "s/\"runtimes\": {/\"runtimes\": { \"a\": \"test.ext.a@$xa_digest\",/" "$work\\ext\\app.json" >"$work\\ext\\app2.json"
check "an app that lists an extension as a runtime builds" z build "$work\\ext\\app2.json"
check "it has that extension once, as its runtime" \
    expect_dirs "$xa;$(dir_of $XRT)\\base;$xc;$xb;$(dir_of test.ext.app2)\\own" test.ext.app2
sandboxed_ext() {
    local sb
    for sb in low appcontainer; do
        [ "$(z run --sandbox=$sb $XAPP sh -c 'cat "$EXT_A/marker.txt"' 2>/dev/null | tr -d '\r')" = "marker a" ] || { echo "$sb: can't read test.ext.a's file"; return 1; }
    done
}
check "the low and appcontainer sandboxes can read an extension's files" sandboxed_ext
removed_ext() { z rm test.ext.a >/dev/null 2>&1 && expect_dirs "$xc;$xb;$(dir_of $XRT)\\base" $XRT; }
check "an extension removed doesn't join any more" removed_ext
printf '{ "id": "test.ext.bad", "version": "1", "command": "marker.txt", "exports": {}, "extends": { "point": "%s", "version": "1" }, "runtimes": { "rt": "%s@%s" },\n  "modules": [{ "name": "m", "sources": [{ "path": "marker-a.txt", "dest": "marker.txt" }] }] }\n' $XRT $XRT "$xrt_digest" >"$work\\ext\\bad.json"
check "an extension with runtimes is refused" sh -c "\"\$0\" build '$work\\ext\\bad.json' 2>&1 | grep -q 'an extension can.t have runtimes'" "$zigsaw"
fi

# --- aliases in runs, and SDKs with runtimes ------------------------------------------

if section aliases; then
# A tool image with aliases, all BusyBox: greet echoes "tool:", ar echoes
# (over BusyBox's own ar applet), fail exits 7, shout drops --quiet. An app
# that has it as a runtime and an alias greet of its own, another, rt, that
# runs the runtime's busybox.exe, and runs BusyBox's sh from the runtime.
# And an SDK that has the tool as its runtime, and an alias that runs it.
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
    local aliases='"aliases": { "greet": { "command": "busybox.exe", "args": ["echo", "app:"] }, "rt": { "command": "${tool}/busybox.exe", "args": ["echo", "rt:", "${tool}"] } },'
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
check "the app's alias runs its runtime's file, \${tool} its directory" sh -c '[ "$("$0" run '$AAPP' -c "rt x" | tr -d "\r" | tr / \\\\)" = "rt: $1\\deploy\\$2 x" ]' "$zigsaw" "$ZIGSAW_HOME" "$(own_layer $TOOL)"
check "the runtime's variables come with it" sh -c '[ "$("$0" run '$AAPP' -c "echo \$ALIAS_TOOL" | tr -d "\r" | tr / \\\\)" = "$1\\deploy\\$2" ]' "$zigsaw" "$ZIGSAW_HOME" "$(own_layer $TOOL)"
records_aliases() { config_of $AAPP | tr -d ' \r\n' | grep -q '"runtimes":{"tool":{.*"aliases":{"greet":{"command":"busybox.exe","args":\["echo","tool:"\]}'; }
check "the app's config records the runtime's aliases" records_aliases
unchanged_shims() {
    local dir="$ZIGSAW_HOME\\aliases\\$AAPP" before after
    before=$(cd "$dir" && ls -l --time-style=full-iso)
    z run $AAPP -c true && after=$(cd "$dir" && ls -l --time-style=full-iso)
    [ "$before" = "$after" ] && [ "$(ls "$dir" | wc -l)" -eq 10 ] || { echo "$after"; return 1; }
}
check "a second run rewrites none of the 10 shim files (5 aliases)" unchanged_shims
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
  "aliases": { "hello": { "command": "\${tool}\\\\busybox.exe", "args": ["echo", "sdk hello"] } },
  "modules": [{ "name": "m", "sources": [{ "path": "y.h", "dest": "include/y.h" }] }] }
EOF
check "an SDK with the tool as its runtime builds" z build "$work\\alias\\sdk.json"
asdk_digest=$(manifest_of $ASDK)
with_sdk_recipe() {
    local extra=${1:-}
    printf '{ "id": "test.alias.built", "version": "1", "command": "b.txt", "exports": {}, "sdk": { "s": "%s@%s"%s },\n  "modules": [{ "name": "m", "build": ["greet built > \\"$PREFIX/b.txt\\"", "hello there > \\"$PREFIX/h.txt\\"", "echo \\"$ALIAS_TOOL\\" > \\"$PREFIX/t.txt\\"", "echo \\"$PATH\\" > \\"$PREFIX/p.txt\\""] }] }\n' \
        $ASDK "$asdk_digest" "$extra"
}
sdk_brings_tool() {
    with_sdk_recipe >"$work\\alias\\built.json"
    z build "$work\\alias\\built.json" >/dev/null 2>&1 || { z build "$work\\alias\\built.json" 2>&1 | tail -1; return 1; }
    local dir="$ZIGSAW_HOME\\deploy\\$(own_layer test.alias.built)"
    [ "$(tr -d '\r' <"$dir\\b.txt")" = "tool: built" ] || { echo "b.txt: $(cat "$dir\\b.txt")"; return 1; }
    [ "$(tr -d '\r' <"$dir\\h.txt")" = "sdk hello there" ] || { echo "h.txt: $(cat "$dir\\h.txt")"; return 1; }
    [ "$(tr -d '\r' <"$dir\\t.txt" | tr '/' '\\')" = "$ZIGSAW_HOME\\deploy\\$(own_layer $TOOL)" ] || { echo "t.txt: $(cat "$dir\\t.txt")"; return 1; }
}
check "a build with the SDK gets its runtime's aliases and variables, and its own alias that runs the runtime's file" sdk_brings_tool
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
fi

# --- projects with a zigsaw.json -----------------------------------------------------

if section projects; then
# A project with a zigsaw.json at its root, which `zigsaw build` builds as
# make builds a Makefile. Its module lists the files and directories it got,
# which should be those git would commit, less what "skip" leaves out.
PROJ=test.project.app
proj="$work\\proj"
: >"$work\\empty"
# git with no settings but the repository's, as a fresh clone has.
pgit() { GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$work\\empty" git -c core.excludesFile="$work\\empty" -C "$proj" "$@"; }
mkdir -p "$proj" && (
    cd "$(cygpath -u "$proj")" || exit 1
    mkdir -p src out docs/x notes empty/below
    printf '*.log\n!keep.log\nout/\n/top-only.txt\ndocs/**/draft.md\n' >.gitignore
    printf 'gen.txt\n' >src/.gitignore
    for f in a.log keep.log top-only.txt src/top-only.txt src/main.txt src/gen.txt src/X.LOG out/bin.txt docs/index.md docs/x/draft.md notes/skipped.txt 'with space.txt'; do
        echo "$f" >"$f"
    done
    cat >zigsaw.json <<EOF
{
  "id": "$PROJ", "version": "1", "command": "files.txt", "exports": {},
  "sdk": { "busybox": "$BB@$bb_digest" },
  "modules": [{
    "name": "files",
    "sources": [{ "path": ".", "skip": ["/notes"] }],
    "build": ["find . -type f | cut -c3- >\"\$PREFIX/files.txt\"", "find . -type d >\"\$PREFIX/dirs.txt\""]
  }]
}
EOF
)
pgit init -q
# Everything in it, and what git says of it, to check the build wrote nothing.
proj_state() { (cd "$(cygpath -u "$proj")" && find . | LC_ALL=C sort) && pgit status --porcelain --ignored; }
proj_before=$(proj_state)

builds_here() { (cd "$proj" && z build); }
check "with no argument, build builds the zigsaw.json of the current directory" builds_here
proj_digest=$(manifest_of $PROJ)
committed() {
    local dir="$ZIGSAW_HOME\\deploy\\$(own_layer $PROJ)" want got
    want=$(pgit ls-files -co --exclude-standard | grep -v '^notes/' | LC_ALL=C sort)
    got=$(tr -d '\r' <"$dir\\files.txt" | LC_ALL=C sort)
    [ "$got" = "$want" ] || { echo "got:" $got "want:" $want; return 1; }
    ! grep -q empty "$dir\\dirs.txt" || { echo "it got the empty directory"; return 1; }
}
check "it got the files git would commit, less what skip leaves out, and no empty directory" committed
untouched() { [ "$(proj_state)" = "$proj_before" ] || { echo "the project's directory changed"; return 1; }; }
check "the build wrote nothing in the project's directory" untouched
reused() { (cd "$work" && z -v build "$proj" 2>&1) | grep -q "built before from the same inputs"; }
check "given the directory, build reuses the image of the same files" reused
echo changed >"$proj\\a.log"
check "an ignored file changed, it still does" reused
echo changed >"$proj\\src\\main.txt"
rebuilds() { local d; d=$(built_manifest "$proj") && [ -n "$d" ] && [ "$d" != "$proj_digest" ] || { echo "got $d"; return 1; }; }
check "a committed file changed, it builds a new image" rebuilds
records_files() {
    local h
    h=$(z -v build "$proj" 2>&1 | grep -o "module files: [0-9]* files from .* (sha256 [0-9a-f]*)" | grep -o '[0-9a-f]\{64\}')
    [ -n "$h" ] && config_of $PROJ | tr -d ' \r\n' | grep -q "\"sources\":\[\"$h\"\]"
}
check "the image's record of the build has the hash of its files" records_files
echo again >"$proj\\src\\main.txt"
check "update rebuilds it from the directory as it is" sh -c "\"\$0\" update $PROJ 2>&1 | grep -q '^updated $PROJ'" "$zigsaw"
no_manifest() { (cd "$work" && z build 2>&1) | grep -q "has no zigsaw.json; give a recipe"; }
check "a directory without one fails, saying so" no_manifest

# Without build commands, a directory's files go into the image as they are.
printf '{ "id": "test.project.lib", "version": "1", "command": "lib/main.txt", "exports": {},\n  "modules": [{ "name": "lib", "sources": [{ "path": "src", "dest": "lib" }] }] }\n' >"$proj\\lib.json"
placed() {
    z build "$proj\\lib.json" >/dev/null 2>&1 || { z build "$proj\\lib.json" 2>&1 | tail -1; return 1; }
    local dir="$ZIGSAW_HOME\\deploy\\$(own_layer test.project.lib)"
    [ -f "$dir\\lib\\main.txt" ] && [ -f "$dir\\lib\\top-only.txt" ] && [ ! -e "$dir\\lib\\gen.txt" ] && [ ! -e "$dir\\lib\\X.LOG" ] ||
        { echo "files: $(cd "$dir" && find . -type f)"; return 1; }
}
check "without build commands, a subdirectory's files are placed, with the .gitignore files above it" placed
printf '{ "id": "test.project.pinned", "version": "1", "command": "x", "exports": {}, "modules": [{ "name": "m", "sources": [{ "path": "src", "sha256": "%064d" }] }] }\n' 0 >"$proj\\pinned.json"
check "a directory can't be pinned with a sha256" sh -c "\"\$0\" build '$proj\\pinned.json' 2>&1 | grep -q 'is a directory, whose files are hashed'" "$zigsaw"
# A link: git would commit it as a link, which an image can't hold.
mkdir -p "$work\\linked" && echo a >"$work\\linked\\a.txt" && cmd /c mklink /J "$work\\linked\\to-src" "$proj\\src" >/dev/null
linked_recipe() { printf '{ "id": "test.project.linked", "version": "1", "command": "a.txt", "exports": {}, "modules": [{ "name": "m", "sources": [{ "path": "."%s }] }] }\n' "$1" >"$work\\linked\\zigsaw.json"; }
linked_recipe ""
check "a link in a project fails the build, naming it" sh -c "\"\$0\" build '$work\\linked' 2>&1 | grep -q 'to-src is a link, which an image can'" "$zigsaw"
linked_recipe ', "skip": ["/to-src"]'
check "skipped, the project builds" z build "$work\\linked"

# Built again, a project's module starts in the work directory its last
# build left, its sources brought up to date there: make remakes only what a
# changed file makes. make.log, which make's rules add to, stays in the work
# directory (cache\work\<key>\incmake in the store); the image holds what
# they made, and note.txt, which a build command edits in place.
INC=test.project.incremental
inc="$work\\inc"
mkdir -p "$inc" && (
    cd "$(cygpath -u "$inc")" || exit 1
    printf 'out/\n' >.gitignore
    echo a >a.in && echo b >b.in && echo c >c.in && echo note >note.in
    printf 'all: out/a.txt out/b.txt\nout/a.txt: a.in\n\tmkdir -p out && sed s/a/A/ a.in >out/a.txt && echo a >>make.log\nout/b.txt: b.in\n\tmkdir -p out && sed s/b/B/ b.in >out/b.txt && echo b >>make.log\n' >Makefile
)
inc_recipe() {
    printf '{ "id": "%s", "version": "%s", "command": "a.txt", "exports": {}, "sdk": { "busybox": "%s@%s" },\n  "modules": [{ "name": "incmake", "sources": [{ "path": "." }],\n    "build": ["make", "sed -i s/$/!/ note.in", "cp out/a.txt out/b.txt note.in \\"$PREFIX/\\""] }] }\n' \
        $INC "$1" $BB "$bb_digest" >"$inc\\zigsaw.json"
}
inc_recipe 1
inc_before=$(cd "$(cygpath -u "$inc")" && find . | LC_ALL=C sort)
inc_log() { cat "$(cygpath -u "$ZIGSAW_HOME")"/cache/work/*/incmake/make.log 2>/dev/null | tr -d '\r' | tr '\n' ' '; }
want_log() { [ "$(inc_log)" = "$1" ] || { echo "make.log: '$(inc_log)', want '$1'"; return 1; }; }
inc_first() { z build "$inc" >/dev/null && want_log "a b "; }
check "a project's first build makes everything" inc_first
inc_again() {
    echo a2 >"$inc\\a.in"
    local d
    d=$(built_manifest "$inc") && [ -n "$d" ] && echo "$d" >"$work\\inc-digest" && want_log "a b a " || return 1
    [ "$(tr -d '\r' <"$ZIGSAW_HOME\\deploy\\$(own_layer $INC)\\note.in")" = 'note!' ] || { echo "note.in was edited twice"; return 1; }
}
check "built again after a change, make remakes only what it makes, and a file the build edits starts afresh" inc_again
inc_clean() { [ "$(z build --clean "$inc" 2>&1 | grep -o 'manifest sha256:[0-9a-f]*' | cut -d' ' -f2)" = "$(cat "$work\\inc-digest")" ] && want_log "a b "; }
check "with --clean, it makes everything again, and the same image" inc_clean
inc_removed() { rm "$inc\\c.in" && z build "$inc" >/dev/null && ! ls "$(cygpath -u "$ZIGSAW_HOME")"/cache/work/*/incmake/c.in >/dev/null 2>&1; }
check "a file the project no longer has is gone from the work directory" inc_removed
inc_recipe_changed() { inc_recipe 2 && z build "$inc" >/dev/null && want_log "a b "; }
check "the recipe changed, it starts afresh" inc_recipe_changed
inc_untouched() { [ "$(cd "$(cygpath -u "$inc")" && find . | LC_ALL=C sort | grep -v -e '^\./c\.in$')" = "$(grep -v -e '^\./c\.in$' <<<"$inc_before")" ]; }
check "the project's directory has no build output" inc_untouched
inc_prune_note() { z prune --dry-run 2>&1 | grep -q 'kept the work directories of [0-9]* project(s)'; }
check "prune keeps work directories, unless --downloads" inc_prune_note
fi

# --- prettier on node --------------------------------------------------------------

if section prettier; then
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
fi

# --- build commands ---------------------------------------------------------------

if section commands; then
HELLO=test.build.hello
need_zig

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
check "the build drive is free afterwards, and the build root gone" free_afterwards

# zig's image puts its cache in ${cache}, which builds keep: building again
# doesn't build zig's C runtime again, and makes the same image.
warm_hello() {
    [ -d "$ZIGSAW_HOME\\cache\\tools\\org.ziglang.zig" ] || { echo "no cache\\tools\\org.ziglang.zig"; return 1; }
    [ "$(rebuilt_manifest "$work\\c\\hello.json")" = "$hello_digest" ]
}
start=$SECONDS
check "a rebuild with zig's kept cache makes the same image" warm_hello
printf '      (%d s; the first build took %d s)\n' $((SECONDS - start)) "$hello_time"
check "zig run as an app has its cache in its data directory" sh -c "\"\$0\" run org.ziglang.zig env | grep '\.global_cache_dir' | grep -qF 'data\\\\org.ziglang.zig\\\\cache\"'" "$zigsaw"
# A toolchain's image asks for soft: at low, what it built would be labelled
# low, and Windows starts a program labelled low at low integrity, wherever
# it's started from.
zig_soft() {
    z -v run org.ziglang.zig version 2>&1 | grep -q '^sandbox  soft' || { echo "zig's run isn't soft"; return 1; }
    ! icacls "$work" | grep -q 'Mandatory Label' || { echo "it labelled its working directory"; return 1; }
}
check "zig's image runs under soft unless told otherwise, and labels nothing" zig_soft

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
fi

# --- CMake --------------------------------------------------------------------------

if section cmake; then
need_zig
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
# CMake's image finds nothing the machine has installed: no Program Files
# among the prefixes it searches (its WindowsPaths.cmake, which found a
# runner's PostgreSQL for Qt), so no Git from there, as this machine and
# runners have, no package registries, and no Python from the registry.
mkdir -p "$work\\cmake-hermetic" && cp "$root\\tests\\build\\cmake\\hermetic\\CMakeLists.txt" "$work\\cmake-hermetic\\" &&
    sed -e "s/@CMAKE@/$(manifest_of org.cmake.cmake)/" -e "s/@BUSYBOX@/$bb_digest/" \
        "$root\\tests\\build\\cmake\\hermetic\\hermetic.json.in" >"$work\\cmake-hermetic\\hermetic.json"
cmake_hermetic() {
    z build "$work\\cmake-hermetic\\hermetic.json" >"$work\\cmake-hermetic.log" 2>&1 || { tail -3 "$work\\cmake-hermetic.log"; return 1; }
    local found
    found=$(tr -d '\r' <"$ZIGSAW_HOME\\deploy\\$(own_layer test.build.cmake-hermetic)\\found.txt")
    ! grep -qi 'program files' <<<"$found" || { echo "$found"; return 1; }
    grep -qx 'git=GIT-NOTFOUND' <<<"$found" && grep -qx 'registry=OFF' <<<"$found" && grep -qx 'system registry=OFF' <<<"$found" &&
        grep -qx 'python=FALSE' <<<"$found" || { echo "$found"; return 1; }
}
check "CMake searches no Program Files, package registries or registry Pythons" cmake_hermetic
fi

# --- llvm-mingw -------------------------------------------------------------------

if section llvm; then
# The CMake project again, with llvm-mingw's image instead of zig's: its
# Clang and lld, through aliases of the same names and the same variables.
# Its program links libc++ and libunwind in, and neither it nor the static
# library the image keeps changes with the time it's built at.
LLVMAPP=test.build.cmake-llvm
check "llvm-mingw.json builds llvm-mingw's image" z build "$root\\recipes\\llvm-mingw.json"
[ -f "$ZIGSAW_HOME\\refs\\org.cmake.cmake.json" ] || z build "$root\\recipes\\cmake.json" >/dev/null 2>&1
mkdir -p "$work\\cmake-llvm" && cp "$(cygpath -u "$root")"/tests/build/c/*.{c,h,cpp,rc} "$(cygpath -u "$root")"/tests/build/cmake/CMakeLists.txt "$(cygpath -u "$work")/cmake-llvm/" &&
    sed -e "s/\"test.build.cmake\"/\"$LLVMAPP\"/" -e "s/\"zig\": \"org.ziglang.zig@@ZIG@\"/\"llvm\": \"com.github.mstorsjo.llvm-mingw@$(manifest_of com.github.mstorsjo.llvm-mingw)\"/" \
        -e 's|"cleanup": \["/include", "/lib"\],|"cleanup": ["/include"],|' \
        -e "s/@CMAKE@/$(manifest_of org.cmake.cmake)/" -e "s/@BUSYBOX@/$bb_digest/" \
        "$root\\tests\\build\\cmake\\hello.json.in" >"$work\\cmake-llvm\\hello.json"
check "a CMake project of C, C++ and resources builds with CMake's and llvm-mingw's images" z build "$work\\cmake-llvm\\hello.json"
llvm_app_digest=$(manifest_of $LLVMAPP)
llvm_runs() {
    local out exe
    out=$(z run $LLVMAPP zigsaw | tr -d '\r')
    [ "$out" = "hello, zigsaw
built from B:/src/hello/main.c
twice 21 is 42
a string from its resources" ] || { echo "got: $out"; return 1; }
    exe="$ZIGSAW_HOME\\deploy\\$(own_layer $LLVMAPP)\\bin\\hello.exe"
    ! grep -aqiE 'lib(c\+\+|unwind|winpthread-1)\.dll' "$exe" || { echo "hello.exe imports a DLL of llvm-mingw's"; return 1; }
    [ -f "$ZIGSAW_HOME\\deploy\\$(own_layer $LLVMAPP)\\lib\\libgreet.a" ] || { echo "the image has no libgreet.a"; return 1; }
}
check "it runs, with libc++ linked in" llvm_runs
llvm_again() { [ "$(rebuilt_manifest "$work\\cmake-llvm\\hello.json")" = "$llvm_app_digest" ]; }
check "built again a moment later, it's the same image" llvm_again
fi

# --- Meson --------------------------------------------------------------------------

if section meson; then
need_zig
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
fi

# --- GNU make -----------------------------------------------------------------------

if section make; then
need_zig
# GNU make's image (built with zig) runs a Makefile only GNU make reads
# (patsubst, foreach, define and call, $(shell), a pattern rule) with -j4
# and a sub-make; its recipes run in BusyBox's sh through the image's
# sh.exe, so echo, mkdir -p and a for loop are BusyBox's, on any line.
MAKEAPP=test.build.make
check "make.json builds GNU make's image" z build "$root\\recipes\\make.json"
mkdir -p "$work\\make" && cp "$(cygpath -u "$root")"/tests/build/make/{Makefile,sub.mk,*.c} "$(cygpath -u "$work")/make/" &&
    sed -e "s/@MAKE@/$(manifest_of org.gnu.make)/" -e "s/@ZIG@/$zig_digest/" -e "s/@BUSYBOX@/$bb_digest/" \
        "$root\\tests\\build\\make\\make.json.in" >"$work\\make\\make.json"
check "a GNU Makefile builds with make's, zig's and BusyBox's images" z build "$work\\make\\make.json"
make_runs() {
    local out dir="$ZIGSAW_HOME\\deploy\\$(own_layer $MAKEAPP)"
    out=$(z run $MAKEAPP | tr -d '\r')
    [ "$out" = "one plus two is 3" ] || { echo "got: $out"; return 1; }
    out=$(cat "$dir\\names.txt" "$dir\\shell.txt" "$dir\\sub.txt" | tr -d '\r')
    [ "$out" = "one
two
shell works
the sub-make ran" ] || { echo "got: $out"; return 1; }
}
check "it runs, and the recipes ran in sh" make_runs
fi

# --- MSVC, if Visual Studio is installed ----------------------------------------------

if section msvc; then
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
fi

# --- SQLite from source ------------------------------------------------------------

if section sqlite; then
check "sqlite.json builds SQLite and zlib from source" z build "$root\\recipes\\sqlite.json"
check "sqlite3 runs, with zlib" sh -c "[ \"\$(\"\$0\" run org.sqlite.sqlite3 :memory: 'select sqlite_version(), length(sqlar_uncompress(sqlar_compress(zeroblob(1000)), 1000))' | tr -d '\r')\" = '3.53.4|1000' ]" "$zigsaw"
fi

# --- 7-Zip, for sources zigsaw doesn't unpack -----------------------------------------

if section sevenzip; then
check "7zip.json makes 7-Zip's image from its installer, which its 7zr unpacks" z build "$root\\recipes\\7zip.json"
# A .7z, made with 7-Zip's image, is the source of a recipe that has 7-Zip
# in its sdk to unpack it, as recipes can for installers and .7z downloads.
SEVENZIP=test.build.sevenzip
mkdir -p "$work\\7z\\in" && printf '@echo hello from a .7z\r\n' >"$work\\7z\\in\\hello.cmd"
(cd "$work\\7z\\in" && z run org.7_zip.7zip a -bd hello.7z hello.cmd >/dev/null 2>&1) && mv "$work\\7z\\in\\hello.7z" "$work\\7z\\"
sed -e "s/@SEVENZIP@/$(manifest_of org.7_zip.7zip)/" -e "s/@BUSYBOX@/$bb_digest/" \
    "$root\\tests\\build\\sevenzip\\hello.json.in" >"$work\\7z\\hello.json"
check "a recipe with 7-Zip in its sdk unpacks a .7z source" z build "$work\\7z\\hello.json"
check "what it unpacked runs" sh -c "[ \"\$(\"\$0\" run $SEVENZIP | tr -d '\r')\" = 'hello from a .7z' ]" "$zigsaw"
fi

# --- Rust from source ---------------------------------------------------------------

if section rust; then
need_zig
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
fi

# --- Go from source -----------------------------------------------------------------

if section go; then
need_zig
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
fi

# --- .NET from source ---------------------------------------------------------------

if section dotnet; then
# Microsoft's licence for its Windows binaries doesn't let them be published,
# so .NET's recipes are in recipes/no-publish: the images are built here from
# Microsoft's download, and the runtime from the SDK image's own files.
check "dotnet-sdk.json builds the .NET SDK image" z build "$root\\recipes\\no-publish\\dotnet-sdk.json"
check "dotnet.json builds the .NET runtime image from it" z build "$root\\recipes\\no-publish\\dotnet.json"
dotnet_version=$(grep -o '"version": *"[^"]*"' "$root\\recipes\\no-publish\\dotnet.json" | cut -d'"' -f4)
runtime_files() {
    local d="$ZIGSAW_HOME\\deploy\\$(own_layer com.microsoft.dotnet)"
    for f in dotnet.exe shared/Microsoft.NETCore.App/$dotnet_version shared/Microsoft.AspNetCore.App shared/Microsoft.WindowsDesktop.App; do
        [ -e "$d\\$f" ] || { echo "no $f"; return 1; }
    done
    for f in sdk packs templates; do [ ! -e "$d\\$f" ] || { echo "has $f"; return 1; }; done
}
check "the runtime has dotnet.exe and the three shared frameworks, not the SDK's tools and packs" runtime_files
# The SDK's image keeps the CLI's and NuGet's files in its data directory: on
# .NET, NuGet finds the profile with SHGetKnownFolderPath, which a run's
# USERPROFILE doesn't move, unless DOTNET_CLI_HOME says where it is.
mkdir -p "$work\\dotnettiny"
sdk_builds_cwd() {
    local out
    out=$(cd "$work\\dotnettiny" && z run com.microsoft.dotnet.Sdk new console -n tiny -o . 2>&1 &&
        z run com.microsoft.dotnet.Sdk run 2>&1) || { echo "$out" | tail -3; return 1; }
    grep -q '^Hello, World!' <<<"$out" || { echo "$out" | tail -3; return 1; }
}
check "the SDK run as an app makes, builds and runs a project in the working directory" sdk_builds_cwd
nuget_in_data() {
    z run com.microsoft.dotnet.Sdk nuget locals global-packages --list | tr -d '\r' |
        grep -qF "global-packages: $ZIGSAW_HOME\\data\\com.microsoft.dotnet.Sdk\\dotnet\\.nuget\\packages"
}
check "NuGet keeps its packages in the SDK's data directory" nuget_in_data
# A program built with the SDK image, its NuGet package from nuget.org through
# a vendor step, that runs on the runtime image: its apphost finds .NET through
# the DOTNET_ROOT the runtime's variables set, not a .NET installed on the
# machine.
DOTNETAPP=test.build.dotnet
mkdir -p "$work\\dotnet" && cp "$(cygpath -u "$root")"/tests/build/dotnet/{hello.csproj,Program.cs} "$(cygpath -u "$work")/dotnet/" &&
    sed -e "s/@DOTNETSDK@/$(manifest_of com.microsoft.dotnet.Sdk)/" -e "s/@DOTNET@/$(manifest_of com.microsoft.dotnet)/" -e "s/@BUSYBOX@/$bb_digest/" \
        "$root\\tests\\build\\dotnet\\hello.json.in" >"$work\\dotnet\\hello.json"
check "a .NET program builds with the SDK image, its NuGet package vendored" z build "$work\\dotnet\\hello.json"
dotnet_app_digest=$(manifest_of $DOTNETAPP)
dotnet_runs() {
    local sb out
    for sb in soft low appcontainer; do
        out=$(z run --sandbox=$sb $DOTNETAPP zigsaw | tr -d '\r')
        [ "$out" = "hello, zigsaw, from .NET $dotnet_version
Built with a vendored package
runs on $ZIGSAW_HOME\\deploy\\$(own_layer com.microsoft.dotnet)\\shared\\Microsoft.NETCore.App\\$dotnet_version\\" ] ||
            { echo "$sb, got: $out"; return 1; }
    done
}
check "it runs on the runtime image, under soft, low and appcontainer" dotnet_runs
dotnet_again() { [ "$(rebuilt_manifest "$work\\dotnet\\hello.json")" = "$dotnet_app_digest" ]; }
check "built again, from the vendored packages in the cache, it's the same image" dotnet_again
# Windows Forms and WPF, which the runtime's Windows Desktop framework has: a
# form and a window that close themselves once they're up.
DESKTOP=test.build.dotnetdesktop
mkdir -p "$work\\dotnetdesktop" && cp "$(cygpath -u "$root")"/tests/build/dotnetdesktop/{desktop.csproj,Program.cs} "$(cygpath -u "$work")/dotnetdesktop/" &&
    sed -e "s/@DOTNETSDK@/$(manifest_of com.microsoft.dotnet.Sdk)/" -e "s/@DOTNET@/$(manifest_of com.microsoft.dotnet)/" -e "s/@BUSYBOX@/$bb_digest/" \
        "$root\\tests\\build\\dotnetdesktop\\desktop.json.in" >"$work\\dotnetdesktop\\desktop.json"
check "a Windows Forms and WPF program builds" z build "$work\\dotnetdesktop\\desktop.json"
desktop_digest=$(manifest_of $DESKTOP)
desktop_runs() {
    local sb out
    for sb in soft low appcontainer; do
        out=$(z run --sandbox=$sb $DESKTOP | tr -d '\r')
        [ "$out" = "Windows Forms: a form came up
WPF: a window came up and drew its content" ] || { echo "$sb, got: $out"; return 1; }
    done
}
check "its form and its window come up, under soft, low and appcontainer" desktop_runs
desktop_again() { [ "$(rebuilt_manifest "$work\\dotnetdesktop\\desktop.json")" = "$desktop_digest" ]; }
check "built again, it's the same image" desktop_again
fi

# --- Java from source ---------------------------------------------------------------

if section java; then
# Eclipse Temurin's builds of OpenJDK: the JDK as the SDK image, its JRE as the
# runtime image Java apps run on. Java takes its user.home from
# SHGetKnownFolderPath, which a run's USERPROFILE doesn't move, so both images
# set it in JAVA_TOOL_OPTIONS, and every JVM says so on stderr.
check "java-sdk.json builds the JDK image" z build "$root\\recipes\\java-sdk.json"
check "java.json builds the JRE image" z build "$root\\recipes\\java.json"
jre_dir() { echo "$ZIGSAW_HOME\\deploy\\$(own_layer org.openjdk.java)"; }
jre_files() {
    [ -e "$(jre_dir)\\bin\\java.exe" ] && [ -e "$(jre_dir)\\bin\\javaw.exe" ] || { echo "no java.exe or javaw.exe"; return 1; }
    [ ! -e "$(jre_dir)\\bin\\javac.exe" ] || { echo "has javac.exe"; return 1; }
}
check "the JRE has java and javaw, not the JDK's javac" jre_files
mkdir -p "$work\\javatiny"
printf 'public class Tiny { public static void main(String[] a) { System.out.println("home " + System.getProperty("user.home")); } }\n' >"$work\\javatiny\\Tiny.java"
jdk_runs_cwd() {
    local sb out
    for sb in soft low appcontainer; do
        out=$(cd "$work\\javatiny" && z run --sandbox=$sb org.openjdk.java.Sdk Tiny.java 2>/dev/null | tr -d '\r')
        [ "$out" = "home $ZIGSAW_HOME\\data\\org.openjdk.java.Sdk\\home" ] || { echo "$sb, got: $out"; return 1; }
    done
}
check "the JDK run as an app runs a program in the working directory, its user.home in its data, under soft, low and appcontainer" jdk_runs_cwd
# java_fixture <dir> <files...>: copies tests/build/<dir>'s files to the work
# directory, and its recipe with the images' digests.
java_fixture() {
    local dir=$1 f
    shift
    mkdir -p "$work\\$dir" || return 1
    for f in "$@"; do cp "$(cygpath -u "$root")/tests/build/$dir/$f" "$(cygpath -u "$work")/$dir/" || return 1; done
    for f in "$(cygpath -u "$root")/tests/build/$dir"/*.json.in; do
        sed -e "s/@JAVASDK@/$(manifest_of org.openjdk.java.Sdk)/" -e "s/@JAVA@/$(manifest_of org.openjdk.java)/" \
            -e "s/@MAVEN@/$(manifest_of org.apache.maven 2>/dev/null)/" -e "s/@GRADLE@/$(manifest_of org.gradle.gradle 2>/dev/null)/" \
            -e "s/@BUSYBOX@/$bb_digest/" "$f" >"$(cygpath -u "$work")/$dir/$(basename "$f" .in)"
    done
}
# A Swing program that lays out its text, as diagrams and documents do: in an
# AppContainer, JDK 25's HarfBuzz through its foreign function interface
# can't find the C runtime (it resolves System32 with toRealPath, which needs
# the drive root listed), so the images turn it off (sun.font.layout.ffm).
SWING=test.build.swing
java_fixture swing Swing.java
check "a Swing program builds with the JDK image's javac and jar" z build "$work\\swing\\swing.json"
swing_digest=$(manifest_of $SWING)
swing_runs() {
    local sb out
    for sb in soft low appcontainer; do
        out=$(z run --sandbox=$sb $SWING 2>/dev/null | tr -d '\r')
        [ "$out" = "Swing: a window came up and drew its text" ] || { echo "$sb, got: $out"; return 1; }
    done
}
check "it runs on the JRE image, and its window draws its text, under soft, low and appcontainer" swing_runs
swing_again() { [ "$(rebuilt_manifest "$work\\swing\\swing.json")" = "$swing_digest" ]; }
check "built again, it's the same image" swing_again
# java_app_runs <id> <how it says it was built>: the fixture's program, from a
# vendored package, on the JRE, with its home in its data, in each sandbox.
java_app_runs() {
    local id=$1 built=$2 sb out
    for sb in soft low appcontainer; do
        out=$(z run --sandbox=$sb $id zigsaw 2>/dev/null | tr -d '\r')
        [ "$(sed -E 's/from Java [0-9][^,]*/from Java (version)/' <<<"$out")" = "hello, zigsaw, from Java (version)$built
Built with a vendored package
runs on $(jre_dir)
home is $ZIGSAW_HOME\\data\\$id\\home" ] || { echo "$sb, got: $out"; return 1; }
    done
}
# Maven, on the JDK: its vendor step is the build itself, with the local
# repository in the module's directory, less the files that record when and
# from where (maven-metadata, _remote.repositories, *.lastUpdated) and the
# prefix lists Maven fetches from each repository into .meta, which change
# upstream; then the build runs offline from it.
check "maven.json builds Maven's image, on the JDK's" z build "$root\\recipes\\maven.json"
check "  mvn runs" sh -c "'$zigsaw' run org.apache.maven -v 2>/dev/null | grep -q '^Apache Maven 3'"
MAVENAPP=test.build.maven
java_fixture maven pom.xml Hello.java
check "a Maven project builds, its dependencies and plugins vendored and the build offline" z build "$work\\maven\\hello.json"
maven_digest=$(manifest_of $MAVENAPP)
check "it runs on the JRE image, under soft, low and appcontainer" java_app_runs $MAVENAPP ""
maven_again() { [ "$(rebuilt_manifest "$work\\maven\\hello.json")" = "$maven_digest" ]; }
check "built again, from the vendored repository in the cache, it's the same image" maven_again
# Gradle, on the JDK: its vendor step builds with a Gradle home of its own,
# and gradle-vendor makes the files Gradle downloaded a Maven repository; the
# build points every repository there (ZIGSAW_GRADLE_REPO, read by the init
# script in Gradle's image), offline. The project has a settings plugin from
# Gradle's plugin portal.
check "gradle.json builds Gradle's image, on the JDK's" z build "$root\\recipes\\gradle.json"
check "  gradle runs" sh -c "'$zigsaw' run org.gradle.gradle --version 2>/dev/null | grep -q '^Gradle 9'"
GRADLEAPP=test.build.gradle
java_fixture gradle settings.gradle build.gradle Hello.java
check "a Gradle project builds, its plugin and dependencies vendored and the build offline" z build "$work\\gradle\\hello.json"
gradle_digest=$(manifest_of $GRADLEAPP)
check "it runs on the JRE image, under soft, low and appcontainer" java_app_runs $GRADLEAPP ", built by Gradle"
gradle_again() { [ "$(rebuilt_manifest "$work\\gradle\\hello.json")" = "$gradle_digest" ]; }
check "built again, from the vendored repository in the cache, it's the same image" gradle_again
fi

# --- PHP extensions with zig ------------------------------------------------------

if section php; then
# PHP's official Windows build, which MSVC builds, in an SDK image with its
# headers and php-ext, which runs an extension's config.w32 under Node and
# builds it with zig; the runtime is the SDK image's files without those.
# The test extension's image is a runtime of an app, next to PHP's, which
# loads it through the .ini in the extension's image (tests/php.sh has
# APCu's and Xdebug's test suites).
check "php-sdk.json builds PHP's SDK image" z build "$root\\recipes\\php-sdk.json"
check "php.json builds PHP's runtime image from it" z build "$root\\recipes\\php.json"
PHPEXT=test.build.phpext PHPAPP=test.build.php
mkdir -p "$work\\php" && cp -r "$(cygpath -u "$root")"/tests/build/php/{zprobe,test.php} "$(cygpath -u "$work")/php/" &&
    sed -e "s/@PHPSDK@/$(manifest_of net.php.php.Sdk)/" "$root\\tests\\build\\php\\zprobe.json.in" >"$work\\php\\zprobe.json"
check "a PHP extension builds with the SDK image's php-ext, from its config.w32" z build "$work\\php\\zprobe.json"
phpext_digest=$(manifest_of $PHPEXT)
sed -e "s/@PHP@/$(manifest_of net.php.php)/" -e "s/@PHPEXT@/$phpext_digest/" "$root\\tests\\build\\php\\app.json.in" >"$work\\php\\app.json"
check "an app with PHP's runtime and the extension's image as runtimes builds" z build "$work\\php\\app.json"
# test.php prints a line per check; the last one is a fatal error, which
# Zend's bailout unwinds through the extension's zend_try.
mkdir -p "$work\\phpcwd"
php_ext_runs() {
    local sb out
    for sb in soft low appcontainer; do
        out=$(cd "$work\\phpcwd" && z run --sandbox=$sb $PHPAPP 2>&1 | tr -d '\r')
        ! grep -q '^FAIL' <<<"$out" && [ "$(grep -c '^ok ' <<<"$out")" -eq 27 ] && grep -q '^shutdown ok$' <<<"$out" ||
            { echo "$sb: $(grep -E '^FAIL|rror' <<<"$out" | head -2 | tr '\n' ' ')"; return 1; }
    done
}
check "PHP loads it, and its 27 checks pass, under soft, low and appcontainer" php_ext_runs
phpext_again() { [ "$(rebuilt_manifest "$work\\php\\zprobe.json")" = "$phpext_digest" ]; }
check "built again, the extension's image is the same" phpext_again
# Installed, it extends PHP's runtime: PHP loads it without listing it.
zprobe_joins() {
    local php='echo extension_loaded("zprobe") ? zprobe_libs() : "not loaded", "\n";' out
    # (What zigsaw notes, as a first low run's label, goes to stderr.)
    out=$(cd "$work\\phpcwd" && z run net.php.php -r "$php" 2>"$work\\stderr" | tr -d '\r')
    [ "$out" = "zlib 1.3.2 crc 3610a686, from libxml2, OpenSSL 3.5.8" ] || { echo "installed: $out $(tr '\r\n' '  ' <"$work\\stderr")"; return 1; }
    out=$(cd "$work\\phpcwd" && z run --noextension=$PHPEXT net.php.php -r "$php" 2>"$work\\stderr" | tr -d '\r')
    [ "$out" = "not loaded" ] || { echo "left out: $out $(tr '\r\n' '  ' <"$work\\stderr")"; return 1; }
}
check "installed, PHP's runs load it through PHP's extension point, unless left out" zprobe_joins
# Without a recipe: the SDK's php-ext in the extension's directory, and PHP's
# runtime loading the DLL from there.
mkdir -p "$work\\phpdir" && cp -r "$(cygpath -u "$root")"/tests/build/php/zprobe/. "$(cygpath -u "$work")/phpdir/"
php_ext_no_recipe() {
    local out
    out=$(cd "$work\\phpdir" && z run --command=php-ext net.php.php.Sdk build 2>&1) || { echo "$out" | tail -2; return 1; }
    # (The SDK runs under soft: PHP's run labels the directory, and says so.)
    out=$(cd "$work\\phpdir" && z run --noextension=$PHPEXT net.php.php -d "extension=$work\\phpdir\\php_zprobe.dll" -r 'echo zprobe_config(), "\n";' 2>"$work\\stderr" | tr -d '\r')
    [ "$out" = "hello from config.w32, version info: yes" ] || { echo "got: $out $(tr '\r\n' '  ' <"$work\\stderr")"; return 1; }
}
check "php-ext builds it in its directory without a recipe, and PHP's runtime loads it" php_ext_no_recipe
fi

# Removing the apps also deletes their AppContainer profiles. The images
# builds use stay until prune --downloads, and only zigsaw can delete their
# protected deployments. Every installed app has refs\<id>.json.
for id in $(ls "$ZIGSAW_HOME\\refs" | sed 's/\.json$//'); do z rm --delete-data "$id" >/dev/null 2>&1; done
check "every app is removed" sh -c "[ -z \"\$(ls '$ZIGSAW_HOME\\refs')\" ]"
z prune --downloads --data >/dev/null 2>&1
check "prune --downloads deletes tools' caches" sh -c "[ -z \"\$(ls '$ZIGSAW_HOME\\cache\\tools')\" ]"
cd / && rm -rf "$ZIGSAW_HOME" "$work"
check "no run labelled or granted the repository" sh -c "! icacls '$root' | grep -q -e 'Mandatory Label' -e 'S-1-15-'"

echo
echo "$failures check(s) failed${GROUP:+ in group $GROUP}."
exit $((failures > 0))
