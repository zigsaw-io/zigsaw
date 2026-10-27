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
# leaves the service unpublished, and the app running. In an AppContainer, a
# run with the network reaches a server on this machine, as its container is
# exempt from loopback isolation while it goes; without the network, or with
# ZIGSAW_LOOPBACK_EXEMPTION=0, it doesn't; `repair` takes back a killed
# run's exemption, and one you made stays. Last, the probe's report: what
# this Windows lets AppContainers do on the loopback, and over AF_UNIX.
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

# The ports the service is on: the app's config's, and two others. Then
# the port of a server on this machine, outside zigsaw, which the app uses,
# and another.
declared=$((47000 + RANDOM % 600))
moved=$((declared + 700))
saved=$((declared + 800))
host_port=$((declared + 900))
host_port2=$((declared + 1000))

# recipe <id> <command args> <more>: the probe as an app.
recipe() {
    printf '{ "id": "%s", "version": "1", "command": "zigsaw-netprobe.exe", "args": [%s],%s\n  "modules": [{ "name": "probe", "sources": [{ "path": "zigsaw-netprobe.exe" }] }] }\n' \
        "$1" "$2" "$3" >"$probe_dir\\$1.json"
    z build "$probe_dir\\$1.json" >/dev/null 2>&1 || { z build "$probe_dir\\$1.json"; exit 1; }
}
recipe $APP '"serve", "${listen:echo}"' '
  "env": { "ECHO_LISTEN": "${listen:echo}", "ECHO_PORT": "${port:echo}", "UPSTREAM_PORT": "${uses:upstream}" },
  "permissions": {
    "services": [{ "name": "echo", "port": '$declared', "command": "netprobe-serve" }],
    "uses": [{ "name": "upstream", "port": '$host_port' }]
  },
  "exports": {
    "netprobe-serve": { "command": "zigsaw-netprobe.exe", "args": ["serve", "${listen:echo}"] },
    "netprobe-ping": { "command": "zigsaw-netprobe.exe", "args": ["ping", "${listen:echo}"] },
    "netprobe-upstream": { "command": "zigsaw-netprobe.exe", "args": ["ping", "${uses:upstream}"] },
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
    grep -q 'has no service "db" or used port of that name; it has echo and upstream' <<<"$out" || { echo "$out"; return 1; }
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

# --- Reaching this machine ---------------------------------------------------

# A server on this machine, outside zigsaw.
"$probe" serve $host_port >"$work\\host.out" 2>&1 &
host_server=$!
sleep 0.5

# exempt: whether Windows lists the app's container as exempt from loopback
# isolation.
exempt() { CheckNetIsolation.exe LoopbackExempt -s | tr -d '\r' | grep -qx "    Name: zigsaw.$APP"; }
# pings <expected> <run options...>: a run of the app pings the server, and
# the probe says <expected>.
pings() {
    local expected=$1 out
    shift
    out=$(z run "$@" --command=zigsaw-netprobe.exe $APP ping $host_port 2>&1 | tr -d '\r')
    [ "$out" = "$expected" ] || { echo "got $out"; return 1; }
}
# waiting <run options...>: a run of the app that waits 3 s, in the
# background; $waiter is its zigsaw.
waiting() {
    "$zigsaw" run "$@" --command=zigsaw-netprobe.exe $APP wait 3000 >/dev/null 2>&1 &
    waiter=$!
}
# becomes <exempt|!exempt>: whether the container is (or isn't) exempt within 3 s.
becomes() {
    local i
    for i in $(seq 30); do
        if [ "$1" = exempt ]; then exempt && return 0; else exempt || return 0; fi
        sleep 0.1
    done
    return 1
}

reaches_host() {
    pings connects --sandbox=appcontainer --share=network || return 1
    ! exempt || { echo "still exempt after the run"; return 1; }
}
check "appcontainer: a run with the network reaches a server on this machine" reaches_host
exempt_while_it_runs() {
    waiting --sandbox=appcontainer --share=network
    becomes exempt || { wait $waiter; echo "not exempt while it ran"; return 1; }
    wait $waiter
    becomes '!exempt' || { echo "still exempt after it ended"; return 1; }
}
check "its container is exempt while the run goes, and not after" exempt_while_it_runs
without_network() {
    waiting --sandbox=appcontainer
    pings dropped --sandbox=appcontainer || { wait $waiter; return 1; }
    ! exempt || { wait $waiter; echo "exempt"; return 1; }
    wait $waiter
}
check "without the network, it doesn't, and isn't exempt" without_network
switched_off() {
    (
        export ZIGSAW_LOOPBACK_EXEMPTION=0
        pings dropped --sandbox=appcontainer --share=network
    ) || return 1
    ! exempt || { echo "exempt"; return 1; }
}
check "ZIGSAW_LOOPBACK_EXEMPTION=0: not even with the network" switched_off
# A zigsaw that's killed can't take the exemption back: `repair` does.
killed() {
    waiting --sandbox=appcontainer --share=network
    becomes exempt || { wait $waiter; echo "not exempt while it ran"; return 1; }
    # bash's kill would let it end as on Ctrl+C.
    taskkill /F /PID "$(cat /proc/$waiter/winpid)" >/dev/null
    wait $waiter 2>/dev/null
    sleep 0.5
    exempt || { echo "not exempt after zigsaw was killed"; return 1; }
    grep -qx loopback "$ZIGSAW_HOME\\grants\\$APP.txt" || { echo "not recorded"; return 1; }
    z repair >/dev/null 2>&1
    ! exempt || { echo "still exempt after repair"; return 1; }
}
check "a killed run's exemption is taken back by \`zigsaw repair\`" killed
# An exemption you made yourself, with CheckNetIsolation, isn't zigsaw's.
yours() {
    CheckNetIsolation.exe LoopbackExempt -a -n=zigsaw.$APP >/dev/null || { echo "CheckNetIsolation -a failed"; return 1; }
    local ok=0
    pings connects --sandbox=appcontainer --share=network || ok=1
    exempt || { echo "not exempt after the run"; ok=1; }
    CheckNetIsolation.exe LoopbackExempt -d -n=zigsaw.$APP >/dev/null
    return $ok
}
check "an exemption you made stays after the run" yours

# The server's port is one the app uses: ${uses:upstream}.
# upstream <run options...>: what the app's runs see as ${uses:upstream}.
upstream() { z run "$@" --command=netprobe-env $APP UPSTREAM_PORT | tr -d '\r' | sed -n 's/^UPSTREAM_PORT=//p'; }
# reaches_upstream <expected> <run options...>: a run of the app pings
# ${uses:upstream}, and the probe says <expected>.
reaches_upstream() {
    local expected=$1 out
    shift
    out=$(z run "$@" --command=netprobe-upstream $APP 2>&1 | tr -d '\r')
    [ "$out" = "$expected" ] || { echo "got $out"; return 1; }
}
direct_use() {
    local sb got
    for sb in soft low; do
        got=$(upstream --sandbox=$sb)
        [ "$got" = $host_port ] || { echo "$sb: got $got"; return 1; }
    done
    got=$(upstream --sandbox=appcontainer --share=network)
    [ "$got" = $host_port ] || { echo "exempt: got $got"; return 1; }
    reaches_upstream connects --sandbox=low
}
check "soft, low, and appcontainer when exempt: \${uses:x} is the port itself" direct_use
forwarded() {
    local got
    got=$(upstream --sandbox=appcontainer)
    [ "$got" != $host_port ] && [ "$got" -ge 20000 ] && [ "$got" -le 48999 ] || { echo "got $got"; return 1; }
    reaches_upstream connects --sandbox=appcontainer
}
check "appcontainer, not exempt: it's a port of the relay's, from which zigsaw forwards it" forwarded
check "  without the network, as the app has none, but not to the port itself" pings dropped --sandbox=appcontainer
forwarded_switched_off() {
    (
        export ZIGSAW_LOOPBACK_EXEMPTION=0
        reaches_upstream connects --sandbox=appcontainer --share=network
    ) || return 1
    ! exempt || { echo "exempt"; return 1; }
}
check "  and with the network, under ZIGSAW_LOOPBACK_EXEMPTION=0" forwarded_switched_off

kill $host_server 2>/dev/null
wait $host_server 2>/dev/null

# --port moves a port the app uses, as it moves a service.
moved_use() {
    local second ok=0
    "$probe" serve $host_port2 >/dev/null 2>&1 &
    second=$!
    sleep 0.5
    reaches_upstream connects --sandbox=appcontainer --port=upstream=$host_port2 || ok=1
    [ "$(upstream --sandbox=soft --port=upstream=$host_port2)" = $host_port2 ] || { echo "soft: not moved"; ok=1; }
    # Where nothing listens, the app's connection is closed.
    reaches_upstream connects --sandbox=appcontainer >/dev/null && { echo "the old port answered"; ok=1; }
    kill $second 2>/dev/null
    wait $second 2>/dev/null
    return $ok
}
check "--port moves a port the app uses" moved_use

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
