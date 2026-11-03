#!/usr/bin/env bash
# Says which of the recipes' sources have newer versions upstream, and what
# each update would rebuild. It only reads: nothing is downloaded but tag lists
# and index pages, and no recipe changes.
#
#   scripts/check-upstream.sh [--all]    the report, as Markdown, on stdout;
#                                        --all lists the current ones too
#   scripts/check-upstream.sh --coverage just whether scripts/upstream.txt and
#                                        the recipes agree (no network)
#
# It fails if a recipe's source has no row in the table, a row covers no source,
# or a row is broken: it found no versions, the place it looks at is gone, or
# the version a recipe pins isn't among those it found. That last check is what
# shows a row's pattern is right; it also catches a release that was withdrawn.
# A newer version isn't a failure, and neither is a host that doesn't answer,
# which the report lists.
#
# The table is scripts/upstream.txt, whose top says how to read it. What rebuilds
# is the recipes with the source, and those that pin them, and so on, from the
# "id:version@sha256:..." pins scripts/check-pins.sh reads.
#
# It sees the sources recipes name, so not what those bring along: dependencies
# in Cargo.lock, go.sum or a vendor step, or the libraries in a prebuilt app. A
# version says nothing about advisories.
#
# Needs Git Bash (or any bash), curl, git and GNU sort. For the tests:
# UPSTREAM_TABLE, UPSTREAM_RECIPES and UPSTREAM_PUBLISHED replace the table, the
# recipes' directory and the list of published recipes.

set -u
export LC_ALL=C
export GIT_TERMINAL_PROMPT=0

# Fetches one place into "<n>.out" in the current directory, with "<n>.status"
# saying how it went: ok, gone (it isn't there any more), or unreachable (it may
# be back tomorrow), and why.
if [ "${1:-}" = --fetch ]; then
    how=$2 where=$3 n=$4
    try() {
        case $how in
        git)
            # A missing repository asks for a password at some hosts: no
            # helper and no prompt make that an error.
            if git -c credential.helper= ls-remote --tags --refs "$where" 2>"$n.err" | sed 's#^[^\t]*\trefs/tags/##' >"$n.out" &&
                [ "${PIPESTATUS[0]}" -eq 0 ]; then
                echo ok >"$n.status"
            elif grep -qiE 'not found|does not exist|does not appear' "$n.err"; then
                echo "gone git says: $(head -1 "$n.err" | tr -d '\r')" >"$n.status"
            else
                echo "unreachable git says: $(head -1 "$n.err" | tr -d '\r')" >"$n.status"
            fi
            ;;
        page)
            local code
            code=$(curl -sSL --compressed --max-time 60 -A 'zigsaw check-upstream' -o "$n.out" -w '%{http_code}' "$where" 2>"$n.err")
            local got=$?
            if [ "$got" -ne 0 ]; then
                echo "unreachable curl says: $(tail -1 "$n.err" | tr -d '\r')" >"$n.status"
            else
                case $code in
                200 | 000) echo ok >"$n.status" ;; # 000: a file:// URL
                404 | 410) echo "gone HTTP $code" >"$n.status" ;;
                *) echo "unreachable HTTP $code" >"$n.status" ;;
                esac
            fi
            ;;
        esac
    }
    try
    case $(cat "$n.status") in unreachable*) sleep 2 && try ;; esac
    exit 0
fi

mode=report
all=false
for arg in "$@"; do
    case $arg in
    --coverage) mode=coverage ;;
    --all) all=true ;;
    *)
        echo "usage: check-upstream.sh [--all | --coverage]" >&2
        exit 2
        ;;
    esac
done

root=$(cd "$(dirname "$0")/.." && pwd)
table=${UPSTREAM_TABLE:-$root/scripts/upstream.txt}
recipes_dir=${UPSTREAM_RECIPES:-$root/recipes}
published=${UPSTREAM_PUBLISHED:-$root/scripts/published-recipes.txt}

problems=0
problem() {
    echo "error: $1" >&2
    problems=$((problems + 1))
}

# A text as a regular expression that matches it literally, but for `*` when
# `$2` gives what it stands for, and `{version}` as `$3`.
to_regex() {
    local text=$1 star=${2:-} version=${3:-} out= c i
    text=${text//\{version\}/$'\001'}
    for ((i = 0; i < ${#text}; i++)); do
        c=${text:i:1}
        case $c in
        $'\001') out+=$version ;;
        '*') if [ -n "$star" ]; then out+=$star; else out+='\*'; fi ;;
        '\' | '.' | '+' | '?' | '(' | ')' | '[' | ']' | '{' | '}' | '^' | '$' | '|') out+="\\$c" ;;
        *) out+=$c ;;
        esac
    done
    REPLY=$out
}

# The table.
declare -a r_name r_how r_where r_pattern r_opts s_row s_text s_re s_used
rows=0
sources=0
while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in '' | '#'*) continue ;; esac
    case $line in
    ' '*)
        text=${line#"${line%%[! ]*}"}
        if [ "$rows" -eq 0 ]; then
            problem "$table: \"$text\" comes before any row"
            continue
        fi
        # `{version}` once captures; another one in the same URL only matches.
        first=${text%%\{version\}*}
        if [ "$first" = "$text" ]; then
            [ "${r_how[rows - 1]}" = skip ] || problem "$table: $text has no {version}, and ${r_name[rows - 1]} isn't a skip row"
            to_regex "$text" '.*'
            regex=$REPLY
        else
            to_regex "$first" '.*'
            regex="$REPLY([^/]*)"
            to_regex "${text#*\{version\}}" '.*' '[^/]*'
            regex+=$REPLY
        fi
        s_row[sources]=$((rows - 1))
        s_text[sources]=$text
        s_re[sources]="^$regex\$"
        s_used[sources]=0
        sources=$((sources + 1))
        ;;
    *)
        read -r name how rest <<<"$line"
        case ${how:-} in
        git | page)
            read -r where pattern opts <<<"$rest"
            if [ -z "${where:-}" ] || [ "${pattern#*\{version\}}" = "${pattern:-}" ]; then
                problem "$table: $name needs a place to look and a pattern with {version}"
            fi
            ;;
        skip)
            where= pattern= opts=$rest
            [ -n "$opts" ] || problem "$table: $name is skipped without saying why"
            ;;
        *)
            problem "$table: $name: \"${how:-}\" isn't git, page or skip"
            where= pattern= opts=
            ;;
        esac
        r_name[rows]=$name
        r_how[rows]=${how:-}
        r_where[rows]=${where:-}
        r_pattern[rows]=${pattern:-}
        r_opts[rows]=$opts
        rows=$((rows + 1))
        ;;
    esac
done <"$table"

# The recipes' sources and pins, read relative to their directory.
shopt -s nullglob
cd "$recipes_dir" || exit 2
recipe_files=(*.json no-publish/*.json)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

declare -A recipe_id consumers is_published
for recipe in "${recipe_files[@]}"; do
    id=$(grep -o '"id": *"[^"]*"' "$recipe" | head -1 | cut -d'"' -f4)
    recipe_id[${recipe%.json}]=$id
done
if [ -f "$published" ]; then
    while IFS= read -r name; do
        name=${name%$'\r'}
        case $name in '' | '#'*) continue ;; esac
        is_published[${name%.json}]=1
    done <"$published"
fi
while IFS=: read -r recipe pinned_id _; do
    consumers[$pinned_id]+=" ${recipe%.json}"
done < <(grep -oH '"[A-Za-z0-9_.-]*:[^"@ ]*@sha256:[0-9a-f]\{64\}"' "${recipe_files[@]}" | tr -d '"')

# <recipe>...: them, those that pin them, and so on, in REPLY.
rebuilds_of() {
    local -A seen=()
    local -a todo=("$@") order=()
    local recipe next
    while [ "${#todo[@]}" -gt 0 ]; do
        recipe=${todo[0]}
        todo=("${todo[@]:1}")
        [ -z "${seen[$recipe]:-}" ] || continue
        seen[$recipe]=1
        order+=("$recipe")
        for next in ${consumers[${recipe_id[$recipe]:-}]:-}; do
            [ -n "${seen[$next]:-}" ] || todo+=("$next")
        done
    done
    REPLY=${order[*]}
}

# Every URL, with the row that covers it: the first one.
declare -A found # "<row> <version>" -> the recipes with it
while IFS= read -r hit; do
    recipe=${hit%%:*}
    url=${hit#*:}
    url=${url#\"url\"}
    url=${url#:}
    url=${url# }
    url=${url#\"}
    url=${url%\"}
    covered=false
    for ((j = 0; j < sources; j++)); do
        if [[ $url =~ ${s_re[j]} ]]; then
            covered=true
            s_used[j]=1
            row=${s_row[j]}
            version=${BASH_REMATCH[1]:-}
            version=${version//%2B/+}
            key="$row $version"
            case " ${found[$key]:-} " in
            *" ${recipe%.json} "*) ;;
            *) found[$key]+=" ${recipe%.json}" ;;
            esac
            break
        fi
    done
    $covered || problem "$recipe: no row of the table covers $url"
done < <(grep -oH '"url": *"[^"]*"' "${recipe_files[@]}")

for ((j = 0; j < sources; j++)); do
    [ "${s_used[j]}" = 1 ] || problem "the table's ${r_name[s_row[j]]}: no recipe has a source like ${s_text[j]}"
done
declare -A has_source
for ((j = 0; j < sources; j++)); do has_source[${s_row[j]}]=1; done
for ((i = 0; i < rows; i++)); do
    [ -n "${has_source[$i]:-}" ] || problem "the table's ${r_name[i]} names no source"
done

if [ "$mode" = coverage ]; then
    echo "$rows row(s) cover the sources of ${#recipe_files[@]} recipe(s); $problems problem(s)"
    [ "$problems" -eq 0 ]
    exit
fi

# Fetch each place once, eight at a time.
cd "$tmp" || exit 2
declare -A place_n
places=0
: >places
for ((i = 0; i < rows; i++)); do
    [ "${r_how[i]}" != skip ] || continue
    key="${r_how[i]} ${r_where[i]}"
    if [ -z "${place_n[$key]:-}" ]; then
        place_n[$key]=$places
        printf '%s\0%s\0%s\0' "${r_how[i]}" "${r_where[i]}" "$places" >>places
        places=$((places + 1))
    fi
done
xargs -0 -P 8 -n 3 bash "$root/scripts/check-upstream.sh" --fetch <places

# A version as compared: one separator, and a pre-release before its release.
normal() {
    REPLY=${1//_/.}
    REPLY=${REPLY//-/.}
    REPLY=${REPLY//+/.}
}

# <n> <row>: the row's versions, normalized, oldest first, one a line. `even`
# leaves out odd minor versions, once GNOME's development series.
versions_of() {
    local n=$1 row=$2 opt ver='[0-9]+([._+-][0-9]+)*' even=false pre suf exclude='^$'
    local -a opts
    # Not a plain `for`: a regex would be taken for a file name, and be gone.
    read -ra opts <<<"${r_opts[row]}"
    for opt in "${opts[@]}"; do
        case $opt in
        ver=*) ver=${opt#ver=} ;;
        exclude=*) exclude=${opt#exclude=} ;;
        even) even=true ;;
        esac
    done
    pre=${r_pattern[row]%%\{version\}*}
    suf=${r_pattern[row]#*\{version\}}
    to_regex "$pre"
    local regex=$REPLY
    to_regex "$suf"
    regex+="($ver)$REPLY"
    local flags=-aoE
    [ "${r_how[row]}" = git ] && flags=-axE
    grep "$flags" -- "$regex" "$n.out" | while IFS= read -r m; do
        m=${m%$'\r'}
        m=${m#"$pre"}
        m=${m%"$suf"}
        normal "$m"
        m=$REPLY
        if $even; then
            local rest=${m#*.}
            local minor=${rest%%.*}
            case $minor in *[13579]) continue ;; esac
        fi
        echo "$m"
        # Sorting, a release comes after its pre-releases: each line becomes
        # "<key><tab><version>", at one sed for the lot, as a repository can
        # have thousands of tags.
    done | grep -vE -- "$exclude" | sed -E 'h; s/([0-9])(rc|RC|alpha|beta|a|b)/\1~\2/; G; s/\n/\t/' | sort -t$'\t' -k1,1V -u | cut -f2
}

# <version> <n components>: REPLY = the series, or nothing with n = 0.
series_of() {
    local rest=$1. n=$2 out= i
    for ((i = 0; i < n; i++)); do
        out+=${rest%%.*}.
        rest=${rest#*.}
        [ -n "$rest" ] || break
    done
    REPLY=$out
}

# The cells for "what rebuilds": up to six names, then how many more.
rebuild_cell() {
    local key=$1 count=0 out= recipe
    rebuilds_of ${found[$key]}
    for recipe in $REPLY; do
        count=$((count + 1))
        if [ "$count" -le 6 ]; then
            local shown=${recipe#no-publish/}
            [ -n "${is_published[$recipe]:-}" ] || shown+=" (local)"
            out+="${out:+, }$shown"
        fi
    done
    [ "$count" -le 6 ] || out+=", and $((count - 6)) more"
    REPLY="$count: $out"
}

in_series=$tmp/in-series
new_series=$tmp/new-series
current=$tmp/current
unreachable=$tmp/unreachable
broken=$tmp/broken
: >"$in_series" >"$new_series" >"$current" >"$unreachable" >"$broken"
checked=0
for key in "${!found[@]}"; do
    row=${key%% *}
    pinned=${key#* }
    [ "${r_how[row]}" != skip ] || continue
    name=${r_name[row]}
    n=${place_n["${r_how[row]} ${r_where[row]}"]}
    read -r status detail <"$n.status" || status=unreachable
    label=$name
    # Upstreams pinned at more than one version get a row for each.
    case $status in
    unreachable)
        echo "| $label | $pinned | ${detail//|/\\|} |" >>"$unreachable"
        continue
        ;;
    gone)
        echo "| $label | $pinned | ${r_where[row]} is gone: ${detail//|/\\|} |" >>"$broken"
        continue
        ;;
    esac
    checked=$((checked + 1))
    versions_of "$n" "$row" >"$key.versions" 2>/dev/null
    normal "$pinned"
    pinned=$REPLY
    if [ ! -s "$key.versions" ]; then
        echo "| $label | $pinned | ${r_where[row]} has no version like ${r_pattern[row]} |" >>"$broken"
        continue
    fi
    series=2
    only_latest=false
    read -ra row_opts <<<"${r_opts[row]}"
    for opt in "${row_opts[@]}"; do
        case $opt in
        series=*) series=${opt#series=} ;;
        latest) only_latest=true ;;
        esac
    done
    if ! grep -qxF -- "$pinned" "$key.versions"; then
        if ! $only_latest; then
            echo "| $label | $pinned | ${r_where[row]} has no such version (its newest: $(tail -1 "$key.versions")) |" >>"$broken"
            continue
        fi
        # A page with only the newest version can't show the pin is right.
        { echo "$pinned"; cat "$key.versions"; } | sort -V -u >"$key.with-pin"
        mv "$key.with-pin" "$key.versions"
    fi
    newest=$(tail -1 "$key.versions")
    if [ "$series" -eq 0 ]; then
        newest_in=$newest
    else
        series_of "$pinned" "$series"
        prefix=$REPLY
        newest_in=$(grep -F -- "$prefix" "$key.versions" | while IFS= read -r v; do
            case $v. in "$prefix"*) echo "$v" ;; esac
        done | tail -1)
        [ -n "$newest_in" ] || newest_in=$pinned
    fi
    rebuild_cell "$key"
    cell=$REPLY
    if [ "$newest_in" != "$pinned" ]; then
        other=
        [ "$newest" = "$newest_in" ] || other=$newest
        echo "| $label | $pinned | $newest_in | $other | $cell |" >>"$in_series"
    elif [ "$newest" != "$pinned" ]; then
        echo "| $label | $pinned | $newest | $cell |" >>"$new_series"
    else
        echo "| $label | $pinned | $cell |" >>"$current"
    fi
done

skipped=0
skip_lines=
for ((i = 0; i < rows; i++)); do
    [ "${r_how[i]}" = skip ] || continue
    skipped=$((skipped + 1))
    skip_lines+="| ${r_name[i]} | ${r_opts[i]} |"$'\n'
done

count() { wc -l <"$1" | tr -d ' '; }
n_series=$(count "$in_series")
n_new=$(count "$new_series")
n_current=$(count "$current")
n_unreachable=$(count "$unreachable")
n_broken=$(count "$broken")

echo "# What's out of date upstream"
echo
echo "Checked $(date -u +%F) by \`scripts/check-upstream.sh\`, against the sources recipes name: $n_series behind within their series, $n_new with only a new series, $n_current current, $skipped not checked, $n_unreachable unreachable, $n_broken broken."
echo
echo "Dependencies a source brings along (Cargo.lock, go.sum, a vendor step, what's inside a prebuilt app) aren't seen, and versions say nothing about advisories. Rebuilds count the recipes with the source and what pins them; *(local)* isn't published."
if [ -s "$broken" ]; then
    printf '\n## Broken\n\nThe table needs fixing, or the release is gone.\n\n| upstream | pinned | what happened |\n|---|---|---|\n'
    sort "$broken"
fi
if [ -s "$in_series" ]; then
    printf '\n## Updates within a series\n\n| upstream | pinned | newest in its series | a newer series | rebuilds |\n|---|---|---|---|---|\n'
    sort "$in_series"
fi
if [ -s "$new_series" ]; then
    printf '\n## Only a new series\n\n| upstream | pinned | newest | rebuilds |\n|---|---|---|---|\n'
    sort "$new_series"
fi
if [ -s "$unreachable" ]; then
    printf '\n## Unreachable\n\nNot known this time.\n\n| upstream | pinned | what happened |\n|---|---|---|\n'
    sort "$unreachable"
fi
if $all && [ -s "$current" ]; then
    printf '\n## Current\n\n| upstream | pinned | rebuilds |\n|---|---|---|\n'
    sort "$current"
fi
if $all && [ -n "$skip_lines" ]; then
    printf '\n## Not checked\n\n| upstream | why |\n|---|---|\n'
    printf '%s' "$skip_lines" | sort
fi

[ "$n_broken" -eq 0 ] && [ "$problems" -eq 0 ]
