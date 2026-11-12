#!/usr/bin/env bash
# Allow lists end to end (docs/networking.md, src/hosts.zig, src/proxy.zig),
# with tests/netprobe.zig as the app, in a store of its own. The app's recipe
# lists one host; servers of the probe's on 127.0.0.1 stand in for hosts. In
# an AppContainer, the run holds no network capability and reaches its hosts
# only through the relay, which is an HTTP proxy that zigsaw decides for: a
# host on the list answers, one that isn't gets 403 and a note when the run
# ends, a name that resolves to this machine is refused, and a direct
# connection doesn't get out. --allow-host, --noallow-host, overrides and
# --global change the list; --unshare=network narrows an app with the network
# to a list, --share=network widens a list to all of it. A request for an
# http:// URL goes on with its path only. The ports the app uses are still
# forwarded beside its proxy. Under low and soft the proxy is there, and a
# note says it isn't enforced. With your proxy set, zigsaw tunnels through it
# with Basic authentication, unless NO_PROXY names the host. Last, one host on
# the internet (example.com, over http), tried twice.
#
#   bash tests/hosts.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and zig (for the probe). Takes about half a minute.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
work=$(cygpath -w "$(mktemp -d)")
ZIGSAW_HOME="$work\\store"
export ZIGSAW_HOME
suite_key="Software\\ZigsawTest\\hosts-$$-grants"
export ZIGSAW_GRANTS_KEY="$suite_key"
mkdir -p "$work\\folders\\Documents"
export ZIGSAW_USER_FOLDERS="$work\\folders"
# Your proxy, if you have one, is the suite's to set.
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy
APP=test.hosts

failures=0
check() {
    local label=$1
    shift
    local out
    if out=$("$@" 2>&1); then
        printf 'ok    %s\n' "$label"
    else
        printf 'FAIL  %s\n      %s\n' "$label" "$(grep -v '^\s*$' <<<"$out" | tail -2 | tr '\n' ' ' | cut -c1-160)"
        failures=$((failures + 1))
    fi
}
z() { timeout 120 "$zigsaw" "$@"; }

(cd "$(cygpath -u "$root")" && zig build netprobe) || { echo "building the network probe failed"; exit 1; }
probe_dir="$work\\netprobe"
mkdir -p "$probe_dir" && cp "$root\\zig-out\\test\\zigsaw-netprobe.exe" "$probe_dir\\"
# The servers run a copy of their own, which builds don't hold.
servers_dir="$work\\servers"
mkdir -p "$servers_dir" && cp "$root\\zig-out\\test\\zigsaw-netprobe.exe" "$servers_dir\\"
server="$servers_dir\\zigsaw-netprobe.exe"

# The app's host, one it doesn't list, an HTTP server, a port it uses, and a
# proxy of "yours".
listed=$((45000 + RANDOM % 900))
other=$((listed + 1000))
web=$((listed + 2000))
proxy_port=$((listed + 3000))

recipe() {
    printf '{ "id": "%s", "version": "1", "command": "zigsaw-netprobe.exe", "args": ["env", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"],%s\n  "modules": [{ "name": "probe", "sources": [{ "path": "zigsaw-netprobe.exe" }] }] }\n' \
        "$1" "$2" >"$probe_dir\\$1.json"
}
recipe $APP '
  "permissions": {
    "hosts": ["127.0.0.1:'$listed'"],
    "uses": [{ "name": "upstream", "port": '$other' }]
  },
  "exports": {
    "netprobe-upstream": { "command": "zigsaw-netprobe.exe", "args": ["ping", "${uses:upstream}"] }
  },'
z build "$probe_dir\\$APP.json" >/dev/null 2>&1 || { z build "$probe_dir\\$APP.json"; exit 1; }

pids=()
start() {
    "$server" "$@" >/dev/null 2>&1 &
    pids+=($!)
}
start serve $listed
start serve $other
start serve-http $web
start fake-proxy $proxy_port 'alice:s3cr:t' "$work\\proxy.log"
sleep 1

# fetch <run options...> -- <probe args...>: the probe's line.
fetch() {
    local opts=()
    while [ "$1" != -- ]; do opts+=("$1"); shift; done
    shift
    z run "${opts[@]}" --command=zigsaw-netprobe.exe $APP "$@" 2>&1 | tr -d '\r'
}
# expect <pattern> <run options...> -- <probe args...>
expect() {
    local pattern=$1 out
    shift
    out=$(fetch "$@")
    grep -qE "$pattern" <<<"$out" || { echo "got: $out"; return 1; }
}
AC=--sandbox=appcontainer

# --- In an AppContainer ------------------------------------------------------

check "its host answers through the proxy" expect '^pong$' $AC -- fetch 127.0.0.1 $listed
refused_note() {
    local out
    out=$(fetch $AC -- fetch 127.0.0.1 $other)
    grep -q "^403 zigsaw: this app's allow list doesn't let it reach 127.0.0.1:$other" <<<"$out" &&
        grep -q "^zigsaw: $APP was refused 127.0.0.1:$other: its allow list doesn't name it" <<<"$out" || { echo "got: $out"; return 1; }
}
check "a host it doesn't list gets 403, and the run says so when it ends" refused_note
check "it holds no network capability: a connection of its own doesn't get out" \
    expect '^error ' $AC --env=HTTPS_PROXY= -- fetch 127.0.0.1 $listed
check "a name of this machine's is refused, even listed" \
    expect "was refused localhost, as its name is this machine's" $AC --allow-host=localhost:$listed -- fetch localhost $listed
check "a request for a URL goes on with its path only, and closes" \
    expect '^200 GET /a/b\?c=d HTTP/1.1\|close$' $AC --allow-host=127.0.0.1:$web -- fetch-http 127.0.0.1 $web '/a/b?c=d'
uses() {
    local out
    out=$(z run $AC --command=netprobe-upstream $APP 2>&1 | tr -d '\r')
    [ "$out" = connects ] || { echo "got: $out"; return 1; }
}
check "the ports it uses are forwarded beside its proxy" uses

# --- Changing the list -------------------------------------------------------

check "--allow-host adds a host" expect '^pong$' $AC --allow-host=127.0.0.1:$other -- fetch 127.0.0.1 $other
check "--noallow-host takes the app's away" \
    expect '^403 ' $AC --allow-host=127.0.0.1:$other --noallow-host=127.0.0.1:$listed -- fetch 127.0.0.1 $listed
# With none left, the run has no network, and no proxy.
check "a list with none left is no network" expect '^error ' $AC --noallow-host=127.0.0.1:$listed -- fetch 127.0.0.1 $listed
overrides() {
    local ok=0
    z override --allow-host=127.0.0.1:$other $APP >/dev/null || return 1
    expect '^pong$' $AC -- fetch 127.0.0.1 $other || ok=1
    # The command line takes it away again.
    expect '^403 ' $AC --noallow-host=127.0.0.1:$other -- fetch 127.0.0.1 $other || ok=1
    z override --reset $APP >/dev/null
    z override --global --noallow-host=127.0.0.1:$listed >/dev/null || return 1
    expect '^403 ' $AC --allow-host=127.0.0.1:$other -- fetch 127.0.0.1 $listed || ok=1
    z override --global --reset >/dev/null
    return $ok
}
check "an override saves it, --global too, under the command line" overrides
narrows() {
    expect '^pong$' $AC --unshare=network --allow-host=127.0.0.1:$other -- fetch 127.0.0.1 $other || return 1
    expect '^403 ' $AC --unshare=network --allow-host=127.0.0.1:$other -- fetch 127.0.0.1 $listed || return 1
    # Without --allow-host, no network: no proxy either.
    [ -z "$(z run $AC --unshare=network $APP 2>&1 | tr -d '\r')" ] || { echo "a proxy without a list"; return 1; }
}
check "--unshare=network --allow-host narrows it to those hosts" narrows
widens() {
    local out
    out=$(z run $AC --share=network $APP 2>&1 | tr -d '\r')
    [ -z "$out" ] || { echo "proxy variables with the network: $out"; return 1; }
    # Exempt from loopback isolation, it reaches any server here itself.
    expect '^pong$' $AC --share=network -- fetch 127.0.0.1 $other
}
check "--share=network widens it to all of the network" widens

# --- Low and soft ------------------------------------------------------------

for sb in low soft; do
    check "under $sb: the proxy, and a note that it isn't enforced" \
        expect "allow list isn't enforced under the $sb sandbox" --sandbox=$sb -- fetch 127.0.0.1 $listed
    check "under $sb: a host it doesn't list gets 403 from the proxy" expect '^403 ' --sandbox=$sb -- fetch 127.0.0.1 $other
done

# --- Your proxy --------------------------------------------------------------

proxied() {
    rm -f "$work\\proxy.log"
    HTTPS_PROXY="http://alice:s3cr%3At@127.0.0.1:$proxy_port" expect '^pong$' $AC -- fetch 127.0.0.1 $listed || return 1
    grep -qx "127.0.0.1:$listed" "$work\\proxy.log" 2>/dev/null || { echo "your proxy wasn't asked"; return 1; }
    # A plain request goes through it too, as a tunnel.
    HTTPS_PROXY="http://alice:s3cr%3At@127.0.0.1:$proxy_port" expect '^200 GET /x HTTP' $AC --allow-host=127.0.0.1:$web -- fetch-http 127.0.0.1 $web /x || return 1
    grep -qx "127.0.0.1:$web" "$work\\proxy.log" || { echo "your proxy wasn't asked for the URL"; return 1; }
}
check "with your proxy set, zigsaw tunnels through it, with Basic authentication" proxied
bypassed() {
    rm -f "$work\\proxy.log"
    HTTPS_PROXY="http://alice:s3cr%3At@127.0.0.1:$proxy_port" NO_PROXY=127.0.0.1 expect '^pong$' $AC -- fetch 127.0.0.1 $listed || return 1
    [ ! -s "$work\\proxy.log" ] || { echo "your proxy was asked"; return 1; }
}
check "NO_PROXY has zigsaw connect directly" bypassed
wrong_password() {
    HTTPS_PROXY="http://alice:wrong@127.0.0.1:$proxy_port" expect '^502 ' $AC -- fetch 127.0.0.1 $listed
}
check "a password your proxy refuses: 502" wrong_password

# --- Recipes -----------------------------------------------------------------

both() {
    recipe test.hosts.both '
  "permissions": { "network": true, "hosts": ["example.com"] },'
    local out
    out=$(z build "$probe_dir\\test.hosts.both.json" 2>&1) && { echo "built"; return 1; }
    grep -q "hosts lists what an app without the network may reach" <<<"$out" || { echo "got: $out"; return 1; }
}
check "a recipe with the network and a list is refused" both

# --- The internet ------------------------------------------------------------

internet() {
    expect '^200 ' $AC --allow-host=example.com -- fetch-http example.com 80 / ||
        { sleep 2; expect '^200 ' $AC --allow-host=example.com -- fetch-http example.com 80 /; }
}
check "a host on the internet, by name" internet

for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
wait 2>/dev/null
z rm --delete-data $APP >/dev/null 2>&1
reg delete "HKCU\\$suite_key" /f >/dev/null 2>&1
rm -rf "$work"
echo "$failures check(s) failed."
[ $failures = 0 ]
