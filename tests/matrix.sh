#!/usr/bin/env bash
# Compatibility matrix: runs real tools through both sandboxes and reports
# where behaviour differs from what zigsaw intends.
#
#   tests/matrix.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and network access. Uses the store in %ZIGSAW_HOME% if set;
# otherwise creates a temporary store and removes it (and the AppContainer
# profiles it created) afterwards. Missing apps are built from recipes/.
#
# Each check states the intended outcome per sandbox: "ok" (exits 0) or
# "fails" (exits non-zero). The soft sandbox doesn't enforce permissions, so
# its intended outcome for a denied action is "ok".

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
GIT=org.git_scm.MinGit
NODE=org.nodejs.node
PY=org.python.python
ZIG=org.ziglang.zig

# --- Setup -------------------------------------------------------------------

installed=$("$zigsaw" list)
for recipe in busybox ripgrep mingit node python zig; do
    id=$(grep -o '"id": *"[^"]*"' "$root/recipes/$recipe.json" | cut -d'"' -f4)
    if ! grep -q "^$id " <<<"$installed"; then
        echo "building $id..."
        out=$("$zigsaw" build "$root/recipes/$recipe.json" 2>&1) || { echo "$out"; exit 1; }
    fi
done

outside="$work\\outside"
mkdir -p "$outside" && echo secret >"$outside\\secret.txt"

# --- Harness -----------------------------------------------------------------

rows=()
mismatches=0

# Runs an installed app in the current sandbox ($sb).
run() { "$zigsaw" run --sandbox="$sb" "$@"; }

# The most telling line of a failed command's output: the first that looks
# like an error, else the last non-empty one.
first_error() {
    local out
    out=$(grep -v '^\s*$')
    { grep -m1 -iE 'error|fatal|denied|EPERM|EACCES' <<<"$out" || tail -1 <<<"$out"; } | sed 's/^\s*//' | cut -c1-110
}

# Starts a tool's checks. Each sandbox gets a fresh working directory.
tool() {
    current_tool=$1
    for sb in soft appcontainer; do mkdir -p "$work\\$current_tool\\$sb"; done
}

# expect <soft> <appcontainer> <label> <command...>
expect() {
    local want_soft=$1 want_ac=$2 label=$3
    shift 3
    local cells=() notes=()
    for sb in soft appcontainer; do
        local want=$want_soft
        [ "$sb" = appcontainer ] && want=$want_ac
        local out code got
        out=$(cd "$work\\$current_tool\\$sb" && "$@" 2>&1)
        code=$?
        got=ok
        [ $code -ne 0 ] && got=fails
        if [ "$got" = "$want" ]; then
            cells+=("$got")
        else
            cells+=("$got  <-- want $want")
            notes+=("$sb: $(first_error <<<"$out")")
            mismatches=$((mismatches + 1))
        fi
    done
    rows+=("$(printf '%-8s %-38s %-22s %s' "$current_tool" "$label" "${cells[0]}" "${cells[1]}")")
    for n in "${notes[@]}"; do rows+=("$(printf '%-8s   %s' '' "$n")"); done
}

# --- Checks ------------------------------------------------------------------

tool busybox
expect ok ok "runs" run $BB echo hello
exit_code_passes() { run $BB sh -c 'exit 3'; [ $? -eq 3 ]; }
expect ok ok "exit code passes through" exit_code_passes
expect ok ok "writes land in data dir" run $BB sh -c 'echo x > "$APPDATA/f" && [ -s "$APPDATA/f" ]'
expect fails fails "app files are read-only" run $BB sh -c 'echo x > "${PATH%%;*}/x"'
expect ok fails "write to ungranted host dir" run $BB sh -c "echo x > '$outside\\written.txt'"
children_end() { run $BB sh -c 'sleep 60 &' && sleep 1 && ! tasklist | grep -qi '^busybox.exe'; }
expect ok ok "job ends background children" children_end

tool ripgrep
echo 'needle' >"$work\\ripgrep\\soft\\a.txt"
echo 'needle' >"$work\\ripgrep\\appcontainer\\a.txt"
expect ok ok "runs" run $RG --version
expect ok ok "searches granted cwd" run $RG -q needle
expect ok fails "read ungranted host file" run $RG -q secret "$outside\\secret.txt"

tool git
expect ok ok "runs" run $GIT --version
git_global_config() {
    run $GIT config --global user.email t@example.com &&
        run $GIT config --global --show-origin user.email | grep -q "data"
}
expect ok ok "global config in data dir" git_global_config
git_commit() {
    echo hi >a.txt && run $GIT init -q && run $GIT add a.txt && run $GIT -c user.name=T commit -qm first
}
expect ok ok "init and commit in cwd" git_commit
expect ok ok "ls-remote over https" run $GIT ls-remote https://github.com/ziglang/zig.git HEAD

tool node
echo 'console.log("hi")' >"$work\\node\\soft\\a.js"
echo 'console.log("hi")' >"$work\\node\\appcontainer\\a.js"
expect ok ok "runs -e" run $NODE -e 'console.log(1)'
expect ok ok "runs a script file" run $NODE a.js
expect ok ok "fs.realpathSync" run $NODE -e 'require("fs").realpathSync(".")'
expect ok ok "fetch over https" run $NODE -e 'fetch("https://example.com").then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))'
expect ok ok "npm install" run --command=npm $NODE install --no-audit --no-fund is-number
# The recipe points npm's global prefix at ${data}\npm and puts it on PATH.
npm_global() {
    run --command=npm $NODE install -g --no-audit --no-fund semver@7 &&
        run --command=npm $NODE ls -g | grep -q semver &&
        [ -f "$ZIGSAW_HOME\\data\\$NODE\\npm\\node_modules\\semver\\package.json" ]
}
expect ok ok "npm install -g into data dir" npm_global
global_bin() { [ "$(run --command=cmd $NODE /c semver 1.2.3 | tr -d '\r')" = 1.2.3 ]; }
expect ok ok "global package's command on PATH" global_bin

tool python
echo 'print("hi")' >"$work\\python\\soft\\a.py"
echo 'print("hi")' >"$work\\python\\appcontainer\\a.py"
expect ok ok "runs a script file" run $PY a.py
expect ok ok "realpath resolves cwd" run $PY -c 'import os, sys; sys.exit(os.path.realpath(".") != os.getcwd())'
expect ok ok "https with system certs" run $PY -c 'import urllib.request as u; u.urlopen("https://example.com", timeout=20)'
expect ok fails "network denied by --unshare" run --unshare=network $PY -c 'import urllib.request as u; u.urlopen("https://example.com", timeout=10)'
expect fails fails "can't write into app dir" run $PY -c 'import os, sys; open(os.path.join(sys.prefix, "x.txt"), "w")'

tool zig
expect ok ok "runs" run $ZIG version
expect ok ok "zig env" run $ZIG env
zig_project() { run $ZIG init >/dev/null && run $ZIG build run; }
expect ok ok "init, build and run a project" zig_project

# --- Report ------------------------------------------------------------------

echo
printf '%-8s %-38s %-22s %s\n' TOOL CHECK SOFT APPCONTAINER
printf '%s\n' "${rows[@]}"
echo
echo "$mismatches result(s) differ from the intended behaviour."

if $own_store; then
    for id in $BB $RG $GIT $NODE $PY $ZIG; do "$zigsaw" rm --delete-data "$id" >/dev/null 2>&1; done
    rm -rf "$ZIGSAW_HOME"
fi
rm -rf "$work"
exit $((mismatches > 0))
