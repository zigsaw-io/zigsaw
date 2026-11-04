#!/usr/bin/env bash
# Checks scripts/rebuild.sh with made-up recipes and a stand-in for zigsaw, so it needs
# no network and takes seconds; and that it can order the real recipes. Runs on Linux
# too, as CI's pins job does.
#
#   tests/rebuild.sh

set -u

root=$(cd "$(dirname "$0")/.." && pwd)
script=$root/scripts/rebuild.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
check() {
    local label=$1
    shift
    if "$@"; then
        echo "ok    $label"
    else
        echo "FAIL  $label"
        failures=$((failures + 1))
    fi
}

old=$(printf 'a%.0s' {1..64})
recipes=$work/recipes

# <file> <id> <version> [<pinned id>:<tag>...]
r() {
    local file=$1 id=$2 version=$3 sdk= p
    shift 3
    for p in "$@"; do sdk+="\"${p%%:*}\": \"$p@sha256:$old\", "; done
    printf '{\n  "id": "%s",\n  "version": "%s",\n  "sdk": { %s"z": "org.other:1@sha256:%s" }\n}\n' "$id" "$version" "$sdk" "$old" >"$recipes/$file.json"
}
# A chain and a fan: go <- app, go <- tool <- top; other, which everything pins but
# isn't named; a local one; and a recipe that pins an older build of itself.
fresh() {
    rm -rf "$recipes"
    mkdir -p "$recipes/no-publish"
    r go org.go 1.2.3
    r tool org.tool 2.0 org.go:1.2.1
    r app org.app 3.0 org.go:1.2.1
    r top org.top 4.0 org.tool:2.0 org.go:1.2.1
    r other org.other 1
    r no-publish/local org.local 9 org.go:1.2.1
}
fresh
# Listed so that going by this list alone would be wrong: top before what it pins.
printf '# the published ones\ntop.json\napp.json\nother.json\ntool.json\ngo.json\n' >"$work/published.txt"
export REBUILD_RECIPES=$recipes
export REBUILD_PUBLISHED=$work/published.txt

# A stand-in for zigsaw: `build <file>` records which, and writes the store's ref, with
# a digest of the recipe's bytes, so that a changed pin changes the digest. Or fails
# on request.
export ZIGSAW=$work/fake-zigsaw
export FAKE_CALLS=$work/calls
cat >"$ZIGSAW" <<'EOF'
#!/usr/bin/env bash
[ "$1" = build ] || exit 9
name=${2##*[\\/]}
echo "$name" >>"$FAKE_CALLS"
if [ "${FAKE_FAIL:-}" = "$name" ]; then
    echo "error: it broke, for a test"
    exit 1
fi
id=$(sed -n 's/^ *"id": *"\([^"]*\)".*/\1/p' "$2")
hex=$(sha256sum <"$2" | cut -d' ' -f1)
mkdir -p "$ZIGSAW_HOME/refs"
printf '{"manifest": "sha256:%s"}\n' "$hex" >"$ZIGSAW_HOME/refs/$id.json"
EOF
chmod +x "$ZIGSAW"

words() { tr '\n' ' ' | sed 's/ $//'; }
hex_of() { sed -n 's/.*"manifest": *"sha256:\([0-9a-f]*\)".*/\1/p' "$store/refs/$1.json"; }
has() { grep -qF -- "$2" "$recipes/$1.json"; }

plan=$(bash "$script" --plan go.json)
check "--plan: what pins it, each after what it pins, equals by the published list" \
    [ "$(printf '%s\n' "$plan" | grep -v '^not published' | words)" = "go app tool top" ]
check "--plan: a recipe that isn't published is listed, not built" \
    sh -c "printf '%s\n' \"\$1\" | grep -q '^not published.*: local\$'" _ "$plan"
check "--plan: changes nothing" has top "org.go:1.2.1@sha256:$old"
check "--plan: what was named comes along with what pins it, and not what it pins" \
    [ "$(bash "$script" --plan tool.json | words)" = "tool top" ]
check "--plan: several named, one pinning the other, is one order" \
    [ "$(bash "$script" --plan top.json go.json | grep -v '^not published' | words)" = "go app tool top" ]

no_store() { ! (unset ZIGSAW_HOME; bash "$script" go.json >/dev/null 2>"$work/err") && grep -q 'set ZIGSAW_HOME' "$work/err"; }
check "building needs ZIGSAW_HOME" no_store
no_such() { ! bash "$script" --plan nope.json >/dev/null 2>"$work/err" && grep -q 'no recipe nope.json' "$work/err"; }
check "a recipe that doesn't exist is an error" no_such

# Building, and pins.
store=$work/store
export ZIGSAW_HOME=$store
export REBUILD_LOGS=$work/logs
: >"$FAKE_CALLS"
output=$(bash "$script" go.json)
code=$?
check "a build succeeds" [ "$code" = 0 ]
check "it builds in the order given" [ "$(words <"$FAKE_CALLS")" = "go.json app.json tool.json top.json" ]
go_hex=$(hex_of org.go)
tool_hex=$(hex_of org.tool)
check "a pin gets the digest, and the built recipe's version" has app "\"org.go:1.2.3@sha256:$go_hex\""
check "  in every recipe that pins it" has top "\"org.go:1.2.3@sha256:$go_hex\""
check "a pin of something rebuilt on the way gets its digest too" has top "\"org.tool:2.0@sha256:$tool_hex\""
check "  built after that, so its own digest is of the new pins" sh -c "grep -q 'org.go:1.2.3' '$recipes/tool.json'"
check "a pin of what wasn't rebuilt stays" has app "\"org.other:1@sha256:$old\""
check "what's not published stays on the old pin" has no-publish/local "org.go:1.2.1@sha256:$old"
check "each step says its recipe and digest" sh -c "printf '%s\n' \"\$1\" | grep -q '^go ${go_hex:0:12} '" _ "$output"
check "it ends with what to publish, in order" sh -c "printf '%s\n' \"\$1\" | grep -q 'scripts/publish.sh go.json app.json tool.json top.json\$'" _ "$output"

first_top=$(hex_of org.top)
fresh
: >"$FAKE_CALLS"
store=$work/store2
export ZIGSAW_HOME=$store
output=$(bash "$script" --no-pin go.json)
check "--no-pin builds the same recipes" [ "$(words <"$FAKE_CALLS")" = "go.json app.json tool.json top.json" ]
check "--no-pin changes no recipe" has top "org.go:1.2.1@sha256:$old"
check "--no-pin says nothing about publishing" sh -c "! printf '%s\n' \"\$1\" | grep -q publish.sh" _ "$output"
check "--no-pin: on old pins, so another digest than the run that pinned" [ "$(hex_of org.top)" != "$first_top" ]

# Stopping, and going on.
fresh
store=$work/store3
export ZIGSAW_HOME=$store
: >"$FAKE_CALLS"
output=$(FAKE_FAIL=tool.json bash "$script" go.json)
code=$?
check "a failed build fails the run" [ "$code" != 0 ]
check "  and stops there" [ "$(words <"$FAKE_CALLS")" = "go.json app.json tool.json" ]
check "  saying which, with the end of its log" sh -c "printf '%s\n' \"\$1\" | grep -q 'tool FAILED' && printf '%s\n' \"\$1\" | grep -q 'it broke, for a test'" _ "$output"
check "  what's done is pinned already" has top "org.go:1.2.3@sha256:"
: >"$FAKE_CALLS"
bash "$script" go.json >/dev/null
code=$?
check "running it again finishes" [ "$code" = 0 ]
check "  with the same digests as a run that didn't stop" [ "$(hex_of org.top)" = "$first_top" ]

# An image that has an older build of itself as a source.
fresh
r app org.app 3.0 org.go:1.2.1 org.app:2.9
store=$work/store4
export ZIGSAW_HOME=$store
bash "$script" go.json >/dev/null
check "an older build of itself isn't waited for, and stays" has app "\"org.app:2.9@sha256:$old\""

# A circle.
fresh
r go org.go 1.2.3 org.top:4.0
circle() { ! bash "$script" --plan go.json >/dev/null 2>"$work/err" && grep -q 'in a circle' "$work/err"; }
check "pins that go in a circle are an error" circle

# The real recipes.
unset REBUILD_RECIPES REBUILD_PUBLISHED ZIGSAW_HOME ZIGSAW REBUILD_LOGS
real=$(bash "$script" --plan zig.json | grep -v '^not published')
check "the real recipes have an order" [ -n "$real" ]
check "  in which zig comes before bat" sh -c "printf '%s\n' \"\$1\" | grep -n . | awk -F: '/:zig\$/{z=\$1} /:bat\$/{b=\$1} END{exit !(z && b && z < b)}'" _ "$real"

echo "$failures check(s) failed."
[ "$failures" -eq 0 ]
