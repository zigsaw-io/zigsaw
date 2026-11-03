#!/usr/bin/env bash
# Checks scripts/check-upstream.sh with made-up recipes, pages and repositories,
# all on this machine, so it needs no network and takes seconds; and that the real
# table covers the real recipes. Runs on Linux too, as CI's pins job does.
#
#   tests/upstream.sh

set -u

root=$(cd "$(dirname "$0")/.." && pwd)
script=$root/scripts/check-upstream.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A path as a file:// URL, which native curl and git want with a drive letter.
url() {
    if command -v cygpath >/dev/null; then echo "file:///$(cygpath -m "$1")"; else echo "file://$1"; fi
}

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

recipes=$work/recipes
mkdir -p "$recipes/no-publish" "$work/pages"
export UPSTREAM_RECIPES=$recipes
export UPSTREAM_PUBLISHED=$work/published.txt
export UPSTREAM_TABLE=$work/table.txt
pin=sha256:$(printf 'a%.0s' {1..64})

# recipe <file> <id> <url> [<pinned id>...]
recipe() {
    local file=$1 id=$2 source=$3 sdk= p
    shift 3
    for p in "$@"; do sdk+="\"$p\": \"$p:1@$pin\", "; done
    printf '{ "id": "%s", "version": "1", "command": "a.exe",\n  "sdk": { %s"x": "x:1@%s" },\n  "modules": [{ "name": "m", "sources": [{ "url": "%s", "sha256": "0" }] }] }\n' \
        "$id" "$sdk" "$pin" "$source" >"$recipes/$file.json"
}

# A chain for what rebuilds: lib <- sdk <- app, and an app that's only local.
recipe lib org.lib https://example.org/lib-1.2.3.tar.gz
recipe sdk org.sdk https://example.org/sdk-5.0.tar.gz org.lib
recipe app org.app https://example.org/app-2.0.tar.gz org.sdk
recipe no-publish/local org.local https://example.org/local-7.tar.gz org.sdk
recipe held org.held https://example.org/held-1.0.tar.gz
recipe dev org.dev https://example.org/dev-1.2.0.tar.gz
recipe rc org.rc https://example.org/rc-2.0.0RC1.tgz
recipe tagged org.tagged https://example.org/dl/R_2_9_0/tagged-2.9.0.tar.gz
recipe plus org.plus https://example.org/dl/plus-25.0.5%2B8.zip
recipe twoa org.twoa https://example.org/two-1.0.tar.gz
recipe twob org.twob https://example.org/two-3.0.tar.gz
recipe gone org.gone https://example.org/gone-1.0.tar.gz
recipe withdrawn org.withdrawn https://example.org/withdrawn-1.0.tar.gz
recipe away org.away https://example.org/away-1.0.tar.gz
recipe skipped org.skipped https://example.org/skipped/abc123.tar.gz
recipe latestonly org.latestonly https://example.org/latestonly-3000.zip
printf '# the published ones\nlib.json\nsdk.json\napp.json\n' >"$UPSTREAM_PUBLISHED"

# The pages, with the versions a real page's markup has around them.
printf '<a href="lib-1.2.3.tar.gz">x</a> <a href="lib-1.2.4.tar.gz">x</a>\n<a href="lib-1.2.10.tar.gz">x</a> <a href="lib-1.3.0.tar.gz">x</a> lib-1.4.0rc1.tar.gz\n' >"$work/pages/lib"
printf 'sdk-5.0.tar.gz sdk-5.0.1.tar.gz\n' >"$work/pages/sdk"
printf 'app-2.0.tar.gz\n' >"$work/pages/app"
printf 'local-7.tar.gz local-8.tar.gz\n' >"$work/pages/local"
printf 'held-1.0.tar.gz held-2.0.tar.gz\n' >"$work/pages/held"
printf 'dev-1.2.0.tar.gz dev-1.3.5.tar.gz dev-1.2.90.tar.gz dev-1.4.0.tar.gz\n' >"$work/pages/dev"
printf '<v>2.0.0RC1</v><v>2.0.0</v><v>1.9.0</v>\n' >"$work/pages/rc"
printf 'plus-25.0.5+8.zip plus-25.0.6+1.zip\n' >"$work/pages/plus"
printf 'two-1.0.tar.gz two-1.1.tar.gz two-3.0.tar.gz\n' >"$work/pages/two"
printf 'gone-9.tar.gz\n' >"$work/pages/withdrawn"
printf 'latestonly-3100.zip\n' >"$work/pages/latestonly"

git init -q --bare "$work/tags.git"
git init -q "$work/clone"
(
    cd "$work/clone" || exit 1
    git -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m one
    for tag in R_2_9_0 R_2_9_1 R_2_10_0 R_2_11_0_beta v9.9.9; do git tag "$tag"; done
    git push -q "$work/tags.git" --tags
)

p() { url "$work/pages/$1"; }
cat >"$UPSTREAM_TABLE" <<EOF
# a comment
lib page $(p lib) lib-{version}.tar.gz
  https://example.org/lib-{version}.tar.gz
sdk page $(p sdk) sdk-{version}.tar.gz
  https://example.org/sdk-{version}.tar.gz
app page $(p app) app-{version}.tar.gz
  https://example.org/app-{version}.tar.gz
local page $(p local) local-{version}.tar.gz series=0
  https://example.org/local-{version}.tar.gz
held page $(p held) held-{version}.tar.gz
  https://example.org/held-{version}.tar.gz
dev page $(p dev) dev-{version}.tar.gz even exclude=\.9[0-9]\$
  https://example.org/dev-{version}.tar.gz
rc page $(p rc) <v>{version}</v> ver=[0-9.]+(RC[0-9]+)?
  https://example.org/rc-{version}.tgz
tagged git $(url "$work/tags.git") R_{version}
  https://example.org/dl/R_{version}/tagged-*.tar.gz
plus page $(p plus) plus-{version}.zip
  https://example.org/dl/plus-{version}.zip
two page $(p two) two-{version}.tar.gz
  https://example.org/two-{version}.tar.gz
gone git $(url "$work/no-such.git") v{version}
  https://example.org/gone-{version}.tar.gz
withdrawn page $(p withdrawn) withdrawn-{version}.tar.gz
  https://example.org/withdrawn-{version}.tar.gz
away page https://127.0.0.1:1/ away-{version}.tar.gz
  https://example.org/away-{version}.tar.gz
skipped skip a commit, for a test
  https://example.org/skipped/*
latestonly page $(p latestonly) latestonly-{version}.zip series=0 latest
  https://example.org/latestonly-{version}.zip
EOF

report=$work/report.md
bash "$script" --all >"$report" 2>"$work/report.err"
code=$?

row() { grep -F "| $1 |" "$report"; }
in_section() { # <section> <row's start>: is the row under that heading?
    awk -v section="## $1" -v start="| $2 |" '
        /^## / { on = ($0 == section) }
        on && index($0, start) == 1 { found = 1 }
        END { exit !found }' "$report"
}
row_says() { row "$1" | grep -qF -- "$2"; }

check "a broken row fails the report" [ "$code" = 1 ]
check "the newest in a series, not the highest as text (1.2.10 > 1.2.4)" row_says lib '| 1.2.3 | 1.2.10 | 1.3.0 |'
check "a pre-release (rc1) is left out" sh -c "! grep '^| lib |' '$report' | grep -q '1\.4\.0'"
check "an update within a series is listed under that" in_section "Updates within a series" lib
check "only a newer series is listed under that" in_section "Only a new series" held
check "a current one, only with --all" in_section "Current" app
check "even leaves out 1.3, exclude leaves out 1.2.90" in_section "Only a new series" dev
check "  and 1.4.0 is what's newest" row_says dev '| 1.2.0 | 1.4.0 |'
check "ver= lets a pinned RC be found, and its release sorts after it" row_says rc '| 2.0.0RC1 | 2.0.0 |'
check "tags: separators compare as dots, a beta left out" row_says tagged '| 2.9.0 | 2.9.1 | 2.10.0 |'
check "a pin with %2B in its URL is found" row_says plus '| 25.0.5.8 | 25.0.6.1 |'
check "two pins of one upstream get a row each" sh -c "[ \$(grep -c '^| two |' '$report') = 2 ]"
check "a repository that's gone is broken" in_section "Broken" gone
check "the pinned version missing upstream is broken" in_section "Broken" withdrawn
check "a host that doesn't answer is only unreachable" in_section "Unreachable" away
check "a skip row is listed, with why" row_says skipped 'a commit, for a test'
check "latest: the pin needn't be on the page" row_says latestonly '| 3000 | 3100 |'
check "what rebuilds goes down the pins" row_says lib '4: lib, sdk, app, local (local)'
check "a recipe that isn't published says local" row_says local '1: local (local)'
check "nothing from a page but its versions reaches the report" sh -c "! grep -q 'href' '$report'"

without_broken=$work/table2.txt
awk '/^(gone|withdrawn) /{ skip = 2 } skip > 0 { skip--; next } { print }' "$UPSTREAM_TABLE" >"$without_broken"
rm "$recipes/gone.json" "$recipes/withdrawn.json"
quiet_report() { UPSTREAM_TABLE=$without_broken bash "$script" >"$work/quiet.md" 2>/dev/null; }
check "newer versions and an unreachable host don't fail it" quiet_report
check "without --all, current ones aren't listed" sh -c "! grep -q '^| app |' '$work/quiet.md'"

coverage() { UPSTREAM_TABLE=$1 bash "$script" --coverage >/dev/null 2>"$work/cov.err"; }
check "--coverage: this table covers these recipes" coverage "$without_broken"
recipe newone org.newone https://example.org/newone-1.tar.gz
uncovered() { ! coverage "$without_broken" && grep -q 'no row of the table covers https://example.org/newone-1.tar.gz' "$work/cov.err"; }
check "--coverage: a source with no row fails" uncovered
rm "$recipes/newone.json"
rm "$recipes/held.json"
stale() { ! coverage "$without_broken" && grep -q "held: no recipe has a source like" "$work/cov.err"; }
check "--coverage: a row nothing uses fails" stale
recipe held org.held https://example.org/held-1.0.tar.gz
no_why=$work/table3.txt
sed 's/^skipped skip .*/skipped skip/' "$without_broken" >"$no_why"
unexplained() { ! coverage "$no_why" && grep -q 'skipped without saying why' "$work/cov.err"; }
check "--coverage: a skip without a reason fails" unexplained

unset UPSTREAM_RECIPES UPSTREAM_PUBLISHED UPSTREAM_TABLE
check "the real table covers the real recipes" bash "$script" --coverage

echo "$failures check(s) failed."
[ "$failures" -eq 0 ]
