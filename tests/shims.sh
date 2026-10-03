#!/usr/bin/env bash
# End-to-end checks for command shims: installing an app puts its exports in
# <store>\bin, the shims behave like the real commands, and the store keeps
# them in sync as apps are rebuilt and removed.
#
#   tests/shims.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and network access (for the Node download, unless the store
# in %ZIGSAW_HOME% or SEED_DOWNLOADS has it). Uses a temporary store unless
# ZIGSAW_HOME is set, and removes the test apps afterwards either way.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
own_store=false
if [ -z "${ZIGSAW_HOME:-}" ]; then
    ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
    own_store=true
fi
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
# SEED_DOWNLOADS: another store's cache\downloads, whose files are linked, or
# copied, into this one's, so as not to download them again.
if [ -n "${SEED_DOWNLOADS:-}" ]; then
    mkdir -p "$ZIGSAW_HOME\\cache\\downloads"
    cp -l "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/" 2>/dev/null ||
        cp -n "$(cygpath -u "$SEED_DOWNLOADS")"/* "$(cygpath -u "$ZIGSAW_HOME")/cache/downloads/"
fi
bin="$ZIGSAW_HOME\\bin"

NODE=org.nodejs.node
OTHER=test.shims.other

failures=0
check() {
    local label=$1
    shift
    local out
    if out=$("$@" 2>&1); then
        printf 'ok    %s\n' "$label"
    else
        printf 'FAIL  %s\n      %s\n' "$label" "$(tail -1 <<<"$out" | cut -c1-110)"
        failures=$((failures + 1))
    fi
}

# Runs a command line through cmd with <store>\bin first on PATH, so the
# shims get exactly the command line written here, with no bash quoting.
via_cmd() {
    printf '@set "PATH=%s;%%PATH%%"\r\n@%s\r\n' "$bin" "$1" >"$work\\t.cmd"
    cmd /c "$work\\t.cmd"
}

"$zigsaw" build "$root/recipes/node.json" >/dev/null 2>&1 || { echo "building node failed"; exit 1; }

check "node, npm and npx shims exist" \
    test -f "$bin\\node.exe" -a -f "$bin\\npm.exe" -a -f "$bin\\npx.exe" -a -f "$bin\\node.shim"
args_exact() {
    local want out
    want='["x y","q\"q","","a\\b","C:\\dir with space\\"]'
    out=$(via_cmd 'node -e "console.log(JSON.stringify(process.argv.slice(1)))" -- "x y" "q\"q" "" a\b "C:\dir with space\\"' | tr -d '\r')
    [ "$out" = "$want" ] || { echo "got $out"; return 1; }
}
exit_code() { via_cmd 'node -e process.exit(7)'; [ $? -eq 7 ]; }
stdio() { [ "$(echo piped | via_cmd 'node -e process.stdin.pipe(process.stdout)' | tr -d '\r')" = piped ]; }
other_home() { ZIGSAW_HOME='C:\nonexistent' via_cmd 'node -e 0'; }
check "arguments arrive exactly as typed" args_exact
check "exit code passes through" exit_code
check "stdin and stdout pass through" stdio
check "npm runs npm-cli.js through node" via_cmd "npm --version"
check "npx runs" via_cmd "npx --version"
check "caller's ZIGSAW_HOME doesn't matter" other_home

# A second app that also exports "node" (plus "other-tool").
sed -e "s/\"net.frippery.busybox\"/\"$OTHER\"/" \
    -e 's/"command": "busybox.exe",/"command": "busybox.exe", "exports": { "node": { "command": "busybox.exe" }, "other-tool": { "command": "busybox.exe" } },/' \
    "$root/recipes/busybox.json" >"$work\\other.json"
check "a taken name is skipped with a warning" sh -c "\"\$0\" build '$work\\other.json' 2>&1 | grep -q 'not exporting node: $NODE already provides it'" "$zigsaw"
check "the taken name keeps its owner" grep -q "app = $NODE" "$bin\\node.shim"
check "the free name is exported" test -f "$bin\\other-tool.exe"

# Commands an app installs while it runs: npm install -g puts <name>.cmd in
# node's global prefix, ${data}\npm, which is on its PATH, and the run gives
# it a shim. The packages are local tarballs, so npm needs no network.
# npm_package <command>: packs a package whose command prints its
# arguments, and prints the tarball's path.
npm_package() {
    local dir="$work\\pkg-$1"
    mkdir -p "$dir"
    printf '{ "name": "%s", "version": "1.0.0", "bin": { "%s": "cli.js" } }\n' "$1" "$1" >"$dir\\package.json"
    printf '#!/usr/bin/env node\nconsole.log(JSON.stringify(process.argv.slice(2)))\n' >"$dir\\cli.js"
    via_cmd "cd /d \"$dir\" && npm pack --silent" >/dev/null 2>&1
    printf '%s\n' "$dir\\$1-1.0.0.tgz"
}
npm_g() { via_cmd "npm $1 -g --offline --no-audit --no-fund $2" 2>&1; }
hello_tgz=$(npm_package zigsaw-hello)
bye_tgz=$(npm_package zigsaw-bye)
taken_tgz=$(npm_package other-tool)
eph_tgz=$(npm_package zigsaw-eph)
installed_by_run() {
    local out
    out=$(npm_g install "\"$hello_tgz\" \"$bye_tgz\"")
    grep -q "added zigsaw-bye, zigsaw-hello to .* (installed by $NODE)" <<<"$out" || { echo "$out"; return 1; }
    [ -f "$bin\\zigsaw-hello.exe" ] && grep -q 'command = zigsaw-hello' "$bin\\zigsaw-hello.shim"
}
check "npm install -g gives the package's command a shim" installed_by_run
installed_args() {
    local out
    out=$(via_cmd 'zigsaw-hello "x y" a\b ""' | tr -d '\r')
    [ "$out" = '["x y","a\\b",""]' ] || { echo "got $out"; return 1; }
}
check "it runs, with its arguments as typed" installed_args
check "list shows it" sh -c "\"\$0\" list | grep '^$NODE ' | grep -q 'zigsaw-hello'" "$zigsaw"
ephemeral_install() {
    "$zigsaw" run --ephemeral --command=npm $NODE install -g --offline --no-audit --no-fund "$eph_tgz" >/dev/null 2>&1 &&
        [ ! -e "$bin\\zigsaw-eph.exe" ]
}
check "an --ephemeral run's command gets none" ephemeral_install
taken_by_other() { npm_g install "\"$taken_tgz\"" >/dev/null && grep -q "app = $OTHER" "$bin\\other-tool.shim"; }
check "a command another app exports keeps its owner" taken_by_other
uninstalled() {
    local out
    out=$(npm_g uninstall zigsaw-bye)
    grep -q "removed zigsaw-bye from .* (gone from $NODE)" <<<"$out" || { echo "$out"; return 1; }
    [ ! -e "$bin\\zigsaw-bye.exe" ] && [ -e "$bin\\zigsaw-hello.exe" ]
}
check "npm uninstall -g removes its shim" uninstalled

sed -e '/"npx":/d' -e 's/npm-cli.js"\] },/npm-cli.js"] }/' "$root/recipes/node.json" >"$work\\node-no-npx.json"
rebuilt() {
    local out
    out=$("$zigsaw" build "$work\\node-no-npx.json" 2>&1)
    [ ! -e "$bin\\npx.exe" ] && [ -e "$bin\\npm.exe" ] || { echo "npx.exe or npm.exe is wrong"; return 1; }
    [ -e "$bin\\zigsaw-hello.exe" ] && grep -q '  commands zigsaw-hello (installed by its runs)' <<<"$out"
}
check "rebuilding drops removed exports, and keeps commands its runs installed" rebuilt
check "list shows exports" sh -c "\"\$0\" list | grep '^$NODE ' | grep -q 'node, npm'" "$zigsaw"
check "rm removes the app's shims only" sh -c "\"\$0\" rm $NODE >/dev/null 2>&1 && [ ! -e '$bin\\node.exe' ] && [ ! -e '$bin\\zigsaw-hello.exe' ] && [ -e '$bin\\other-tool.exe' ]" "$zigsaw"

# Overrides reach shims: other-tool is busybox, which the appcontainer
# sandbox keeps from writing outside its own directories.
mkdir -p "$work\\outside"
fails() { ! "$@"; }
writes_outside() { via_cmd "other-tool sh -c \"echo x > '$work\\outside\\f'\""; }
check "a shim writes anywhere by default (soft sandbox)" writes_outside
"$zigsaw" override --sandbox=appcontainer "$OTHER" >/dev/null 2>&1
check "an appcontainer override keeps the shim from writing there" fails writes_outside
rebuild_keeps() { "$zigsaw" build "$work\\other.json" >/dev/null 2>&1 && ! writes_outside; }
check "the override survives a rebuild" rebuild_keeps
"$zigsaw" override --reset "$OTHER" >/dev/null 2>&1
check "after --reset, the shim writes there again" writes_outside

"$zigsaw" rm "$NODE" >/dev/null 2>&1
"$zigsaw" rm "$OTHER" >/dev/null 2>&1
# The global packages, in case the store isn't ours.
for pkg in zigsaw-hello other-tool; do
    rm -rf "$ZIGSAW_HOME\\data\\$NODE\\npm\\node_modules\\$pkg"
    for ext in "" .cmd .ps1; do rm -f "$ZIGSAW_HOME\\data\\$NODE\\npm\\$pkg$ext"; done
done
$own_store && rm -rf "$ZIGSAW_HOME"
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
