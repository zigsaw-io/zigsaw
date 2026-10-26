#!/usr/bin/env bash
# Networking end to end (docs/networking.md), with tests/netprobe.zig as the
# app, in a store of its own: a run with the network gets the proxy
# variables zigsaw has, one without doesn't; eight first runs of an app in an
# AppContainer start at once, and all of them make it. The app declares a
# service, which a client on the host reaches under soft, low and
# appcontainer, on the port the app's config says, on one --port or an
# override moves it to, and not after the run ends; in an AppContainer, the
# app listens on an internal port that all its runs agree on, and its runs
# reach each other there without the network; a port another program holds
# leaves the service unpublished, and the app running. Last, the probe's
# report: what this Windows lets AppContainers do on the loopback.
#
#   bash tests/network.sh [path\to\zigsaw.exe]
#
# With LOG_DIR set, the report is also left there.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
work=$(cygpath -w "$(mktemp -d)")
ZIGSAW_HOME="$work\\store"
export ZIGSAW_HOME
APP=test.netprobe
RACE=test.netprobe.race

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
z() { timeout 120 "$zigsaw" "$@"; }

(cd "$root" && zig build netprobe) || { echo "building the network probe failed"; exit 1; }
probe_dir="$work\\netprobe"
mkdir -p "$probe_dir" && cp "$root\\zig-out\\test\\zigsaw-netprobe.exe" "$probe_dir\\"
# The report runs the probe in AppContainers of its own.
icacls "$probe_dir" /grant '*S-1-15-2-1:(OI)(CI)RX' >/dev/null || { echo "granting the probe to AppContainers failed"; exit 1; }
probe="$probe_dir\\zigsaw-netprobe.exe"

# The ports the service is on: the app's config's, and two others.
declared=$((47000 + RANDOM % 600))
moved=$((declared + 700))
saved=$((declared + 800))

# recipe <id> <command args> <more>: the probe as an app.
recipe() {
    printf '{ "id": "%s", "version": "1", "command": "zigsaw-netprobe.exe", "args": [%s],%s\n  "modules": [{ "name": "probe", "sources": [{ "path": "zigsaw-netprobe.exe" }] }] }\n' \
        "$1" "$2" "$3" >"$probe_dir\\$1.json"
    z build "$probe_dir\\$1.json" >/dev/null 2>&1 || { z build "$probe_dir\\$1.json"; exit 1; }
}
recipe $APP '"serve", "${listen:echo}"' '
  "env": { "ECHO_LISTEN": "${listen:echo}", "ECHO_PORT": "${port:echo}" },
  "permissions": { "services": [{ "name": "echo", "port": '$declared', "command": "netprobe-serve" }] },
  "exports": {
    "netprobe-serve": { "command": "zigsaw-netprobe.exe", "args": ["serve", "${listen:echo}"] },
    "netprobe-ping": { "command": "zigsaw-netprobe.exe", "args": ["ping", "${listen:echo}"] },
    "netprobe-env": { "command": "zigsaw-netprobe.exe", "args": ["env"] }
  },'
recipe $RACE '"env", "ZIGSAW_ID"' ' "exports": {},'

# --- Proxies -----------------------------------------------------------------

proxied() {
    local out
    out=$(HTTP_PROXY=http://proxy.invalid:3128 https_proxy=http://proxy.invalid:3129 NO_PROXY=localhost \
        z run "$@" --command=netprobe-env $APP HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY | tr -d '\r')
    echo "$out"
}
with_proxies() {
    local out
    out=$(proxied "$@")
    grep -qx 'HTTP_PROXY=http://proxy.invalid:3128' <<<"$out" && grep -qx 'HTTPS_PROXY=http://proxy.invalid:3129' <<<"$out" &&
        grep -qx 'NO_PROXY=localhost' <<<"$out" && ! grep -q '^ALL_PROXY' <<<"$out" || { echo "got: $out"; return 1; }
}
without_proxies() {
    local out
    out=$(proxied "$@")
    [ -z "$out" ] || { echo "got: $out"; return 1; }
}
check "a run with the network gets your proxy variables" with_proxies --share=network
check "a run without it doesn't" without_proxies --unshare=network
check "an AppContainer run with the network gets them too" with_proxies --share=network --sandbox=appcontainer

# --- AppContainer profiles ---------------------------------------------------

# Eight first runs at once: each would create the app's profile.
race() {
    local i pids=() failed=0
    for i in 1 2 3 4 5 6 7 8; do
        z run --sandbox=appcontainer $RACE >"$work\\race.$i.out" 2>&1 &
        pids+=($!)
    done
    for i in "${!pids[@]}"; do
        wait "${pids[$i]}" || { failed=$((failed + 1)); tail -1 "$work\\race.$((i + 1)).out"; }
    done
    [ $failed = 0 ]
}
check "eight first runs in an AppContainer start at once" race

# --- Services ----------------------------------------------------------------

# answers <port>: whether a client on the host gets the probe's pong there.
answers() { "$probe" ping $1 >/dev/null 2>&1; }

# serve <run options...>: a run of the app's command, which serves, in the
# background; $server is its zigsaw.
serve() {
    "$zigsaw" run "$@" $APP >"$work\\serve.out" 2>&1 &
    server=$!
}
stop() {
    kill $server 2>/dev/null
    wait $server 2>/dev/null
}

# served <port> <run options...>: a run serves the app's service on <port>
# to a client on the host, and the port is free once the run ends.
served() {
    local port=$1 i ok=1
    shift
    serve "$@"
    for i in $(seq 60); do
        answers $port && { ok=0; break; }
        sleep 0.25
    done
    stop
    [ $ok = 0 ] || { echo "no answer on $port: $(tail -1 "$work\\serve.out")"; return 1; }
    for i in $(seq 20); do
        answers $port || return 0
        sleep 0.25
    done
    echo "port $port still answers after the run ended"
    return 1
}

# ports <run options...>: what the app's runs see as ${listen:echo} and
# ${port:echo}, as "<listen> <port>".
ports() {
    local out
    out=$(z run "$@" --command=netprobe-env $APP ECHO_LISTEN ECHO_PORT | tr -d '\r')
    echo "$(sed -n 's/^ECHO_LISTEN=//p' <<<"$out") $(sed -n 's/^ECHO_PORT=//p' <<<"$out")"
}
same_ports() {
    local got
    got=$(ports "$@")
    [ "$got" = "$declared $declared" ] || { echo "got $got"; return 1; }
}
internal_port() {
    local got listen port again
    got=$(ports --sandbox=appcontainer)
    read -r listen port <<<"$got"
    [ "$port" = $declared ] && [ "$listen" != $declared ] && [ "$listen" -ge 20000 ] && [ "$listen" -le 48999 ] ||
        { echo "got $got"; return 1; }
    again=$(ports --sandbox=appcontainer)
    [ "$again" = "$got" ] || { echo "first $got, then $again"; return 1; }
    grep -qx "echo $listen" "$ZIGSAW_HOME\\ports\\$APP.txt" || { echo "not kept: $(cat "$ZIGSAW_HOME\\ports\\$APP.txt")"; return 1; }
}

for sandbox in soft low appcontainer; do
    check "$sandbox: a host client reaches the app's service on its port" served $declared --sandbox=$sandbox
done
check "soft and low: the app listens on that port itself" same_ports --sandbox=low
check "appcontainer: it listens on an internal port, the same in every run" internal_port
check "--port moves the service" served $moved --sandbox=appcontainer --port=echo=$moved
moved_ports() {
    local got
    got=$(ports --port=echo=$moved)
    [ "$got" = "$moved $moved" ] || { echo "got $got"; return 1; }
}
check "and its placeholders" moved_ports
z override --port=echo=$saved $APP >/dev/null 2>&1
check "and so does an override" served $saved --sandbox=appcontainer
z override --reset $APP >/dev/null 2>&1
unknown_service() {
    local out
    out=$(z run --port=db=5432 $APP 2>&1) && return 1
    grep -q 'has no service "db"; it has echo' <<<"$out" || { echo "$out"; return 1; }
}
check "--port for a service the app doesn't have fails" unknown_service

# In one container, a client run reaches the server run on its internal
# port, with no network permission (the app has none).
private_loopback() {
    local out i
    serve --sandbox=appcontainer
    for i in $(seq 40); do
        out=$(z run --sandbox=appcontainer --command=netprobe-ping $APP 2>&1 | tr -d '\r') && break
        sleep 0.25
    done
    stop
    [ "$out" = connects ] || { echo "$out"; return 1; }
}
check "appcontainer: the app's runs reach each other, without the network" private_loopback

# Another program holds the port: the run says so, and the app runs on.
taken() {
    local holder out i
    "$probe" serve $declared >/dev/null 2>&1 &
    holder=$!
    sleep 0.5
    serve --sandbox=appcontainer
    for i in $(seq 40); do
        out=$(z run --sandbox=appcontainer --command=netprobe-ping $APP 2>&1 | tr -d '\r') && break
        sleep 0.25
    done
    stop
    kill $holder 2>/dev/null
    wait $holder 2>/dev/null
    grep -q "port $declared is taken, so echo isn't published this run" "$work\\serve.out" || { echo "$(cat "$work\\serve.out")"; return 1; }
    [ "$out" = connects ] || { echo "the app didn't run on: $out"; return 1; }
}
check "appcontainer: a port another program holds leaves the service unpublished" taken

# --- What this Windows does --------------------------------------------------

report=$("$probe" report 2>&1 | tr -d '\r')
echo "On $(cmd /c ver | tr -d '\r' | grep -v '^$') (tests/netprobe.zig):"
sed 's/^/  /' <<<"$report"
if [ -n "${LOG_DIR:-}" ]; then echo "$report" >"$LOG_DIR\\netprobe.txt"; fi

z rm --delete-data $APP >/dev/null 2>&1
z rm --delete-data $RACE >/dev/null 2>&1
rm -rf "$work"
echo "$failures check(s) failed."
[ $failures = 0 ]
