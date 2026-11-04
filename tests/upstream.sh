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

# OSV: a stand-in for what sends it the batch, answering from a list, so a row's
# answer depends on what was really asked; and its advisories' records, as files.
export OSV_DIR=$work/osv
mkdir -p "$OSV_DIR/vulns"
export UPSTREAM_OSV=$(url "$OSV_DIR")
export UPSTREAM_OSV_CURL=$work/fake-curl
cat >"$UPSTREAM_OSV_CURL" <<'EOF'
#!/usr/bin/env bash
out= body=
while [ $# -gt 0 ]; do
    case $1 in
    -o) out=$2; shift 2 ;;
    -d) body=${2#@}; shift 2 ;;
    -w | -A | -H) shift 2 ;;
    *) shift ;;
    esac
done
case ${OSV_FAKE:-} in
down) echo "curl: (7) Failed to connect" >&2; exit 7 ;;
http) printf '{"error":"no"}' >"$out"; printf 500; exit 0 ;;
garbled) printf '{"results":[{}]}' >"$out"; printf 200; exit 0 ;;
esac
cp "$body" "$OSV_DIR/sent"
{
    printf '{"results":['
    sep=
    while IFS= read -r q; do
        case $q in '{"queries"'* | ']}') continue ;; esac
        name=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p' <<<"$q")
        version=$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' <<<"$q")
        ids=$(awk -F'\t' -v n="$name" -v v="$version" '$1 == n && $2 == v { print $3 }' "$OSV_DIR/answers")
        printf '%s' "$sep"
        sep=,
        if [ -z "$ids" ]; then
            printf '{}'
        else
            printf '{"vulns":['
            s=
            for id in $ids; do
                printf '%s{"id":"%s","modified":"2026-01-01T00:00:00Z"}' "$s" "$id"
                s=,
            done
            printf ']}'
        fi
    done <"$body"
    printf ']}\n'
} >"$out"
printf 200
EOF
chmod +x "$UPSTREAM_OSV_CURL"

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
recipe lite org.lite https://example.org/lite-3530400.zip
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
printf 'lite-3530400.zip lite-3540100.zip\n' >"$work/pages/lite"

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
lib page $(p lib) lib-{version}.tar.gz osv=https://example.org/lib.git,v{version}
  https://example.org/lib-{version}.tar.gz
sdk page $(p sdk) sdk-{version}.tar.gz osv=Go:example.org/sdk
  https://example.org/sdk-{version}.tar.gz
app page $(p app) app-{version}.tar.gz
  https://example.org/app-{version}.tar.gz
local page $(p local) local-{version}.tar.gz series=0
  https://example.org/local-{version}.tar.gz
held page $(p held) held-{version}.tar.gz osv=https://example.org/held.git,h{version_}
  https://example.org/held-{version}.tar.gz
dev page $(p dev) dev-{version}.tar.gz even exclude=\.9[0-9]\$ osv=https://example.org/dev.git,{version} osv-thin
  https://example.org/dev-{version}.tar.gz
rc page $(p rc) <v>{version}</v> ver=[0-9.]+(RC[0-9]+)?
  https://example.org/rc-{version}.tgz
tagged git $(url "$work/tags.git") R_{version}
  https://example.org/dl/R_{version}/tagged-*.tar.gz
plus page $(p plus) plus-{version}.zip osv=https://example.org/plus.git,{version}
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
lite page $(p lite) lite-{version}.zip series=0 osv=https://example.org/lite.git,version-{sqlite}
  https://example.org/lite-{version}.zip
EOF

# What OSV lists: <name> <tab> <version, or nothing for the name alone> <tab> <IDs>.
# lib: a remote high one under two IDs, CVSS v3; one in v4; one that's local; one with
# no vector; and one that isn't an ID. plus: more than the table shows. held: unknown.
tags_url=$(url "$work/tags.git")
{
    printf 'https://example.org/lib.git\tv1.2.3\tCVE-2026-1 GHSA-aaaa-bbbb-cccc CVE-2026-2 CVE-2026-3 GO-2026-4 @someone\n'
    printf 'https://example.org/lib.git\t\tCVE-2026-1 CVE-2026-2 CVE-2026-3 GO-2026-4 CVE-2020-9\n'
    printf 'https://example.org/lib.git\tv1.2.10\tGHSA-aaaa-bbbb-cccc\n'
    printf 'Go-is-the-ecosystem\t\tx\n'
    printf 'example.org/sdk\t5.0\tPYSEC-2026-5\n'
    printf 'example.org/sdk\t\tPYSEC-2026-5\n'
    printf 'https://example.org/plus.git\t25.0.5.8\tCVE-2026-11 CVE-2026-12 CVE-2026-13 CVE-2026-14 CVE-2026-15 CVE-2026-16 CVE-2026-17 CVE-2026-18\n'
    printf 'https://example.org/plus.git\t\tCVE-2026-11\n'
    printf '%s\tR_2_9_0\tOSV-2026-20\n' "$tags_url"
    printf '%s\tR_2_9_1\t\n' "$tags_url"
    printf '%s\t\tOSV-2026-20\n' "$tags_url"
    printf 'https://example.org/dev.git\t\tOSV-2010-1 OSV-2010-2\n'
    printf 'https://example.org/lite.git\t\tOSV-2011-1\n'
} >"$OSV_DIR/answers"
vuln() { # <id> <vector, or nothing> <aliases, as JSON strings>
    local severity=
    [ -z "$2" ] || severity="\"severity\":[{\"type\":\"CVSS\",\"score\":\"$2\"}],"
    printf '{"id":"%s","summary":"**Bad** @someone [x](http://evil.example)",%s"aliases":[%s],"details":"\\"score\\": \\"CVSS:3.1/AV:N/PR:N/UI:N/C:H\\""}' "$1" "$severity" "$3" >"$OSV_DIR/vulns/$1"
}
vuln CVE-2026-1 'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:N/A:N' '"GHSA-aaaa-bbbb-cccc"'
vuln GHSA-aaaa-bbbb-cccc '' '"CVE-2026-1"'
vuln CVE-2026-2 'CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:N/VI:H/VA:N/SC:N/SI:N/SA:N' ''
vuln CVE-2026-3 'CVSS:3.1/AV:L/AC:H/PR:N/UI:N/S:U/C:H/I:N/A:N' ''
vuln GO-2026-4 '' ''
# PYSEC-2026-5 has no record. A high attack complexity isn't a high impact, and a
# high impact on availability alone isn't data at risk:
for i in 11 12 13 14 15 16 17; do vuln "CVE-2026-$i" 'CVSS:3.1/AV:N/AC:H/PR:N/UI:N/S:U/C:L/I:N/A:N' ''; done
vuln CVE-2026-18 'CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:N/VI:N/VA:H/SC:H/SI:H/SA:H' ''
vuln OSV-2026-20 '' ''

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

sent() { grep -qF -- "$1" "$OSV_DIR/sent"; }
adv() { # <upstream> <text>: its row under Known advisories says that
    awk -v start="| $1 |" '/^## /{ on = ($0 == "## Known advisories") } on && index($0, start) == 1' "$report" | grep -qF -- "$2"
}
check "OSV: a git row is asked by its repository and real tag (2.9.0: R_2_9_0)" sent "{\"version\":\"R_2_9_0\",\"package\":{\"ecosystem\":\"GIT\",\"name\":\"$tags_url\"}}"
check "OSV: and about the newest in its series" sent '"version":"R_2_9_1"'
check "OSV: a page row by its osv= place" sent '{"version":"v1.2.3","package":{"ecosystem":"GIT","name":"https://example.org/lib.git"}}'
check "OSV: an ecosystem's package" sent '{"version":"5.0","package":{"ecosystem":"Go","name":"example.org/sdk"}}'
check "OSV: {version_} has underscores" sent '"version":"h1_0"'
check "OSV: {sqlite} is SQLite's number as a version" sent '"version":"version-3.53.4"'
check "OSV: and for the newest" sent '"version":"version-3.54.1"'
check "OSV: a page row with no osv= isn't asked about" sh -c "! grep -q 'example.org/app' '$OSV_DIR/sent'"
check "advisories come first" sh -c "grep -m1 '^## ' '$report' | grep -q 'Known advisories'"
check "IDs are links" adv lib '[CVE-2026-1](https://osv.dev/vulnerability/CVE-2026-1)'
check "one advisory under two IDs shows once" sh -c "! grep -F '| lib |' '$report' | grep -q 'vulnerability/GHSA-aaaa-bbbb-cccc'"
check "network, no login, no action, data at risk: v3 and v4, not local, and one without a vector" adv lib '| 2, 1 not stated |'
check "what's left at the newest counts an alias of one listed, once" adv lib '| 1 at 1.2.10 |'
check "cleared at the newest" adv tagged '| 0 at 2.9.1 |'
check "an advisory with no record is not stated" adv sdk '| not stated | 0 at 5.0.1 |'
check "  and the report says some couldn't be read" grep -qF "1 advisory record(s) couldn't be read" "$report"
check "neither a high attack complexity nor what only stops a program counts" adv plus '| 0 |'
check "six IDs, then how many more" adv plus 'and 2 more'
check "  all of them in the hidden list" grep -q '^<!-- advisories:.* CVE-2026-18 ' "$report"
check "the most reachable come first" sh -c "awk '/^## Known/{on=1;next} /^## /{on=0} on && /^\\| /' '$report' | sed -n 2p | grep -q '^| lib |'"
check "an ID that doesn't look like one is left out, and counted" grep -qF "1 advisory ID(s) from OSV didn't look like IDs" "$report"
check "nothing from OSV's text reaches the report" sh -c "! grep -qE 'someone|evil|Bad' '$report'"
check "a vector quoted in a record's text doesn't count" adv tagged '| not stated |'
check "none listed where OSV knows little: thin, and says so" in_section "OSV's records are thin here" dev
check "  with how many records it has" row_says dev '| 1.2.0 | 2 |'
check "none listed where OSV knows the place: only with --all, and not proof" in_section "No advisories listed" lite
check "a place OSV has no record of is told apart" in_section "OSV has no record of these" held
check "the summary line counts them" grep -qE 'listed against 4 pinned version\(s\); none listed for 1; 1 where .* too thin .*; 1 it has no record of' "$report"

# When OSV can't be read: nothing about advisories, rather than zeros.
for how in down http garbled; do
    OSV_FAKE=$how bash "$script" >"$work/no-osv.md" 2>/dev/null
    check "OSV $how: the report says it couldn't read it" grep -qF "Advisories couldn't be read this time" "$work/no-osv.md"
    check "OSV $how: and lists nothing as clear" sh -c "! grep -qE 'Known advisories|thin here|^<!-- advisories' '$work/no-osv.md'"
    check "OSV $how: versions are still reported" grep -qF '| lib | 1.2.3 | 1.2.10 |' "$work/no-osv.md"
done

# Advisories new since the last report, for the issue's comment.
printf '<!-- advisories: A-1 B-2 -->\n<!-- advisory aliases: C-3 -->\n' >"$work/old.md"
printf '<!-- advisories: A-1 C-3 D-4 @x -->\r\n<!-- advisory aliases: none -->\n' >"$work/new.md"
new_ones() { bash "$script" --new-advisories "$1" "$2"; }
check "new advisories: only what the old report lacks, aliases counting" sh -c "[ \"\$(bash '$script' --new-advisories '$work/old.md' '$work/new.md')\" = '- [D-4](https://osv.dev/vulnerability/D-4)' ]"
printf '# no list\n' >"$work/first.md"
check "new advisories: a first report, with nothing to compare, says nothing" sh -c "[ -z \"\$(bash '$script' --new-advisories '$work/first.md' '$work/new.md')\" ]"
check "new advisories: a report without any says nothing" sh -c "[ -z \"\$(bash '$script' --new-advisories '$work/old.md' '$work/first.md')\" ]"

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
bad_osv=$work/table4.txt
sed 's|^app page \(.*\)$|app page \1 osv=https://example.org/app.git,v1|; s|^rc page \(.*\)$|rc page \1 osv=nonsense|' "$without_broken" >"$bad_osv"
malformed() { ! coverage "$bad_osv" && grep -q 'app: osv=https://example.org/app.git,v1 needs' "$work/cov.err" && grep -q 'rc: osv=nonsense is neither' "$work/cov.err"; }
check "--coverage: an osv= that can't work fails" malformed

unset UPSTREAM_RECIPES UPSTREAM_PUBLISHED UPSTREAM_TABLE
check "the real table covers the real recipes" bash "$script" --coverage

echo "$failures check(s) failed."
[ "$failures" -eq 0 ]
