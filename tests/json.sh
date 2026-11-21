#!/usr/bin/env bash
# End-to-end checks for `--format=json` (src/output.zig, docs/json.md): what
# each command that prints data prints as JSON, read back with jq: the keys
# docs/json.md lists, every one there, null where there's nothing; whole
# digests, bytes, RFC 3339 times; an empty listing as []; the text's exit
# codes, and nothing on stdout when a command fails; the forms that print no
# JSON refused; and --format=text the same as no --format.
#
#   tests/zot.sh bash tests/json.sh [path\to\zigsaw.exe]
#
# The remote side (remote-info, --show-files, search, remote-ls, remotes,
# update --check, updates) needs a registry on localhost:5000; without one
# those rows are skipped, and the rest run. The fixture is a batch file, so
# nothing is downloaded. Needs Git Bash and jq. Always uses temporary stores,
# removed afterwards. Takes about half a minute.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root\\zig-out\\bin\\zigsaw.exe}
command -v jq >/dev/null || { echo "tests/json.sh needs jq"; exit 1; }
work=$(cygpath -wl "$(mktemp -d)")
mkdir -p "$work\\cwd" && cd "$work\\cwd" || exit 1

export ZIGSAW_TASK_NAME="ZigsawTest-json-$$"
export ZIGSAW_GRANTS_KEY="Software\\ZigsawTest\\json-$$"
export ZIGSAW_CLASSES_KEY="Software\\ZigsawTest\\json-$$-classes"
export ZIGSAW_SHORTCUTS_DIR="$work\\links"
export ZIGSAW_USER_FOLDERS="$work\\folders"
export DOCKER_CONFIG="$work\\docker"
mkdir -p "$DOCKER_CONFIG" "$ZIGSAW_USER_FOLDERS"

store_a="$work\\a"
store_b="$work\\b"
za() { ZIGSAW_HOME="$store_a" "$zigsaw" "$@"; }
zb() { ZIGSAW_HOME="$store_b" "$zigsaw" "$@"; }

cleanup() {
    touch "$store_a\\volumes\\$APP\\stop" 2>/dev/null
    for s in "$store_a" "$store_b"; do
        [ -d "$s" ] && ZIGSAW_HOME="$s" "$zigsaw" uninstall $APP >/dev/null 2>&1
    done
    reg delete "HKCU\\$ZIGSAW_GRANTS_KEY" /f >/dev/null 2>&1
    reg delete "HKCU\\$ZIGSAW_CLASSES_KEY" /f >/dev/null 2>&1
    cd / && rm -rf "$work"
}
trap cleanup EXIT

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
skip() { printf 'skip  %s\n' "$1"; }

# jq -e <filter> on JSON, saying what it was given when that's false.
is() { # <json> <filter>
    jq -e "$2" <<<"$1" >/dev/null 2>&1 || { echo "not $2: $(tr -d '\n' <<<"$1" | cut -c1-200)"; return 1; }
}
# The keys of an object, as docs/json.md lists them.
keys_are() { # <json> <jq path> <key>...
    local json=$1 path=$2
    shift 2
    local want
    want=$(printf '%s\n' "$@" | jq -R . | jq -sc 'sort')
    is "$json" "($path | keys) == $want"
}
digest='test("^sha256:[0-9a-f]{64}$")'
rfc3339='test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")'

# --- The fixture --------------------------------------------------------------------
APP=test.json.app
recipe() { # <version> [network]
    local extra=
    [ "${2:-}" = network ] && extra=', "network": true'
    printf '{ "id": "%s", "version": "%s", "name": "JSON Test", "summary": "A fixture for --format=json",\n  "command": "app.cmd", "layer": "estargz", "env": { "STOP": "${data}\\\\stop" },\n  "permissions": { "sandbox": "soft"%s }, "exports": { "hello": { "command": "app.cmd" } },\n  "modules": [{ "name": "scripts", "sources": [{ "path": "app.cmd" }] }] }\n' \
        $APP "$1" "$extra" >"$work\\app.json"
    # `app.cmd wait` waits for ${data}\stop.
    printf '%s\r\n' '@echo off' 'if "%1"=="wait" goto wait' "echo version $1" 'exit /b 0' ':wait' 'if exist "%STOP%" exit /b 0' 'ping -n 2 127.0.0.1 >nul' 'goto wait' >"$work\\app.cmd"
}
recipe 1
za build "$work\\app.json" >"$work\\build.txt" 2>&1 || { echo "building the fixture failed:"; tail -5 "$work\\build.txt"; exit 1; }

# --- Every command prints JSON only where it can --------------------------------------
refused() { # <args>...: fails, says so, prints nothing on stdout
    local out
    out=$(za "$@" 2>/dev/null) && { echo "it went on"; return 1; }
    [ -z "$out" ] || { echo "stdout: $out"; return 1; }
    za "$@" 2>&1 >/dev/null | grep -q -e 'prints no JSON' -e '--format takes text or json' -e '--format needs a value'
}
check "logs --format=json is refused, saying why" refused logs --format=json $APP
check "  and remote-info --file" refused remote-info --file=app.cmd --format=json $APP
check "  and run without -d" refused run --format=json $APP
check "  and updates check --notify" refused updates check --notify --format=json
check "--format=yaml is refused" refused list --format=yaml
check "--format without a value is refused" refused list --format
same_text() { [ "$(za list 2>/dev/null)" = "$(za list --format=text 2>/dev/null)" ]; }
check "--format=text is the text" same_text

version_json() {
    local out
    out=$(za version --format json) || return 1
    keys_are "$out" . version && is "$out" ".version == \"$(za version | tr -d '\r' | sed 's/^zigsaw //')\""
}
check "version: its version, --format json spelt apart" version_json

# --- Installed apps -----------------------------------------------------------------
list_json() {
    local out
    out=$(za list --format=json) || return 1
    is "$out" 'type == "array" and length == 1' &&
        keys_are "$out" '.[0]' id version manifest source commands runtimes extension_points extends shortcuts opens registry override lazy masked previous skips &&
        is "$out" ".[0].id == \"$APP\" and .[0].version == \"1\" and (.[0].manifest | $digest)" &&
        is "$out" '.[0].commands == ["hello"] and .[0].extends == null and .[0].override == null and .[0].masked == false and .[0].previous == null' &&
        is "$out" ".[0].manifest | startswith(\"$(za list | tr -d '\r' | awk -v id=$APP '$1 == id { print $3 }')\")"
}
check "list: each app, every key there, its whole manifest digest the one text shortens" list_json

info_json() {
    local out data
    out=$(za info $APP --format=json) || return 1
    keys_are "$out" . id version name summary homepage license source remote manifest runtimes layer_format extension_points extends commands shortcuts opens unsupported permissions uses registry build location data masked previous &&
        is "$out" '.name == "JSON Test" and .homepage == null and .layer_format == "estargz" and .permissions.sandbox == "soft"' &&
        is "$out" '.commands == ["hello"] and (.build.sources | length) == 1 and .remote == null and (.source | endswith("app.json"))' &&
        is "$out" "(.location | type) == \"string\" and .manifest == \"$(za list --format=json | jq -r '.[0].manifest')\""
}
check "info: the app, what it brings and may reach, where it is" info_json
check "info of an app not installed fails, with nothing on stdout" sh -c "out=\$(ZIGSAW_HOME='$store_a' '$zigsaw' info org.example.none --format=json 2>/dev/null); [ \$? = 1 ] && [ -z \"\$out\" ]"

overridden() {
    za override --env=A=1 $APP >/dev/null 2>&1 && za mask $APP >/dev/null 2>&1 || return 1
    local out
    out=$(za list --format=json) || return 1
    is "$out" '.[0].override.env == ["A=1"] and .[0].masked == true' || return 1
    out=$(za mask --format=json) || return 1
    is "$out" ". == [{\"id\": \"$APP\", \"version\": \"1\"}]" || return 1
    za mask --remove $APP >/dev/null 2>&1 && is "$(za mask --format=json)" '. == []'
}
check "list has its override as saved and whether it's masked; mask lists the masked, then none" overridden

volumes_json() {
    za volume create jsonvol >/dev/null 2>&1 && za override --volume=jsonvol:cache $APP >/dev/null 2>&1 || return 1
    printf '12345' >"$store_a\\volumes\\jsonvol\\five.txt"
    local out
    out=$(za volume ls --format=json) || return 1
    is "$out" '[.[] | select(.name == "jsonvol")] | length == 1' &&
        keys_are "$out" '.[] | select(.name == "jsonvol")' name path external own mounts &&
        is "$out" ".[] | select(.name == \"jsonvol\") | .mounts == [{\"app\": \"$APP\", \"target\": \"cache\", \"read_only\": false}] and .external == false" || return 1
    out=$(za volume inspect jsonvol --format=json) || return 1
    keys_are "$out" . name path external own exists bytes files mounts in_use grants &&
        is "$out" '.exists and .bytes == 5 and .files == 1 and .in_use == false and .grants == []'
}
check "volume ls and inspect: where each is, its mounts, its size in bytes" volumes_json

# --- Runs -----------------------------------------------------------------------------
nothing_running() {
    local out err
    out=$(za ps --format=json 2>"$work\\err.txt") || return 1
    err=$(cat "$work\\err.txt")
    is "$out" '. == []' && [ -z "$err" ] || { echo "stderr: $err"; return 1; }
}
check "ps with nothing running: [], and no note" nothing_running

run=$(za run -d $APP wait 2>/dev/null | tr -d '\r')
ps_json() {
    [ -n "$run" ] || { echo "the run didn't start"; return 1; }
    local out
    out=$(za ps --format=json) || return 1
    is "$out" "length == 1 and .[0].run == $run and .[0].kind == \"run\" and .[0].id == \"$APP\" and .[0].sandbox == \"soft\"" &&
        keys_are "$out" '.[0]' run kind id version manifest sandbox network inside started process_count memory memory_limit cpus cpu_ms ephemeral command shortcut log project ports module step n of processes &&
        is "$out" ".[0].started | $rfc3339" &&
        is "$out" '.[0].process_count >= 1 and .[0].memory > 0 and (.[0].cpu_ms | type) == "number" and .[0].processes == null and .[0].module == null' &&
        is "$out" '(.[0].command | test("app.cmd")) and (.[0].log | type) == "string"'
}
check "ps: the run, by its zigsaw's PID, with raw numbers and when it started" ps_json
processes_json() {
    local out
    out=$(za ps --processes --format=json) || return 1
    is "$out" '(.[0].processes | length) >= 1 and all(.[0].processes[]; (.pid | type) == "number" and (.ppid | type) == "number")' &&
        is "$out" '[.[0].processes[] | .name] | any(. == "cmd.exe")'
}
check "  --processes lists its processes, each naming its parent" processes_json
check "  filtered to another app: []" is "$(za ps --format=json org.example.none)" '. == []'
stops() {
    touch "$store_a\\volumes\\$APP\\stop" || return 1
    for _ in $(seq 30); do
        [ "$(za ps --format=json | jq length)" = 0 ] && return 0
        sleep 0.5
    done
    echo "it didn't end"
    return 1
}
check "  and once it ends, []" stops

# --- What zigsaw changed, and what's wrong --------------------------------------------
permissions_json() {
    local out
    out=$(za permissions --format=json) || return 1
    keys_are "$out" . store other_stores deleted_stores unexplained daily_checks &&
        is "$out" '(.store.root | type) == "string" and (.store.apps | type) == "array" and (.daily_checks | type) == "array"'
}
check "permissions: this store's changes, other stores', and the daily checks" permissions_json

doctor_json() {
    local out code text_code
    out=$(za doctor --offline --format=json 2>/dev/null)
    code=$?
    za doctor --offline >/dev/null 2>&1
    text_code=$?
    [ "$code" = "$text_code" ] || { echo "exit $code, and $text_code in text"; return 1; }
    keys_are "$out" . version sections problems warnings &&
        is "$out" '(.sections | length) > 3 and all(.sections[].findings[]; .level == "ok" or .level == "note" or .level == "warning" or .level == "problem")' &&
        is "$out" '.problems == ([.sections[].findings[] | select(.level == "problem")] | length)' &&
        is "$out" '[.sections[] | .title] | any(test("^Network: not checked"))'
}
check "doctor: its sections and findings, counted, with the text's exit code" doctor_json

updates_offline() {
    local out
    out=$(za updates --format=json) || return 1
    keys_are "$out" . checked waiting failed zigsaw zigsaw_failed daily_check &&
        is "$out" '.checked == null and .waiting == [] and .zigsaw == null and (.daily_check | type) == "boolean"'
}
check "updates before any check: checked null, nothing waiting" updates_offline

# --- The remote side --------------------------------------------------------------------
registry=localhost:5000
if curl -sf "http://127.0.0.1:5000/v2/" >/dev/null; then
    repo="$registry/zigsaw-json-$RANDOM"
    sza() { ZIGSAW_REGISTRY="$repo" za "$@"; }
    szb() { ZIGSAW_REGISTRY="$repo" zb "$@"; }
    publish() { sza build-export $APP >/dev/null 2>&1 && sza build-export $APP $APP:latest >/dev/null 2>&1 && sza build-update-repo $APP >/dev/null 2>&1; }
    check "the fixture goes out, with a catalog" publish

    remote_info() {
        local out
        out=$(szb remote-info $APP --format=json) || return 1
        keys_are "$out" . id version name summary homepage license image manifest index signature download runtimes layer_format extension_points extends commands shortcuts opens unsupported permissions uses registry build installed &&
            is "$out" ".id == \"$APP\" and (.manifest | $digest) and .installed == null and .index == null" &&
            is "$out" '(.signature.state == "missing" or .signature.state == "no_key") and .signature.by == null' &&
            is "$out" '.download.bytes > 0 and .download.missing > 0 and .download.missing <= .download.bytes and .layer_format == "estargz"'
    }
    check "remote-info: the image, its signature, what installing it downloads" remote_info
    installed_now() {
        szb install --yes $APP >/dev/null 2>&1 || return 1
        local out
        out=$(szb remote-info $APP --format=json) || return 1
        is "$out" '.installed.manifest == .manifest and .installed.version == "1" and .download.missing == 0'
    }
    check "  once installed: which version, and nothing left to download" installed_now
    show_files() {
        local out
        out=$(szb remote-info --show-files $APP --format=json) || return 1
        is "$out" "length == 1 and .[0].id == \"$APP\" and .[0].format == \"estargz\" and (.[0].layer | $digest)" &&
            is "$out" ".[0].files == [{\"name\": \"app.cmd\", \"size\": $(stat -c %s "$work\\app.cmd")}]"
    }
    check "remote-info --show-files: each layer's files, with their sizes in bytes" show_files

    search_json() {
        local out
        out=$(szb search --format=json json fixture) || return 1
        is "$out" "length == 1 and .[0].remote == \"zigsaw\" and .[0].id == \"$APP\" and .[0].name == \"JSON Test\" and .[0].commands == [\"hello\"]" &&
            is "$out" '(.[0].manifest | test("^sha256:")) and .[0].download > 0' || return 1
        out=$(szb remote-ls --format=json) || return 1
        is "$out" "[.[] | .id] == [\"$APP\"]"
    }
    check "search and remote-ls: the catalog's entries, each with its remote" search_json
    no_match() {
        local out
        out=$(szb search --format=json no-such-app-anywhere 2>"$work\\err.txt")
        [ $? = 1 ] && is "$out" '. == []' && [ ! -s "$work\\err.txt" ]
    }
    check "  nothing found: [], no note, and exit 1 as text has" no_match

    remotes_json() {
        local out
        out=$(szb remotes --format=json) || return 1
        keys_are "$out" . remotes releases &&
            keys_are "$out" '.remotes[0]' name url default from_env signers login &&
            is "$out" ".remotes[0] | .name == \"zigsaw\" and .url == \"$repo\" and .default and .from_env and .login == null" &&
            is "$out" '(.releases.signers | length) == 2 and all(.releases.signers[]; .built_in) and ([.releases.signers[] | .kind] | sort) == ["key", "keyless"]'
    }
    check "remotes: each remote, its signers and login; zigsaw's releases' signers" remotes_json

    waiting() {
        recipe 2 network && za build "$work\\app.json" >/dev/null 2>&1 && publish || { echo "publishing version 2 failed"; return 1; }
        local out
        out=$(zb update --check --format=json) || return 1
        keys_are "$out" . waiting failed && keys_are "$out" '.waiting[0]' id from to from_manifest to_manifest adds &&
            is "$out" ".waiting[0] | .id == \"$APP\" and .from == \"1\" and .to == \"2\" and (.to_manifest | $digest) and .adds.permissions.network == true" &&
            is "$out" '.failed == []'
    }
    check "update --check: what's waiting, and what it adds" waiting
    checked() {
        local out
        out=$(zb updates check --format=json) || return 1
        is "$out" ".checked | $rfc3339" && is "$out" ".waiting[0].to == \"2\" and .waiting[0].adds.permissions.network == true" || return 1
        out=$(zb updates --format=json) || return 1
        is "$out" '.waiting[0].to == "2" and .failed == [] and .zigsaw_failed == false'
    }
    check "updates check, then updates: when it checked, and the same" checked
else
    skip "the remote side: no registry on localhost:5000 (tests/zot.sh starts one)"
fi

echo
if [ "$failures" -gt 0 ]; then
    echo "$failures failed"
    exit 1
fi
echo "all passed"
