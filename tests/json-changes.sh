#!/usr/bin/env bash
# End-to-end checks for `--format=json` on the commands that change something
# (src/output.zig, docs/json.md): each prints one JSON value on stdout once
# it's done, with the keys docs/json.md lists; one that stops at a failure
# prints nothing, and one that goes on past failures (update, kill) prints
# what it did with what failed, exit 1; a build's tools write on stderr, not
# into the JSON; the forms that print no JSON are refused. tests/json.sh
# checks the commands that only read.
#
#   tests/zot.sh bash tests/json-changes.sh [path\to\zigsaw.exe]
#
# The remote side (install, build-export, build-update-repo, remote-add,
# remote-modify, remote-delete) needs a registry on localhost:5000; without
# one those rows are skipped, and the rest run. The fixture is batch files
# built with cmd, so nothing is downloaded. Needs Git Bash and jq. Always
# uses temporary stores, removed afterwards. Takes about half a minute.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root\\zig-out\\bin\\zigsaw.exe}
command -v jq >/dev/null || { echo "tests/json-changes.sh needs jq"; exit 1; }
work=$(cygpath -wl "$(mktemp -d)")
mkdir -p "$work\\cwd" && cd "$work\\cwd" || exit 1

export ZIGSAW_TASK_NAME="ZigsawTest-jsonc-$$"
export ZIGSAW_GRANTS_KEY="Software\\ZigsawTest\\jsonc-$$"
export ZIGSAW_CLASSES_KEY="Software\\ZigsawTest\\jsonc-$$-classes"
export ZIGSAW_SHORTCUTS_DIR="$work\\links"
export ZIGSAW_USER_FOLDERS="$work\\folders"
export DOCKER_CONFIG="$work\\docker"
mkdir -p "$DOCKER_CONFIG" "$ZIGSAW_USER_FOLDERS"

store_a="$work\\a"
store_b="$work\\b"
za() { ZIGSAW_HOME="$store_a" "$zigsaw" "$@"; }
zb() { ZIGSAW_HOME="$store_b" "$zigsaw" "$@"; }

APP=test.jsonc.app
OTHER=test.jsonc.other

cleanup() {
    touch "$store_a\\volumes\\$APP\\stop" 2>/dev/null
    za kill --now $APP >/dev/null 2>&1
    for s in "$store_a" "$store_b"; do
        [ -d "$s" ] || continue
        ZIGSAW_HOME="$s" "$zigsaw" uninstall $APP >/dev/null 2>&1
        ZIGSAW_HOME="$s" "$zigsaw" uninstall $OTHER >/dev/null 2>&1
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
# What `list` has of an app, which what installs one adds to.
listed_keys="id version manifest source commands runtimes extension_points extends shortcuts opens registry override lazy masked previous skips"

# --- The fixture --------------------------------------------------------------------
# A batch file, and a module whose build command writes on stdout: under
# --format=json that goes to stderr.
recipe() { # <dir> <id> <version>
    mkdir -p "$1"
    cat >"$1\\app.json" <<EOF
{ "id": "$2", "version": "$3", "name": "JSON Changes", "command": "app.cmd",
  "env": { "STOP": "\${data}\\\\stop" },
  "permissions": { "sandbox": "soft" }, "exports": { "hello": { "command": "app.cmd" } },
  "modules": [
    { "name": "scripts", "sources": [{ "path": "app.cmd" }] },
    { "name": "noise", "shell": "cmd", "build": ["echo noise-from-the-build"] }
  ] }
EOF
    # `app.cmd wait` waits for \${data}\stop.
    printf '%s\r\n' '@echo off' 'if "%1"=="wait" goto wait' "echo version $3" 'exit /b 0' ':wait' 'if exist "%STOP%" exit /b 0' 'ping -n 2 127.0.0.1 >nul' 'goto wait' >"$1\\app.cmd"
}
recipe "$work\\app" $APP 1

# Fails, says why, prints nothing on stdout.
refused() { # <args>...
    local out
    out=$(za "$@" 2>/dev/null) && { echo "it went on"; return 1; }
    [ -z "$out" ] || { echo "stdout: $out"; return 1; }
    za "$@" 2>&1 >/dev/null | grep -q 'prints no JSON'
}
# Fails as text does, with nothing on stdout.
fails_quietly() { # <args>...
    local out
    out=$(za "$@" 2>/dev/null) && { echo "it went on"; return 1; }
    [ -z "$out" ] || { echo "stdout: $out"; return 1; }
}

# --- Building and installing ----------------------------------------------------------
built_json() {
    local out
    out=$(za build "$work\\app\\app.json" --format=json 2>"$work\\err.txt") || { tail -3 "$work\\err.txt"; return 1; }
    is "$out" 'type == "array" and length == 1' &&
        keys_are "$out" '.[0]' $listed_keys replaced old_kept_running reused &&
        is "$out" ".[0].id == \"$APP\" and .[0].version == \"1\" and (.[0].manifest | $digest) and .[0].commands == [\"hello\"]" &&
        is "$out" '.[0].replaced == null and .[0].old_kept_running == false and .[0].reused == false' &&
        grep -q noise-from-the-build "$work\\err.txt" || { echo "the build's own output isn't on stderr"; return 1; }
}
check "build: the app it installed, as list has it; its tools' output on stderr, not stdout" built_json
check "  built again from the same inputs: reused" is "$(za build "$work\\app\\app.json" --format=json 2>/dev/null)" '.[0].reused == true and .[0].replaced == null'
first=$(za list --format=json | jq -r '.[0].manifest')
recipe "$work\\app" $APP 2
replaced_json() {
    local out
    out=$(za build "$work\\app\\app.json" --format=json 2>/dev/null) || return 1
    is "$out" ".[0].version == \"2\" and .[0].replaced == {\"version\": \"1\", \"manifest\": \"$first\"} and .[0].previous.version == \"1\""
}
check "  version 2: what it replaced" replaced_json
check "a build that fails prints nothing" fails_quietly build "$work\\no-such\\app.json" --format=json

# --- What updates do ---------------------------------------------------------------
mask_json() {
    local out
    out=$(za mask $APP --format=json) || return 1
    is "$out" ". == [{\"id\": \"$APP\", \"version\": \"2\", \"masked\": true, \"changed\": true}]" &&
        is "$(za mask $APP --format=json)" '.[0].changed == false' &&
        is "$(za mask --remove $APP --format=json)" '.[0].masked == false and .[0].changed == true'
}
check "mask and mask --remove: each app, and whether it changed" mask_json
check "  mask of an app not installed changes nothing, prints nothing" fails_quietly mask $APP org.example.none --format=json

override_json() {
    local out
    out=$(za override --env=A=1 $APP --format=json) || return 1
    is "$out" '.env == ["A=1"]' &&
        is "$(za override $APP --format=json)" '.env == ["A=1"]' &&
        is "$(za override --reset $APP --format=json)" '. == null' &&
        is "$(za override $APP --format=json)" '. == null'
}
check "override: what's saved after the change, or null; the same without options" override_json

rollback_json() {
    local out
    out=$(za rollback --yes --keep-data $APP --format=json) || return 1
    keys_are "$out" . id from to from_manifest to_manifest data snapshot &&
        is "$out" ".id == \"$APP\" and .from == \"2\" and .to == \"1\" and .to_manifest == \"$first\" and (.data == \"kept\" or .data == \"none\")"
}
check "rollback: from and to, and what became of its data" rollback_json

recipe "$work\\other" $OTHER 1
za build "$work\\other\\app.json" >/dev/null 2>&1
rm -rf "$work\\other"
update_json() {
    local out code
    out=$(za update --yes --format=json $APP $OTHER 2>/dev/null)
    code=$?
    [ "$code" = 1 ] || { echo "exit $code"; return 1; }
    keys_are "$out" . updated up_to_date skipped failed &&
        is "$out" ".skipped == [{\"id\": \"$APP\", \"why\": \"skips\"}] and .failed == [\"$OTHER\"] and .updated == []"
}
check "update goes on past a failure: what it did, what failed, exit 1" update_json
za uninstall $OTHER >/dev/null 2>&1
recipe "$work\\app" $APP 3
updated_json() {
    local out
    out=$(za update --yes --format=json $APP 2>/dev/null) || return 1
    is "$out" ".updated[0] | .id == \"$APP\" and .from == \"1\" and .to == \"3\" and (.to_manifest | $digest)" &&
        is "$out" '.failed == [] and .skipped == []'
}
check "  and what it updated: from, to, and the manifests" updated_json

# --- Runs ---------------------------------------------------------------------------
run_json=$(za run -d --format=json $APP wait 2>/dev/null)
run_d() {
    keys_are "$run_json" . run id log in_job &&
        is "$run_json" ".id == \"$APP\" and (.run | type) == \"number\" and (.log | type) == \"string\"" &&
        is "$(za ps --format=json)" "[.[] | .run] | index($(jq .run <<<"$run_json")) != null"
}
check "run -d: the run's number, which ps lists, and its log" run_d
run=$(jq -r '.run // empty' <<<"$run_json" 2>/dev/null)
enter_d() {
    local out
    out=$(za enter -d --format=json "$run" hello 2>/dev/null) || return 1
    keys_are "$out" . run inside id command in_job &&
        is "$out" ".inside == $run and .id == \"$APP\" and .command == \"hello\""
}
check "enter -d: the exec's number, and the run it's in" enter_d
check "run without -d refuses JSON" refused run --format=json $APP
kill_json() {
    local out
    out=$(za kill --now --format=json "$run" 2>/dev/null) || return 1
    is "$out" "type == \"array\" and (map(select(.run == $run)) | length) == 1" &&
        keys_are "$out" '.[0]' run id kind inside outcome why &&
        is "$out" ".[] | select(.run == $run) | .kind == \"run\" and (.outcome == \"killed\" or .outcome == \"ended\")"
}
check "kill --now: each run it ended, and how" kill_json
check "  nothing running by that name: nothing on stdout" fails_quietly kill --format=json org.example.none

mkdir -p "$work\\proj"
printf '{ "run": [{ "app": "%s", "args": ["wait"] }] }\n' $APP >"$work\\proj\\zigsaw.json"
up_json() {
    rm -f "$store_a\\volumes\\$APP\\stop"
    local out
    out=$(za up -d --format=json "$work\\proj" 2>/dev/null) || return 1
    keys_are "$out" '.[0]' id run log ports state &&
        is "$out" "length == 1 and .[0].id == \"$APP\" and .[0].state == \"started\"" &&
        is "$(za up -d --format=json "$work\\proj" 2>/dev/null)" '.[0].state == "up_already"'
}
check "up -d: each app, and whether it started now" up_json
check "  up without -d refuses JSON" refused up --format=json "$work\\proj"
down_json() {
    local out
    out=$(za down --time=1 --format=json "$work\\proj" 2>/dev/null)
    is "$out" "type == \"array\" and length >= 1 and .[0].id == \"$APP\"" &&
        is "$(za down --format=json "$work\\proj" 2>/dev/null)" '. == []'
}
check "down: what it stopped; then nothing running, []" down_json

# --- Volumes ------------------------------------------------------------------------
volume_json() {
    local out
    out=$(za volume create jcvol --format=json) || return 1
    keys_are "$out" . name path external own mounts && is "$out" '.name == "jcvol" and .own == false' || return 1
    # A name that can't go leaves the others.
    fails_quietly volume rm --format=json jcvol org-example-none || return 1
    [ -d "$store_a\\volumes\\jcvol" ] || { echo "rm removed jcvol before failing"; return 1; }
    is "$(za volume rm --format=json jcvol)" '. == [{"name": "jcvol", "files_kept": null}]'
}
check "volume create, then rm: checks every name before removing any" volume_json
mkdir -p "$store_a\\volumes\\$APP"
printf 'abc' >"$store_a\\volumes\\$APP\\three.txt"
export_import() {
    local out
    out=$(za volume export --format=json $APP "$work\\data.tar") || return 1
    keys_are "$out" . volume file gzip bytes files links_passed_over archive_bytes left_out &&
        is "$out" ".volume == \"$APP\" and .files >= 1 and .archive_bytes > 0 and .gzip == false" || return 1
    out=$(za volume import --format=json jcdata "$work\\data.tar") || return 1
    keys_are "$out" . volume file bytes files links_passed_over made replaced exported &&
        is "$out" ".volume == \"jcdata\" and .made == true and .replaced == 0 and .exported.volume == \"$APP\" and .exported.version == \"3\""
}
check "volume export and import: what went in the archive, and what it says of itself" export_import
check "  export to - refuses JSON" refused volume export --format=json $APP -
prune_json() {
    local out
    out=$(za volume prune --dry-run --format=json) || return 1
    keys_are "$out" . dry_run removed in_use bytes &&
        is "$out" '.dry_run and ([.removed[] | .name] | index("jcdata")) != null' || return 1
    out=$(za uninstall --unused --dry-run --format=json) || return 1
    keys_are "$out" . dry_run freed removed kept forgot_previous &&
        keys_are "$out" .removed blobs deployments tmp downloads tool_caches work volumes kept_data &&
        is "$out" '.dry_run and .removed.downloads == null and (.kept.volumes | index("jcdata")) != null'
}
check "volume prune and uninstall --unused, --dry-run: what would go, and what stays" prune_json

# --- The rest --------------------------------------------------------------------------
mkdir -p "$work\\plain"
check "permission-remove of a folder with no label: says so" is "$(za permission-remove --format=json "$work\\plain" 2>/dev/null)" '.outcome == "no_label"'
check "repair: the apps it repaired" is "$(za repair --format=json 2>/dev/null)" ".apps == [\"$APP\"] and .failed == [] and .grants_unsettled == 0"
check "updates off: the daily check is off" is "$(za updates off --format=json 2>/dev/null)" '. == {"daily_check": false}'
check "  updates on --unless-off leaves it off" is "$(za updates on --unless-off --format=json)" '. == {"daily_check": false}'
uninstall_json() {
    local out
    out=$(za uninstall --format=json $APP) || return 1
    keys_are "$out" . id version manifest data_deleted data kept_volumes files_kept removed &&
        is "$out" ".id == \"$APP\" and .data_deleted == false and .removed.commands == [\"hello\"]"
}
check "uninstall: what it removed, and where its data stays" uninstall_json

# --- The remote side ------------------------------------------------------------------
registry=localhost:5000
if curl -sf "http://127.0.0.1:5000/v2/" >/dev/null; then
    repo="$registry/zigsaw-jsonc-$RANDOM"
    sza() { ZIGSAW_REGISTRY="$repo" za "$@"; }
    szb() { ZIGSAW_REGISTRY="$repo" zb "$@"; }
    za build "$work\\app\\app.json" >/dev/null 2>&1
    export_json() {
        local out
        out=$(sza build-export --format=json $APP) || return 1
        keys_are "$out" . id version image manifest sources &&
            is "$out" ".id == \"$APP\" and .version == \"3\" and (.image | endswith(\":3\")) and .sources == null" || return 1
        out=$(sza build-export --sources --format=json $APP $APP:latest) || return 1
        is "$out" '(.image | endswith(":latest")) and (.sources | type) == "object"'
    }
    check "build-export: the image by its tag, and --sources what went beside it" export_json
    repo_json() {
        local out
        out=$(sza build-update-repo --format=json $APP) || return 1
        keys_are "$out" . catalog registry apps &&
            is "$out" ".apps == [{\"id\": \"$APP\", \"version\": \"3\", \"manifest\": \"$(za list --format=json | jq -r '.[0].manifest')\"}]"
    }
    check "build-update-repo: the catalog, and the apps it lists" repo_json
    install_json() {
        local out
        out=$(szb install --yes --format=json $APP 2>/dev/null) || return 1
        keys_are "$out" . $listed_keys replaced old_kept_running &&
            is "$out" ".id == \"$APP\" and .version == \"3\" and .replaced == null and (.source | test(\"zigsaw-jsonc\"))"
    }
    check "install: the app, as list has it" install_json
    remotes_json() {
        local out
        out=$(zb remote-add --format=json jc "$registry/jc") || return 1
        keys_are "$out" . name url default from_env signers login changed &&
            is "$out" '.name == "jc" and .changed == true' || return 1
        is "$(zb remote-add --if-not-exists --format=json jc "$registry/jc")" '.changed == false' || return 1
        is "$(zb remote-modify --url="$registry/jc2" --format=json jc)" '.changed == true and (.url | endswith("/jc2"))' || return 1
        out=$(zb remote-delete --format=json jc) || return 1
        keys_are "$out" . name url signers_removed login_kept remotes_left && is "$out" '.name == "jc"'
    }
    check "remote-add, -modify, -delete: the remote as remotes has it, and what changed" remotes_json
else
    skip "the remote side: no registry on localhost:5000 (tests/zot.sh starts one)"
fi

echo
if [ "$failures" -gt 0 ]; then
    echo "$failures failed"
    exit 1
fi
echo "all passed"
