#!/usr/bin/env bash
# Compatibility matrix: runs real tools through the three sandboxes and
# reports where behaviour differs from what zigsaw intends.
#
#   tests/matrix.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and network access. Uses the store in %ZIGSAW_HOME% if set;
# otherwise creates a temporary store and removes it (and the AppContainer
# profiles it created) afterwards. Missing apps are built from recipes/.
#
# Each check states the intended outcome per sandbox: "ok" (exits 0) or
# "fails" (exits non-zero). The soft sandbox doesn't enforce permissions, so
# its intended outcome for a denied action is "ok"; the low sandbox enforces
# only where the app may write. "gap" means "ok" is intended, but zigsaw
# doesn't manage it yet (see the README's Known gaps and docs/findings.md): a
# failure is reported, but isn't a mismatch, so the matrix fails only for
# results that changed.
#
# Each check runs in soft, then appcontainer, then low: an AppContainer run
# changes the ACLs of the app's deployments and data, which low-integrity
# runs must still be able to read.
#
# Most known gaps are AppContainer failures caused by what Windows denies
# AppContainers, which differs between Windows versions. The probe
# (tests/acprobe.zig, built with `zig build acprobe`) checks those causes
# from inside an AppContainer first, and checks whose causes it finds lifted
# are expected to pass, so a regression fails the matrix.
#
# Each run of an app is stopped after MATRIX_TIMEOUT seconds (default 120),
# and counts as failed, so a hung tool can't stall the matrix. The report
# shows how long slow checks took. The zig check compiles a project, which
# takes minutes the first time after zig's image changes, while the app's
# cache in its data directory is cold.

set -u
export MSYS_NO_PATHCONV=1 # Keep arguments like "/c" from being rewritten into paths.

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}

own_store=false
if [ -z "${ZIGSAW_HOME:-}" ]; then
    ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
    own_store=true
fi
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")

BB=net.frippery.busybox
RG=com.github.BurntSushi.ripgrep
BAT=com.github.sharkdp.bat
GIT=org.git_scm.MinGit
NODE=org.nodejs.node
PY=org.python.python
ZIG=org.ziglang.zig
GO=org.golang.go
FZF=com.github.junegunn.fzf
ZOT=dev.zotregistry.zot
CMAKE=org.cmake.cmake
ZSTD=com.github.facebook.zstd

# --- Setup -------------------------------------------------------------------

installed=$("$zigsaw" list)
# zig and rust before ripgrep and bat, go before fzf and zot, and zig and cmake
# before zstd, which build with them.
for recipe in busybox zig rust ripgrep bat go fzf zot cmake zstd mingit node python; do
    id=$(grep -o '"id": *"[^"]*"' "$root/recipes/$recipe.json" | cut -d'"' -f4)
    if ! grep -q "^$id " <<<"$installed"; then
        echo "building $id..."
        out=$("$zigsaw" build "$root/recipes/$recipe.json" 2>&1) || { echo "$out"; exit 1; }
    fi
done

outside="$work\\outside"
mkdir -p "$outside" && echo secret >"$outside\\secret.txt"

# What this Windows denies AppContainers: the probe, as an app of its own,
# run in one, from a granted directory.
PROBE=test.matrix.acprobe
(cd "$root" && zig build acprobe) || { echo "building the AppContainer probe failed"; exit 1; }
mkdir -p "$work\\acprobe\\cwd" && cp "$root\\zig-out\\test\\zigsaw-acprobe.exe" "$work\\acprobe\\"
printf '{ "id": "%s", "version": "1", "command": "zigsaw-acprobe.exe", "exports": {}, "permissions": { "filesystem": ["cwd"] },\n  "modules": [{ "name": "probe", "sources": [{ "path": "zigsaw-acprobe.exe" }] }] }\n' \
    $PROBE >"$work\\acprobe\\acprobe.json"
out=$("$zigsaw" build "$work\\acprobe\\acprobe.json" 2>&1) || { echo "$out"; exit 1; }
probe=$(cd "$work\\acprobe\\cwd" && "$zigsaw" run --sandbox=appcontainer $PROBE 2>/dev/null | tr -d '\r')
grep -q '^nul ' <<<"$probe" || { echo "the AppContainer probe didn't run: $probe"; exit 1; }

# ac_if <check...>: the intended outcome under AppContainer of a known gap
# whose causes are those probe checks: "ok" where they all passed, else "gap".
ac_if() {
    local check
    for check in "$@"; do
        grep -qx "$check ok" <<<"$probe" || { echo gap; return; }
    done
    echo ok
}

# --- Harness -----------------------------------------------------------------

rows=()
mismatches=0
gaps=0

limit=${MATRIX_TIMEOUT:-120}
started=$SECONDS

# Runs an installed app in the current sandbox ($sb), for at most $limit
# seconds. Ending zigsaw ends the app's whole process tree (its job object).
# Its stdin is empty, whatever the matrix's is: given a pipe, as in CI,
# ripgrep would search that instead of its working directory.
run() {
    run_input "$@" </dev/null
}

# Like run, but the app reads the caller's stdin.
run_input() {
    timeout "$limit" "$zigsaw" run --sandbox="$sb" "$@"
    local code=$?
    [ $code -eq 124 ] && echo "error: timed out after ${limit}s"
    return $code
}

# The most telling line of a failed command's output: the first that looks
# like an error, else the last non-empty one.
first_error() {
    local out
    out=$(grep -v '^\s*$')
    { grep -m1 -iE 'error|fatal|denied|EPERM|EACCES' <<<"$out" || tail -1 <<<"$out"; } | sed 's/^\s*//' | cut -c1-110
}

sandboxes="soft appcontainer low"

# Starts a tool's checks. Each sandbox gets a fresh working directory.
tool() {
    current_tool=$1
    for sb in $sandboxes; do mkdir -p "$work\\$current_tool\\$sb"; done
}

# in_each <file> <content>: writes a file into each sandbox's working
# directory for the current tool.
in_each() {
    for sb in $sandboxes; do printf '%s\n' "$2" >"$work\\$current_tool\\$sb\\$1"; done
}

# expect <soft> <appcontainer> <low> <label> <command...>
expect() {
    local want_soft=$1 want_ac=$2 want_low=$3 label=$4
    shift 4
    local cells=() notes=() start=$SECONDS
    for sb in $sandboxes; do
        local want=$want_soft
        [ "$sb" = appcontainer ] && want=$want_ac
        [ "$sb" = low ] && want=$want_low
        local out code got
        out=$(cd "$work\\$current_tool\\$sb" && "$@" 2>&1)
        code=$?
        got=ok
        [ $code -ne 0 ] && got=fails
        if [ "$got" = "$want" ]; then
            cells+=("$got")
        elif [ "$want" = gap ] && [ "$got" = ok ]; then
            cells+=("ok  (a known gap)")
        elif [ "$want" = gap ]; then
            cells+=("fails  (known gap)")
            notes+=("$sb: $(first_error <<<"$out")")
            gaps=$((gaps + 1))
        else
            cells+=("$got  <-- want $want")
            notes+=("$sb: $(first_error <<<"$out")")
            mismatches=$((mismatches + 1))
        fi
    done
    local took=$((SECONDS - start)) time=""
    [ $took -ge 5 ] && time="  (${took}s)"
    rows+=("$(printf '%-8s %-38s %-20s %-20s %s%s' "$current_tool" "$label" "${cells[0]}" "${cells[1]}" "${cells[2]}" "$time")")
    for n in "${notes[@]}"; do rows+=("$(printf '%-8s   %s' '' "$n")"); done
}

# --- Checks ------------------------------------------------------------------

tool busybox
expect ok ok ok "runs" run $BB echo hello
exit_code_passes() { run $BB sh -c 'exit 3'; [ $? -eq 3 ]; }
expect ok ok ok "exit code passes through" exit_code_passes
expect ok ok ok "writes land in data dir" run $BB sh -c 'echo x > "$APPDATA/f" && [ -s "$APPDATA/f" ]'
expect fails fails fails "app files are read-only" run $BB sh -c 'echo x > "${PATH%%;*}/x"'
expect ok fails fails "write to ungranted host dir" run $BB sh -c "echo x > '$outside\\written.txt'"
children_end() { run $BB sh -c 'sleep 60 &' && sleep 1 && ! tasklist | grep -qi '^busybox.exe'; }
expect ok ok ok "job ends background children" children_end

tool ripgrep
in_each a.txt needle
expect ok ok ok "runs" run $RG --version
expect ok ok ok "searches granted cwd" run $RG -q needle
expect ok fails ok "read ungranted host file" run $RG -q secret "$outside\\secret.txt"

tool bat
in_each a.rs 'fn main() {}'
expect ok ok ok "runs" run $BAT --version
# Highlighted: a colour code before the keyword.
bat_highlights() { run $BAT --color=always --style=plain a.rs | grep -q $'\e\\[[0-9;]*mfn'; }
expect ok ok ok "highlights a file in granted cwd" bat_highlights
expect ok fails ok "read ungranted host file" run $BAT --style=plain "$outside\\secret.txt"

# Under AppContainer, git needs its own real path, and NUL. Repository
# discovery would stat the working directory's parent, which the container
# can't read, but the recipe's GIT_DISCOVERY_ACROSS_FILESYSTEM skips that.
# Creating files, git stats each directory of their path, the drive root too.
tool git
expect ok "$(ac_if self-path-dos nul)" ok "runs" run $GIT --version
git_global_config() {
    run $GIT config --global user.email t@example.com &&
        run $GIT config --global --show-origin user.email | grep -q "data"
}
expect ok "$(ac_if self-path-dos nul)" ok "global config in data dir" git_global_config
git_commit() {
    echo hi >a.txt && run $GIT init -q && run $GIT add a.txt && run $GIT -c user.name=T commit -qm first
}
expect ok "$(ac_if self-path-dos nul drive-root)" ok "init and commit in cwd" git_commit
expect ok "$(ac_if self-path-dos nul)" ok "ls-remote over https" run $GIT ls-remote https://github.com/ziglang/zig.git HEAD

tool node
in_each a.js 'console.log("hi")'
# Node's JavaScript realpath lstat()s each directory of a path, the drive
# root too, which AppContainers can't; the recipe's NODE_OPTIONS keeps Node
# from resolving the paths of scripts and modules that way. Its native
# realpath needs drive letters, and child processes whose output is
# ignored, as npm starts them, get NUL.
expect ok ok ok "runs -e" run $NODE -e 'console.log(1)'
expect ok "$(ac_if final-path-dos self-path-dos nul)" ok "runs a script file" run $NODE a.js
expect ok "$(ac_if final-path-dos drive-root nul)" ok "fs.realpathSync" run $NODE -e 'require("fs").realpathSync(".")'
expect ok ok ok "fetch over https" run $NODE -e 'fetch("https://example.com").then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))'
expect ok "$(ac_if final-path-dos self-path-dos nul)" ok "npm install" run --command=npm $NODE install --no-audit --no-fund is-number
# The recipe points npm's global prefix at ${data}\npm and puts it on PATH.
npm_global() {
    run --command=npm $NODE install -g --no-audit --no-fund semver@7 &&
        run --command=npm $NODE ls -g | grep -q semver &&
        [ -f "$ZIGSAW_HOME\\data\\$NODE\\npm\\node_modules\\semver\\package.json" ]
}
# npm itself lstat()s each directory of the data directory's path.
expect ok gap ok "npm install -g into data dir" npm_global
# Its command is semver.cmd, a batch file in ${data}\npm.
global_bin() { [ "$(run --command=semver $NODE 1.2.3 | tr -d '\r')" = 1.2.3 ]; }
expect ok "$(ac_if final-path-dos self-path-dos nul)" ok "global package's .cmd command" global_bin

tool python
in_each a.py 'print("hi")'
expect ok ok ok "runs a script file" run $PY a.py
expect ok "$(ac_if final-path-dos)" ok "realpath resolves cwd" run $PY -c 'import os, sys; sys.exit(os.path.realpath(".") != os.getcwd())'
expect ok ok ok "https with system certs" run $PY -c 'import urllib.request as u; u.urlopen("https://example.com", timeout=20)'
expect ok fails ok "network denied by --unshare" run --unshare=network $PY -c 'import urllib.request as u; u.urlopen("https://example.com", timeout=10)'
expect fails fails fails "can't write into app dir" run $PY -c 'import os, sys; open(os.path.join(sys.prefix, "x.txt"), "w")'

# zig finds its library by its own real path.
tool zig
expect ok ok ok "runs" run $ZIG version
expect ok "$(ac_if self-path-dos)" ok "zig env" run $ZIG env
zig_project() { run $ZIG init >/dev/null && run $ZIG build run; }
expect ok "$(ac_if self-path-dos final-path-dos nul)" ok "init, build and run a project" zig_project

tool go
for sb in $sandboxes; do
    printf 'module zigsaw.test/hi\n\ngo 1.27\n' >"$work\\go\\$sb\\go.mod"
    printf 'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println("hi from go") }\n' >"$work\\go\\$sb\\main.go"
done
expect ok ok ok "runs" run $GO version
go_run() { run $GO run . | grep -q 'hi from go'; }
# Go's toolchain opens NUL, which Windows Server 2025 denies AppContainers
# (docs/findings.md).
expect ok "$(ac_if nul final-path-dos)" ok "builds and runs a module in granted cwd" go_run

tool fzf
expect ok ok ok "runs" run $FZF --version
fzf_filters() { [ "$(printf 'apple\nbanana\ncherry\n' | run_input $FZF --filter=an | tr -d '\r')" = banana ]; }
expect ok ok ok "filters lines from stdin" fzf_filters

tool zot
for sb in $sandboxes; do
    printf '{ "distSpecVersion": "1.1.1", "storage": { "rootDirectory": "data" },\n  "http": { "address": "127.0.0.1", "port": "5099" }, "log": { "level": "warn" } }\n' >"$work\\zot\\$sb\\zot.json"
done
expect ok ok ok "runs" run $ZOT --version
expect ok ok ok "verifies a config in granted cwd" run $ZOT verify zot.json

# CMake finds its modules by its own real path. Whether it opens NUL isn't
# known.
tool cmake
expect ok "$(ac_if self-path-dos nul)" ok "runs" run $CMAKE --version
cmake_hashes() { echo hello >a.txt && run $CMAKE -E sha256sum a.txt | grep -q '^5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03 '; }
expect ok "$(ac_if self-path-dos nul)" ok "hashes a file in granted cwd" cmake_hashes

tool zstd
expect ok ok ok "runs" run $ZSTD --version
zstd_round_trip() {
    seq 1 1000 >a.txt && run $ZSTD -q -f a.txt -o a.zst && run --command=unzstd $ZSTD -q -f a.zst -o b.txt && cmp -s a.txt b.txt
}
expect ok ok ok "compresses and restores in granted cwd" zstd_round_trip
# (What it writes to stdout is compressed, binary.)
zstd_reads_outside() { run $ZSTD -q -c "$outside\\secret.txt" >/dev/null; }
expect ok fails ok "read ungranted host file" zstd_reads_outside

# --- Report ------------------------------------------------------------------

echo
echo "In an AppContainer on $(cmd /c ver | tr -d '\r' | grep -v '^$') (tests/acprobe.zig):"
grep -v '^#' <<<"$probe" | sed 's/^/  /'
echo
printf '%-8s %-38s %-20s %-20s %s\n' TOOL CHECK SOFT APPCONTAINER LOW
printf '%s\n' "${rows[@]}"
echo
echo "$mismatches result(s) differ from the intended behaviour, and $gaps known gap(s) failed. The checks took $((SECONDS - started))s."

"$zigsaw" rm --delete-data $PROBE >/dev/null 2>&1
if $own_store; then
    for id in $BB $RG $BAT $GIT $NODE $PY $ZIG $GO $FZF $ZOT $CMAKE $ZSTD; do "$zigsaw" rm --delete-data "$id" >/dev/null 2>&1; done
    rm -rf "$ZIGSAW_HOME"
fi
rm -rf "$work"
exit $((mismatches > 0))
