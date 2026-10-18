#!/usr/bin/env bash
# Checks that the registry has what the published recipes pin: each image a
# recipe names by digest ("org.gtk.Gtk4:4.24.1@sha256:...", as a runtime, an
# SDK or an image source), and each recipe's own version, by tag. Something
# missing means a fresh store can't build a recipe that pins it, which the
# Reproduce workflow can't see for recipes it skips.
#
#   scripts/check-pins.sh [recipe.json...]   (default: those in published-recipes.txt)
#
# It fails if anything is missing. It warns about a runtime pin that isn't
# what its tag points to now: an app on an older build of a runtime than the
# one published under the same version, so a store with it and the runtime's
# other apps deploys the runtime twice. Older SDK pins don't warn.
#
# The registry is the default one (ghcr.io/zigsaw-io) or ZIGSAW_REGISTRY's,
# read anonymously. Needs curl and Git Bash, not zigsaw.

set -eu
export MSYS_NO_PATHCONV=1

root=$(cd "$(dirname "$0")/.." && pwd)
registry=${ZIGSAW_REGISTRY:-ghcr.io/zigsaw-io}
registry=${registry%/}
case $registry in
http://*) scheme=http; registry=${registry#http://} ;;
https://*) scheme=https; registry=${registry#https://} ;;
*) scheme=https ;;
esac
host=${registry%%/*}
namespace=
case $registry in */*) namespace=${registry#*/}/ ;; esac
# As zigsaw itself: plain HTTP for this machine only.
case $host in localhost | localhost:* | 127.0.0.1 | 127.0.0.1:* | "[::1]" | "[::1]:"*) scheme=http ;; esac

if [ $# -eq 0 ]; then
    for name in $(grep -v '^#' "$root/scripts/published-recipes.txt" | tr -d '\r'); do set -- "$@" "$root/recipes/$name"; done
fi

accept='application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json'
declare -A tokens

# head_manifest <repository> <tag or digest>: sets `found` to the manifest's
# digest, or to nothing if the registry hasn't got it. Asks for a pull token
# when the registry wants one, once per repository (so it mustn't run in a
# subshell, which would forget the token).
head_manifest() {
    found=
    local repo=$1 ref=$2 url headers status challenge realm service
    url="$scheme://$host/v2/$repo/manifests/$ref"
    local auth=()
    [ -n "${tokens[$repo]:-}" ] && auth=(-H "Authorization: Bearer ${tokens[$repo]}")
    headers=$(curl -sS -I -H "Accept: $accept" "${auth[@]}" "$url" | tr -d '\r')
    status=$(sed -n '1s/^HTTP[^ ]* \([0-9]*\).*/\1/p' <<<"$headers")
    if [ "$status" = 401 ] && [ -z "${tokens[$repo]:-}" ]; then
        challenge=$(grep -i '^www-authenticate:' <<<"$headers" || true)
        # Only a token can be had anonymously; a registry that wants a
        # password (Basic) hasn't got the image for everyone.
        grep -qi '^www-authenticate: *bearer ' <<<"$challenge" || return 0
        realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$challenge")
        service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$challenge")
        [ -n "$realm" ] || { echo "error: $host refused $url without saying how to log in" >&2; exit 1; }
        tokens[$repo]=$(curl -sS -G "$realm" --data-urlencode "service=$service" --data-urlencode "scope=repository:$repo:pull" |
            sed -n 's/.*"\(token\|access_token\)": *"\([^"]*\)".*/\2/p')
        [ -n "${tokens[$repo]}" ] || tokens[$repo]=none
        head_manifest "$repo" "$ref"
        return
    fi
    case $status in
    200) found=$(grep -i '^docker-content-digest:' <<<"$headers" | sed 's/^[^:]*: *//') ;;
    401 | 403 | 404) ;; # ghcr.io answers a private or missing package with 401 or 403
    *)
        echo "error: $url: HTTP ${status:-no answer}" >&2
        exit 1
        ;;
    esac
}

repo_of() { echo "$namespace$1" | tr '[:upper:]' '[:lower:]'; }
short() { echo "${1#sha256:}" | cut -c1-8; }

declare -A tag_digest have_digest
# tag <id> <version>: sets `now` to the digest the tag points to now, looked
# up once.
tag() {
    local key="$1:$2"
    if [ -z "${tag_digest[$key]+x}" ]; then
        head_manifest "$(repo_of "$1")" "$2"
        tag_digest[$key]=$found
    fi
    now=${tag_digest[$key]}
}

# The script runs itself for the tags below: `--tag <id> <version>` prints
# "<id> <version> <digest>", the digest empty if there's no such tag.
if [ "${1:-}" = --tag ]; then
    head_manifest "$(repo_of "$2")" "$3"
    echo "$2 $3 $found"
    exit 0
fi

field() { grep -o "\"$1\": *\"[^\"]*\"" "$2" | head -1 | cut -d'"' -f4; }
pin_re='"[A-Za-z0-9_.-]*:[^"@ ]*@sha256:[0-9a-f]\{64\}"'

# Every tag the checks need, looked up eight at a time: a request takes about
# a second here, most of it TLS, and there are about a hundred. What these
# lookups miss, tag() looks up again on its own.
while read -r tid tversion tdigest; do tag_digest[$tid:$tversion]=$tdigest; done < <(
    for recipe in "$@"; do
        echo "$(field id "$recipe") $(field version "$recipe")"
        grep -o "$pin_re" "$recipe" | tr -d '"' | sed 's/@.*//; s/:/ /'
    done | sort -u | xargs -P 8 -n 2 bash "$0" --tag
)

missing=0
older=0
pins=0
for recipe in "$@"; do
    name=${recipe##*/recipes/}
    id=$(field id "$recipe")
    version=$(field version "$recipe")
    tag "$id" "$version"
    if [ -z "$now" ]; then
        echo "missing: $id:$version, which $name makes, isn't published (or not publicly)"
        missing=$((missing + 1))
    fi
    # The pins in the recipe's "runtimes" (one object, no "}" inside), which
    # an install brings along: only these warn when older than their tag. An
    # older SDK is the recipe's business and costs nothing at run time.
    runtime_pins=$(awk '/"runtimes": *\{/ { on = 1 } on { print } on && /\}/ { exit }' "$recipe" |
        grep -o "$pin_re" | tr -d '"' || true)
    for pin in $(grep -o "$pin_re" "$recipe" | tr -d '"' | sort -u); do
        pins=$((pins + 1))
        ref=${pin%%@*}
        digest=${pin#*@}
        pid=${ref%%:*}
        pversion=${ref#*:}
        # The tag first: it's looked up once for every recipe that pins the
        # same version, and if it points to the pin, the pin is there.
        tag "$pid" "$pversion"
        if [ "$now" != "$digest" ] && [ -z "${have_digest[$pid@$digest]+x}" ]; then
            head_manifest "$(repo_of "$pid")" "$digest"
            have_digest[$pid@$digest]=$found
        fi
        if [ "$now" != "$digest" ] && [ -z "${have_digest[$pid@$digest]}" ]; then
            echo "missing: $name pins $ref@$(short "$digest"), which $registry hasn't got (or not publicly)"
            missing=$((missing + 1))
            continue
        fi
        grep -qxF "$pin" <<<"$runtime_pins" || continue
        if [ -z "$now" ]; then
            echo "warning: $name's runtime $ref@$(short "$digest") is on $registry, but no tag $pversion is"
        elif [ "$now" != "$digest" ]; then
            echo "warning: $name pins an older runtime $ref (@$(short "$digest"); the tag is @$(short "$now"))"
            older=$((older + 1))
        fi
    done
done

echo "$# recipe(s), $pins pin(s): $missing missing, $older older runtime(s)"
[ "$missing" -eq 0 ]
