#!/usr/bin/env bash
# ZLS, the Zig language server (recipes/zls.json, built from source with
# zig's image, its packages fetched in a vendor step), end to end: its
# version, then a language server session over stdio in each sandbox, held
# open as an editor holds one. It finds zig and zig's library in the zig
# image it runs with, so hover shows the standard library's documentation;
# it runs a project's build.zig with that zig to learn the modules the
# project declares; it reports a syntax error; and it exits when told to.
# Last, its shim, which editors start.
#
#   ZLS_HOME=path\to\store bash tests/zls.sh [path\to\zigsaw.exe]
#
# The store (ZLS_HOME, or BUILD_HOME as tests/published.sh leaves it, or a
# temporary one) gets ZLS unless it has it (built in about 2 minutes, with
# zig's image), and loses it afterwards if it didn't.
set -u
export MSYS_NO_PATHCONV=1
# Byte counts, for Content-Length.
export LC_ALL=C

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
temp_store=""
ZIGSAW_HOME=${ZLS_HOME:-${BUILD_HOME:-}}
if [ -z "$ZIGSAW_HOME" ]; then
    ZIGSAW_HOME=$(cygpath -w "$(mktemp -d)")
    temp_store=$ZIGSAW_HOME
fi
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
ZLS=org.zigtools.zls

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

z() { "$zigsaw" "$@"; }
installed_here=""
if [ ! -f "$ZIGSAW_HOME\\refs\\$ZLS.json" ]; then
    installed_here=$ZLS
    z build "$root\\recipes\\zls.json" >"$work\\build.log" 2>&1 || echo "building zls.json failed: $(tail -1 "$work\\build.log")"
fi
# Runs from the work directory's sandbox folders, never the repository: ZLS
# has the cwd permission, which low runs label and AppContainer runs grant.
cd "$work" || exit 1

check "zls --version says 0.16.1" sh -c "[ \"\$(\"\$0\" run $ZLS --version | tr -d '\r')\" = 0.16.1 ]" "$zigsaw"
caches_in_data() {
    local dir
    dir=$(z run $ZLS env | tr -d '\r' | grep '"global_cache_dir"' | sed -e 's/.*: "//' -e 's/",*$//' -e 's/\\\\/\\/g')
    [[ $dir == "$ZIGSAW_HOME\\data\\$ZLS\\"* ]] || { echo "global_cache_dir is $dir"; return 1; }
}
check "its caches and log are in its data" caches_in_data

# --- A session in each sandbox --------------------------------------------------

# The server is this script's coprocess SERVER: its stdin is $to_server, its
# stdout $from_server. A check runs in a subshell, which reads its replies
# from the same pipe.
send() { printf 'Content-Length: %d\r\n\r\n%s' "${#1}" "$1" >&"$to_server"; }
# next_message: puts the server's next message in $message; fails after a
# minute without one.
next_message() {
    local line length=0
    while IFS= read -r -t 60 line <&"$from_server"; do
        line=${line%$'\r'}
        [ -n "$line" ] || break
        case $line in Content-Length:*) length=${line#*: } ;; esac
    done
    [ "$length" -gt 0 ] && IFS= read -r -N "$length" -t 60 message <&"$from_server"
}
# reply <id>: puts the reply to request <id> in $message, skipping the
# server's notifications.
reply() {
    while next_message; do [[ $message == *"\"id\":$1,"* ]] && return 0; done
    echo "no reply to request $1"
    return 1
}
# A project, tests/zls, whose main.zig uses the standard library and a module
# its build.zig declares; bad.zig doesn't parse. main.zig as JSON:
main_text='const std = @import(\"std\");\nconst greet = @import(\"greet\");\npub fn main() void {\n    std.debug.print(\"hi\\n\", .{});\n    greet.hello();\n}\n'
hover() { send '{"jsonrpc":"2.0","id":'"$1"',"method":"textDocument/hover","params":{"textDocument":{"uri":"'"$uri"'/main.zig"},"position":{"line":'"$2"',"character":'"$3"'}}}'; }
std_hover() {
    local message
    hover 2 3 16 && reply 2 || return 1
    [[ $message == *'fn print(comptime fmt: []const u8, args: anytype) void'* ]] || { echo "got: ${message:0:110}"; return 1; }
}
# ZLS runs build.zig in the background after the file opens, so this asks
# again each second, for a minute.
module_hover() {
    local message id
    for id in $(seq 10 69); do
        hover $id 4 11 && reply $id || return 1
        [[ $message == *'Says hello, from a module build.zig declares.'* ]] && return 0
        sleep 1
    done
    echo "no module after a minute: ${message:0:110}"
    return 1
}
syntax_error() {
    local message
    send '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$uri"'/bad.zig","languageId":"zig","version":1,"text":"const x = ;\n"}}}'
    while next_message; do
        [[ $message == *publishDiagnostics*bad.zig* ]] || continue
        [[ $message == *'expected expression'* ]] && return 0
        echo "got: ${message:0:110}"
        return 1
    done
    echo "no diagnostics for bad.zig"
    return 1
}
for sb in soft low appcontainer; do
    dir="$work\\$sb"
    mkdir -p "$dir" && cp "$(cygpath -u "$root")"/tests/zls/*.zig "$(cygpath -u "$dir")/"
    uri="file:///$(cygpath -m "$dir")"
    coproc SERVER { cd "$dir" && exec "$zigsaw" run --sandbox=$sb $ZLS 2>"$work\\$sb.stderr.txt"; }
    # (Bash forgets SERVER once the server exits.)
    to_server=${SERVER[1]} from_server=${SERVER[0]} pid=$SERVER_PID
    send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":"'"$uri"'","capabilities":{"textDocument":{"publishDiagnostics":{}}}}}'
    check "under $sb: it starts, and answers initialize" reply 1
    send '{"jsonrpc":"2.0","method":"initialized","params":{}}'
    send '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$uri"'/main.zig","languageId":"zig","version":1,"text":"'"$main_text"'"}}}'
    check "  hover shows the standard library's documentation, from the zig image" std_hover
    check "  it learns the module build.zig declares, running it with that zig" module_hover
    check "  it reports a syntax error" syntax_error
    send '{"jsonrpc":"2.0","id":99,"method":"shutdown","params":null}'
    reply 99 >/dev/null
    send '{"jsonrpc":"2.0","method":"exit","params":null}'
    exec {to_server}>&- {from_server}<&-
    wait "$pid"
    check "  told to, it exits, with 0" test $? -eq 0
done

check "its shim runs it, as an editor would" sh -c "[ \"\$(\"$ZIGSAW_HOME\\\\bin\\\\zls.exe\" --version | tr -d '\r')\" = 0.16.1 ]"
check "no run labelled or granted the repository" sh -c "! icacls '$root' | grep -q -e 'Mandatory Label' -e 'S-1-15-'"

cd "$root" || exit 1
for id in $installed_here; do z rm --delete-data "$id" >/dev/null 2>&1; done
if [ -n "$temp_store" ]; then
    z prune --downloads --data >/dev/null 2>&1
    rm -rf "$temp_store"
fi
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
