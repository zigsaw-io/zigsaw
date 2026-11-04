#!/usr/bin/env bash
# Says which of the recipes' sources have newer versions upstream, what advisories
# OSV (osv.dev) lists against the pinned ones, and what each update would rebuild.
# It only reads: nothing is downloaded but tag lists, index pages and OSV's answers,
# and no recipe changes. OSV is sent the table's repositories and versions.
#
#   scripts/check-upstream.sh [--all]    the report, as Markdown, on stdout;
#                                        --all lists the current ones too
#   scripts/check-upstream.sh --coverage just whether scripts/upstream.txt and
#                                        the recipes agree (no network)
#   scripts/check-upstream.sh --new-advisories <old report> <new report>
#                                        the advisories only the new report lists, as
#                                        Markdown; nothing if the old one lists none
#
# It fails if a recipe's source has no row in the table, a row covers no source,
# or a row is broken: it found no versions, the place it looks at is gone, or
# the version a recipe pins isn't among those it found. That last check is what
# shows a row's pattern is right; it also catches a release that was withdrawn.
# A newer version isn't a failure, and neither is a host that doesn't answer,
# which the report lists, nor an advisory, nor OSV not answering.
#
# The table is scripts/upstream.txt, whose top says how to read it. What rebuilds
# is the recipes with the source, and those that pin them, and so on, from the
# "id:version@sha256:..." pins scripts/check-pins.sh reads.
#
# It sees the sources recipes name, so not what those bring along: dependencies
# in Cargo.lock, go.sum or a vendor step, or the libraries in a prebuilt app.
#
# Advisories are OSV's matches for a repository's tag or a package's version, not
# checked against these Windows builds. Of what OSV answers, only advisory IDs that
# look like IDs and what a CVSS vector states reach the report, never its text. A
# version with none listed may just be one OSV knows little about: it lists nothing
# for PHP 8.5.11, whose RCEs iteration 69 moved away from. Rows marked osv-thin say so.
#
# Needs Git Bash (or any bash), curl, git and GNU sort. For the tests:
# UPSTREAM_TABLE, UPSTREAM_RECIPES and UPSTREAM_PUBLISHED replace the table, the
# recipes' directory and the list of published recipes; UPSTREAM_OSV is where OSV's
# API is, and UPSTREAM_OSV_CURL the program that sends it the batch of questions.

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

# What an advisory's ID looks like. Nothing else from OSV gets into a report.
id_re='[A-Za-z]+(-[A-Za-z0-9]+)+'

if [ "${1:-}" = --new-advisories ]; then
    [ $# -eq 3 ] || {
        echo "usage: check-upstream.sh --new-advisories <old report> <new report>" >&2
        exit 2
    }
    # <the list's name> <report>: the IDs in its hidden list, one a line. The table
    # shows only some of a row's, and shows one ID of several for the same advisory.
    hidden_list() {
        tr -d '\r' <"$2" | sed -n "s/^<!-- $1: \(.*\) -->\$/\1/p" | tr ' ' '\n' | grep -xE -- "$id_re"
    }
    # A report without the list, from before there was one or from when OSV couldn't
    # be read, can't be compared with: everything would look new.
    grep -q '^<!-- advisories: ' "$2" || exit 0
    known=$({
        hidden_list advisories "$2"
        hidden_list 'advisory aliases' "$2"
    } | sort -u)
    hidden_list advisories "$3" | sort -u | while IFS= read -r id; do
        if ! grep -qxF -- "$id" <<<"$known"; then
            echo "- [$id](https://osv.dev/vulnerability/$id)"
        fi
    done
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
        if [ "${how:-}" != skip ]; then
            read -ra row_opts <<<"$opts"
            for opt in "${row_opts[@]}"; do
                case $opt in
                osv=https://*,*\{version\}* | osv=https://*,*\{version_\}* | osv=https://*,*\{sqlite\}*) ;;
                osv=https://*) problem "$table: $name: $opt needs <repository>,<tag with {version}, {version_} or {sqlite}>" ;;
                osv=*:*) ;;
                osv=*) problem "$table: $name: $opt is neither <repository>,<tag> nor <ecosystem>:<package>" ;;
                esac
            done
        fi
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
# The versions looked at, as compared, the newest in their series, and what rebuilds.
declare -A k_pinned k_newest k_cell
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
    k_pinned[$key]=$pinned
    k_newest[$key]=$newest_in
    k_cell[$key]=$cell
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

# --- What OSV lists -----------------------------------------------------------

osv=${UPSTREAM_OSV:-https://api.osv.dev/v1}
osv_curl=${UPSTREAM_OSV_CURL:-curl}
osv_problem= # why OSV couldn't be read, if it couldn't

# <n> <row> <version as compared>: REPLY = the tag among the row's fetched tags.
tag_of() {
    local pre suf regex
    pre=${r_pattern[$2]%%\{version\}*}
    suf=${r_pattern[$2]#*\{version\}}
    to_regex "$pre"
    regex=$REPLY${3//./[._+-]}
    to_regex "$suf"
    regex+=$REPLY
    REPLY=$(grep -axE -m1 -- "$regex" "$1.out" | tr -d '\r')
}

# <tag template> <version as compared>: REPLY = the tag.
tag_from() {
    local template=$1 version=$2 sqlite
    case $template in *'{sqlite}'*)
        # SQLite's number for 3.53.4 is 3530400.
        sqlite="${version:0:1}.$((10#${version:1:2})).$((10#${version:3:2}))"
        template=${template//\{sqlite\}/$sqlite}
        ;;
    esac
    template=${template//\{version_\}/${version//./_}}
    REPLY=${template//\{version\}/$version}
}

# The questions, one a line in `queries`, with q_key and q_kind saying whose and
# what about. For each place a row is looked up in: its pinned version, the newest
# in its series if that's another, and the place with no version: has OSV heard of it?
declare -a q_key q_kind
declare -A k_looked k_thin
n_queries=0
ask() { # <key> <kind> <ecosystem> <name> [version]
    local version_part=
    [ $# -lt 5 ] || version_part="\"version\":\"$5\","
    [ "$n_queries" -eq 0 ] || printf ',\n' >>queries
    printf '{%s"package":{"ecosystem":"%s","name":"%s"}}' "$version_part" "$3" "$4" >>queries
    q_key[n_queries]=$1
    q_kind[n_queries]=$2
    n_queries=$((n_queries + 1))
}
: >queries
sorted_keys=$(printf '%s\n' "${!k_pinned[@]}" | sort)
while IFS= read -r key; do
    [ -n "$key" ] || continue
    row=${key%% *}
    pinned=${k_pinned[$key]}
    newest_in=${k_newest[$key]}
    n=${place_n["${r_how[row]} ${r_where[row]}"]}
    spec_list=()
    read -ra row_opts <<<"${r_opts[row]}"
    for opt in "${row_opts[@]}"; do
        case $opt in
        osv=*) spec_list+=("${opt#osv=}") ;;
        osv-thin) k_thin[$key]=1 ;;
        esac
    done
    if [ "${#spec_list[@]}" -eq 0 ] && [ "${r_how[row]}" = git ]; then spec_list=(tags); fi
    for spec in "${spec_list[@]}"; do
        pin_v= new_v=
        case $spec in
        tags)
            ecosystem=GIT name=${r_where[row]}
            tag_of "$n" "$row" "$pinned"
            pin_v=$REPLY
            if [ "$newest_in" != "$pinned" ]; then
                tag_of "$n" "$row" "$newest_in"
                new_v=$REPLY
            fi
            ;;
        https://*)
            ecosystem=GIT name=${spec%%,*}
            tag_from "${spec#*,}" "$pinned"
            pin_v=$REPLY
            if [ "$newest_in" != "$pinned" ]; then
                tag_from "${spec#*,}" "$newest_in"
                new_v=$REPLY
            fi
            ;;
        *)
            ecosystem=${spec%%:*} name=${spec#*:} pin_v=$pinned
            [ "$newest_in" = "$pinned" ] || new_v=$newest_in
            ;;
        esac
        [ -n "$pin_v" ] || continue
        k_looked[$key]=1
        ask "$key" pin "$ecosystem" "$name" "$pin_v"
        ask "$key" known "$ecosystem" "$name"
        [ -z "$new_v" ] || ask "$key" newest "$ecosystem" "$name" "$new_v"
    done
done <<<"$sorted_keys"
{
    printf '{"queries":[\n'
    cat queries
    printf '\n]}\n'
} >queries.json

declare -a a_ids a_more # for each question: the IDs answered, and whether OSV has more
if [ "$n_queries" -gt 0 ]; then
    send() {
        local code got
        code=$("$osv_curl" -sS --compressed --max-time 120 -A 'zigsaw check-upstream' -H 'Content-Type: application/json' \
            -d @queries.json -o answer.json -w '%{http_code}' "$osv/querybatch" 2>osv.err)
        got=$?
        osv_problem=
        if [ "$got" -ne 0 ]; then
            osv_problem="curl says: $(tail -1 osv.err | tr -d '\r|')"
        elif [ "$code" != 200 ]; then
            osv_problem="HTTP $code"
        fi
    }
    send
    if [ -n "$osv_problem" ]; then
        sleep 2
        send
    fi
fi
if [ "$n_queries" -gt 0 ] && [ -z "$osv_problem" ]; then
    # The answer has a result per question, in order: {} or
    # {"vulns":[{"id":"...","modified":"..."},...]}. Anything else gets counted
    # wrong, and then none of it's used, rather than reading as no advisories.
    # An ID that doesn't look like one comes through as "refused".
    grep -aoE '\{ *\}|"vulns"|"id": *"[^"]*"|"next_page_token"' answer.json | awk -v id_re="^$id_re\$" '
        /^\{/ || /^"vulns"/ { i++; next }
        /next_page_token/ { print i, "+"; next }
        {
            sub(/^"id": *"/, "")
            sub(/"$/, "")
            print i, ($0 ~ id_re ? $0 : "refused")
        }
        END { print "count", i + 0 }' >answer.txt
    answered=0
    while read -r i id; do
        case $i/$id in
        count/*) answered=$id ;;
        */+) a_more[i - 1]=1 ;;
        *) a_ids[i - 1]+=" $id" ;;
        esac
    done <answer.txt
    [ "$answered" = "$n_queries" ] || osv_problem="its answer had $answered result(s) for $n_queries question(s)"
fi

# Each advisory's record, for its vector and aliases, eight at a time.
declare -A d_n d_state d_aliases
n_unread=0
# <id>: d_state[id] = what its vectors state: high (over a network, no login, no user
# action, and a high loss of confidentiality or integrity, which leaves out what only
# stops a program), stated (something else), or none. d_aliases[id] too.
read_detail() {
    local id=$1 file="d${d_n[$1]}.out" state=none vector alias aliases= whole_id="^$id_re\$"
    if [ ! -s "$file" ]; then
        n_unread=$((n_unread + 1))
    else
        while IFS= read -r vector; do
            [ "$state" = high ] || state=stated
            if [[ $vector == */AV:N/* && $vector == */PR:N/* && $vector == */UI:N* && $vector =~ /V?[CI]:H ]]; then
                state=high
            fi
        done < <(grep -aoE '"score": *"CVSS:[^"]*"' "$file")
        while IFS= read -r alias; do
            alias=${alias//\"/}
            if [[ $alias =~ $whole_id ]]; then aliases+=" $alias"; fi
        done < <(grep -aoE -m1 '"aliases": *\[[^]]*\]' "$file" | sed 's/^"aliases": *//' | grep -aoE '"[^"]*"')
    fi
    d_state[$id]=$state
    d_aliases[$id]=$aliases
}
if [ "$n_queries" -gt 0 ] && [ -z "$osv_problem" ]; then
    d=0
    : >details
    for ((i = 0; i < n_queries; i++)); do
        [ "${q_kind[i]}" != known ] || continue
        for id in ${a_ids[i]:-}; do
            [ "$id" != refused ] || continue
            if [ -z "${d_n[$id]:-}" ]; then
                d_n[$id]=$d
                printf '%s\0%s\0%s\0' page "$osv/vulns/$id" "d$d" >>details
                d=$((d + 1))
            fi
        done
    done
    [ ! -s details ] || xargs -0 -P 8 -n 3 bash "$root/scripts/check-upstream.sh" --fetch <details
    for id in "${!d_n[@]}"; do read_detail "$id"; done
fi

advisories=$tmp/advisories
none_listed=$tmp/none-listed
no_record=$tmp/no-record
thin=$tmp/thin
: >"$advisories" >"$none_listed" >"$no_record" >"$thin"
all_ids=
all_aliases=
n_refused=0
n_not_looked=0
if [ -z "$osv_problem" ]; then
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        row=${key%% *}
        label=${r_name[row]}
        pinned=${k_pinned[$key]}
        newest_in=${k_newest[$key]}
        cell=${k_cell[$key]}
        if [ -z "${k_looked[$key]:-}" ]; then
            n_not_looked=$((n_not_looked + 1))
            continue
        fi
        ids=
        new_ids=
        more=
        records=0
        for ((i = 0; i < n_queries; i++)); do
            [ "${q_key[i]}" = "$key" ] || continue
            case ${q_kind[i]} in
            pin)
                ids+=" ${a_ids[i]:-}"
                [ -z "${a_more[i]:-}" ] || more=1
                ;;
            newest) new_ids+=" ${a_ids[i]:-}" ;;
            known)
                set -- ${a_ids[i]:-}
                [ "$#" -le "$records" ] || records=$#
                ;;
            esac
        done
        # One advisory under several IDs counts once: canon says which it's shown as.
        declare -A canon=() state=()
        kept=
        for id in $(printf '%s\n' $ids | sort -u); do
            if [ "$id" = refused ]; then
                n_refused=$((n_refused + 1))
                continue
            fi
            first=${canon[$id]:-}
            for alias in ${d_aliases[$id]:-}; do
                [ -n "$first" ] || first=${canon[$alias]:-}
            done
            if [ -z "$first" ]; then
                first=$id
                kept+=" $id"
            fi
            canon[$id]=$first
            for alias in ${d_aliases[$id]:-}; do
                canon[$alias]=$first
                all_aliases+=" $alias"
            done
            case ${d_state[$id]:-none}/${state[$first]:-none} in
            high/* | */high) state[$first]=high ;;
            stated/* | */stated) state[$first]=stated ;;
            *) state[$first]=none ;;
            esac
        done
        if [ -z "$kept" ]; then
            if [ "$records" -eq 0 ]; then
                echo "| $label | $pinned | $cell |" >>"$no_record"
            elif [ -n "${k_thin[$key]:-}" ]; then
                echo "| $label | $pinned | $records | $cell |" >>"$thin"
            else
                echo "| $label | $pinned | $records | $cell |" >>"$none_listed"
            fi
            continue
        fi
        total=0 high=0 unstated=0 shown=
        for id in $kept; do
            total=$((total + 1))
            all_ids+=" $id"
            [ "$total" -gt 6 ] || shown+="${shown:+, }[$id](https://osv.dev/vulnerability/$id)"
            case ${state[$id]} in
            high) high=$((high + 1)) ;;
            none) unstated=$((unstated + 1)) ;;
            esac
        done
        [ "$total" -le 6 ] || shown+=", and $((total - 6)) more"
        [ -z "$more" ] || shown+=", and OSV has more"
        if [ "$unstated" -eq "$total" ]; then
            reach="not stated"
        elif [ "$unstated" -gt 0 ]; then
            reach="$high, $unstated not stated"
        else
            reach=$high
        fi
        if [ "$newest_in" = "$pinned" ]; then
            left="no newer version in its series"
        else
            declare -A left_seen=()
            left_count=0
            for id in $new_ids; do
                [ "$id" != refused ] || continue
                one=${canon[$id]:-}
                for alias in ${d_aliases[$id]:-}; do
                    [ -n "$one" ] || one=${canon[$alias]:-}
                done
                [ -n "$one" ] || one=$id
                if [ -z "${left_seen[$one]:-}" ]; then
                    left_seen[$one]=1
                    left_count=$((left_count + 1))
                fi
            done
            left="$left_count at $newest_in"
        fi
        printf '%s\t%s\t| %s | %s | %s | %s | %s | %s |\n' "$high" "$total" "$label" "$pinned" "$shown" "$reach" "$left" "$cell" >>"$advisories"
    done <<<"$sorted_keys"
fi

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
n_advisories=$(count "$advisories")
n_none=$(count "$none_listed")
n_thin=$(count "$thin")
n_no_record=$(count "$no_record")

echo "# What's out of date upstream"
echo
echo "Checked $(date -u +%F) by \`scripts/check-upstream.sh\`, against the sources recipes name: $n_series behind within their series, $n_new with only a new series, $n_current current, $skipped not checked, $n_unreachable unreachable, $n_broken broken."
echo
echo "Dependencies a source brings along (Cargo.lock, go.sum, a vendor step, what's inside a prebuilt app) aren't seen. Rebuilds count the recipes with the source and what pins them; *(local)* isn't published."
echo
if [ -n "$osv_problem" ]; then
    echo "**Advisories couldn't be read this time**, so this report says nothing about them. OSV: $osv_problem."
else
    echo "Advisories, from [OSV](https://osv.dev): listed against $n_advisories pinned version(s); none listed for $n_none; $n_thin where OSV's records are too thin to go by; $n_no_record it has no record of; $((skipped + n_not_looked)) not looked up."
fi
if [ -s "$advisories" ]; then
    printf '\n## Known advisories\n\n'
    # All of them, as the table shows some. See --new-advisories.
    echo "<!-- advisories:$all_ids -->"
    echo "<!-- advisory aliases:${all_aliases:- none} -->"
    printf "\nThese are OSV's matches for each version, not checked against these Windows builds, so some won't apply. The fourth column counts those whose CVSS vector says: over a network, no login, no user action, and a high loss of confidentiality or integrity, so not what only stops a program; \"not stated\" means there's no vector.\n\n"
    printf '| upstream | pinned | advisories | network, no login, no action, data at risk | left at the newest in its series | rebuilds |\n|---|---|---|---|---|---|\n'
    sort -t$'\t' -k1,1nr -k2,2nr -k3,3 "$advisories" | cut -f3
    if [ "$n_refused" -gt 0 ]; then printf "\n%s advisory ID(s) from OSV didn't look like IDs, and were left out.\n" "$n_refused"; fi
    if [ "$n_unread" -gt 0 ]; then printf "\n%s advisory record(s) couldn't be read, and count as not stated.\n" "$n_unread"; fi
fi
if [ -s "$thin" ]; then
    printf "\n## OSV's records are thin here\n\nNone listed, but it lists about as little for older releases with known problems, so that says nothing: read the project's own notices.\n\n| upstream | pinned | records OSV has for it | rebuilds |\n|---|---|---|---|\n"
    sort "$thin"
fi
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
if $all && [ -s "$none_listed" ]; then
    printf '\n## No advisories listed\n\nNot proof there are none.\n\n| upstream | pinned | records OSV has for it | rebuilds |\n|---|---|---|---|\n'
    sort "$none_listed"
fi
if $all && [ -s "$no_record" ]; then
    printf '\n## OSV has no record of these\n\n| upstream | pinned | rebuilds |\n|---|---|---|\n'
    sort "$no_record"
fi

[ "$n_broken" -eq 0 ] && [ "$problems" -eq 0 ]
