#!/usr/bin/env bash
# Checks that the published images are what the recipes build. For every
# recipe listed in scripts/published-recipes.txt, it builds the recipe, then
# pulls the image tagged with the recipe's version, anonymously and by app id,
# from the default registry (or ZIGSAW_REGISTRY):
# - The image must have the digest of the build. If it doesn't, either the
#   build isn't reproducible, or the recipe changed without a new version.
# - A version that isn't published yet is reported, but isn't a failure:
#   publishing is manual (scripts/publish.sh).
# - An image built with a host toolchain (MSVC) isn't compared, since it isn't
#   expected to match a build elsewhere.
# - The pulled app must run (a web server, such as Kanboard's, must serve
#   its login page), `latest` must be the same image, and the app must then
#   be up to date.
# - The programs of an image built with Rust must have all their imports
#   bound (tests/imports.zig).
# - The registry's catalog must list the apps published at these versions.
# CI runs this on a fresh Windows runner (.github/workflows/reproduce.yml), so
# it also shows that the recipes build the same images on another machine.
#
#   tests/published.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and network access. Pulls into a temporary store. Builds the
# recipes in BUILD_HOME if set, e.g. a store that already has their downloads,
# otherwise in a temporary store. Keeps the build and pull logs in LOG_DIR if
# set. With GROUP set, checks only the recipes of that group in
# scripts/published-groups.txt, as each of CI's jobs does with one; either
# way, every published recipe must be in exactly one group there. Skips the
# recipes SKIP_RECIPES lists (file names, separated by spaces).

set -u
export MSYS_NO_PATHCONV=1
unset ZIGSAW_REGISTRY_USERNAME ZIGSAW_REGISTRY_PASSWORD # Pulls must work anonymously.

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
work=$(cygpath -w "$(mktemp -d)")
# Apps that may use the user's folders, such as Documents, find none here,
# rather than yours.
export ZIGSAW_USER_FOLDERS="$work\\no-folders"
# Low runs (the default) label the working directory of an app with cwd: the
# runs go from a scratch one, not the repository, nor a folder that holds the
# stores (their programs would then start at low integrity).
mkdir -p "$work\\cwd" && cd "$work\\cwd" || exit 1
logs=${LOG_DIR:-$work\\logs}
mkdir -p "$logs"
pull_store="$work\\pulled"
build_store=${BUILD_HOME:-$work\\built}
# tests/imports.zig: whether the loader binds every import of a program.
(cd "$root" && zig build imports) || { echo "building the import checker failed"; exit 1; }
imports="$root\\zig-out\\test\\zigsaw-imports.exe"
zp() { ZIGSAW_HOME="$pull_store" "$zigsaw" "$@"; }
zb() { ZIGSAW_HOME="$build_store" "$zigsaw" "$@"; }

failures=0
unpublished=0
pulled=0
pass() { printf 'ok    %s\n' "$1"; }
# fail <label> [<detail line>...]
fail() {
    printf 'FAIL  %s\n' "$1"
    shift
    for line in "$@"; do printf '      %s\n' "$line"; done
    failures=$((failures + 1))
}
check() {
    local label=$1
    shift
    local out
    if out=$("$@" 2>&1); then
        pass "$label"
    else
        fail "$label" "$(grep -v '^\s*$' <<<"$out" | tail -1 | cut -c1-110)"
    fi
}
last_line() { grep -v '^\s*$' "$1" | tail -1 | cut -c1-110; }
# slowest <build log>: its five slowest commands, slowest first, as
# "<took>\t[<module> <n>/<count>]\t<command, cut short>". zigsaw logs each
# command as "[<module> <n>/<count>] <command>", and when it took a second
# or more, "[...] took 4m 07s" (or "12.3 s", "1h 03m") after it.
slowest() {
    tr -d '\r' <"$1" | awk '
        match($0, /^\[[^]]+ [0-9]+\/[0-9]+\] /) {
            step = substr($0, 1, RLENGTH - 1); rest = substr($0, RLENGTH + 1)
            if (rest ~ /^took ([0-9]+h [0-9]+m|[0-9]+m [0-9]+s|[0-9.]+ s)$/) {
                split(substr(rest, 6), p, " "); s = 0
                if (p[1] ~ /h$/) s = p[1] * 3600 + p[2] * 60
                else if (p[1] ~ /m$/) s = p[1] * 60 + p[2]
                else s = p[1]
                printf "%d\t%s\t%s\t%s\n", s * 10, substr(rest, 6), step, substr(command[step], 1, 100)
            } else command[step] = rest
        }' | sort -t$'\t' -k1,1nr | head -5 | cut -f2-
}

# Arguments for a quick run of each app that exits 0, within two minutes (a
# run still going then fails, rather than holding up the job).
smoke_args() {
    case $1 in
    # GTK's option parser: it has no --version.
    com.github.flxzt.rnote) printf '%s\n' --help ;;
    net.frippery.busybox) printf '%s\n' true ;;
    org.nodejs.node) printf '%s\n' '-e 0' ;;
    org.python.python) printf '%s\n' '-c pass' ;;
    org.ziglang.zig | org.golang.go | org.apache.pdfbox) printf '%s\n' version ;;
    org.7_zip.7zip) printf '%s\n' i ;;
    org.videolan.VLC) printf '%s\n' '-I dummy vlc://quit' ;;
    *) printf '%s\n' --version ;;
    esac
}
# GUI apps with no option that exits: they must still be running after ten
# seconds, when the run is stopped.
stays_up_ids=" org.notepad_plus_plus.NotepadPlusPlus org.sumatrapdfreader.SumatraPDF org.gtk.Gtk3demo com.gluonhq.SceneBuilder io.qt.Qt6 io.github.nuttyartist.notes "
stays_up() {
    ZIGSAW_HOME="$pull_store" timeout 10 "$zigsaw" run "$1" >/dev/null 2>&1
    [ $? -eq 124 ]
}
# Apps whose command is a web server, which they open in the browser unless
# told --no-browser: it must serve its login page at the address --listen
# gives. zigsaw itself in the background, not a function running it, so
# that `kill` ends zigsaw, and the run's job the server.
serves_ids=" org.kanboard.Kanboard "
serves() {
    local port=$((9100 + RANDOM % 800)) out="$logs\\$1.serve.log" server page=""
    ZIGSAW_HOME="$pull_store" "$zigsaw" run --ephemeral "$1" --no-browser --listen=127.0.0.1:$port >"$out" 2>&1 &
    server=$!
    for _ in $(seq 40); do
        page=$(curl -s -m 5 "http://127.0.0.1:$port/?controller=AuthController&action=login") && [ -n "$page" ] && break
        sleep 0.5
    done
    kill $server 2>/dev/null
    wait $server 2>/dev/null
    grep -q 'name="csrf_token"' <<<"$page" && return 0
    # What it served instead, kept with the logs.
    printf '%s' "$page" >"$logs\\$1.page.html"
    echo "no login page on port $port, but \"$(grep -o '<title>[^<]*' <<<"$page" | cut -c8- | head -1)\" ($1.page.html): $(last_line "$out")"
    return 1
}
smoke() { ZIGSAW_HOME="$pull_store" timeout 120 "$zigsaw" run "$@" </dev/null; }
ref_digest() { grep -o 'sha256:[0-9a-f]*' "$1\\refs\\$2.json"; }
# all_bound <store> <manifest digest>: tests/imports.zig on the executables
# and DLLs of the image's own layer, the last, deployed by a run.
all_bound() {
    local layer
    layer=$(manifest "$1" "$2" | tr -d ' \r\n' | grep -o '"layers":.*' | grep -o 'sha256:[0-9a-f]*' | tail -1 | cut -d: -f2)
    find "$(cygpath -u "$1\\deploy\\$layer")" -iname '*.exe' -o -iname '*.dll' | cygpath -w -f - | xargs -d '\n' "$imports" | grep -v -e ', 0 unbound$' -e ', skipped$'
    [ "${PIPESTATUS[2]}" -eq 0 ]
}
manifest() { cat "$1\\blobs\\sha256\\${2#sha256:}"; }
# The digests a manifest lists: <store> <manifest digest> config|layers
listed() { manifest "$1" "$2" | tr -d ' \r\n' | grep -o "\"$3\":\(\[[^]]*\]\|{[^}]*}\)" | grep -o 'sha256:[0-9a-f]*'; }
# files_diff <id> <built manifest digest> <published manifest digest>: for
# each layer of the built image that isn't the published image's layer at
# the same place, the files that differ between the two: a list in
# $logs\<id>.files-diff.txt ("differs", "only built", "only published"), and
# the files themselves, up to 200 MB in all, in $logs\<id>.differ\built and
# \published, so a build on another machine can be compared with this one's.
files_diff() {
    local id=$1 list="$logs\\$1.files-diff.txt" dir differ i=0 b p side kind path size left=$((200 * 1024 * 1024)) skipped=0
    local built_layers published_layers
    dir=$(cygpath -u "$work\\diff\\$id")
    differ=$(cygpath -u "$logs\\$id.differ")
    read -ra built_layers <<<"$(listed "$build_store" "$2" layers | tr '\n' ' ')"
    read -ra published_layers <<<"$(listed "$pull_store" "$3" layers | tr '\n' ' ')"
    : >"$list"
    for b in "${built_layers[@]}"; do
        p=${published_layers[$i]:-}
        i=$((i + 1))
        [ "$b" = "$p" ] && continue
        echo "layer $i: built $b, published ${p:-none}" >>"$list"
        rm -rf "$dir" && mkdir -p "$dir/built" "$dir/published"
        tar -xf "$(cygpath -u "$build_store\\blobs\\sha256\\${b#sha256:}")" -C "$dir/built" || echo "  can't unpack the built layer" >>"$list"
        [ -n "$p" ] && { tar -xf "$(cygpath -u "$pull_store\\blobs\\sha256\\${p#sha256:}")" -C "$dir/published" || echo "  can't unpack the published layer" >>"$list"; }
        for side in built published; do
            (cd "$dir/$side" && find . -type f -print0 | xargs -0 -r sha256sum) >"$dir/$side.sums"
        done
        # "<kind> <path>", for each path whose hash isn't the same on both sides.
        awk '
            FNR == 1 { side++ }
            { hash = $1; sub(/^[0-9a-f]+ [ *]/, ""); h[side, $0] = hash; seen[$0] = 1 }
            END {
                for (f in seen) {
                    if (!((1, f) in h)) print "only published " f
                    else if (!((2, f) in h)) print "only built " f
                    else if (h[1, f] != h[2, f]) print "differs " f
                }
            }' "$dir/built.sums" "$dir/published.sums" | sort -k2 >"$dir/differ.txt"
        sed 's/^/  /' "$dir/differ.txt" >>"$list"
        echo "  $(grep -c . "$dir/differ.txt") of $(grep -c . "$dir/built.sums") built file(s)" >>"$list"
        while read -r kind path; do
            [ "$kind" = only ] && path=${path#* }
            for side in built published; do
                [ -f "$dir/$side/$path" ] || continue
                size=$(stat -c %s "$dir/$side/$path")
                if [ "$size" -gt "$left" ]; then skipped=$((skipped + 1)); continue; fi
                left=$((left - size))
                mkdir -p "$differ/$side" && (cd "$dir/$side" && cp --parents "$path" "$differ/$side/")
            done
        done <"$dir/differ.txt"
        rm -rf "$dir"
    done
    [ "$skipped" -eq 0 ] || echo "$skipped file(s) not copied into $id.differ: over 200 MB in all" >>"$list"
}
# Whether an image was built with a host toolchain, such as MSVC, and so
# isn't expected to match a build on another machine: <store> <manifest digest>
host_built() {
    local config
    config=$(listed "$1" "$2" config)
    tr -d ' \r\n' <"$1\\blobs\\sha256\\${config#sha256:}" | grep -q '"host":{"'
}

published_recipes=$(grep -v '^#' "$root/scripts/published-recipes.txt" | tr -d '\r')
# Each published recipe's group, and nothing grouped that isn't published.
declare -A group_of
problems=()
while read -r group recipes; do
    group=${group%:}
    for name in $recipes; do
        if [ -n "${group_of[$name]:-}" ]; then
            problems+=("$name is in both ${group_of[$name]} and $group")
        else
            group_of[$name]=$group
        fi
        grep -qxF "$name" <<<"$published_recipes" || problems+=("$name ($group) isn't in published-recipes.txt")
    done
done < <(grep -v -e '^#' -e '^\s*$' "$root/scripts/published-groups.txt" | tr -d '\r')
for name in $published_recipes; do
    [ -n "${group_of[$name]:-}" ] || problems+=("$name is in no group")
done
if [ ${#problems[@]} -gt 0 ]; then
    fail "scripts/published-groups.txt groups each published recipe once" "${problems[@]}"
    rm -rf "$work"
    exit 1
fi
if [ -n "${GROUP:-}" ] && ! grep -qx "$GROUP" < <(printf '%s\n' "${group_of[@]}"); then
    echo "no group $GROUP in scripts/published-groups.txt"
    rm -rf "$work"
    exit 1
fi

# The job's summary, in CI: each recipe's build time, for balancing the
# groups (a build log says where its time went).
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '### %s\n\n| recipe | build |\n|---|---|\n' "${GROUP:-all groups}" >>"$GITHUB_STEP_SUMMARY"
fi
ids=()
declare -A names # by id: the recipe's name, if it gives one
published_versions=()
skipped=0
others=0
for name in $published_recipes; do
    if [ -n "${GROUP:-}" ] && [ "${group_of[$name]}" != "$GROUP" ]; then
        others=$((others + 1))
        continue
    fi
    case " ${SKIP_RECIPES:-} " in
    *" $name "*)
        printf 'skip  %s\n' "$name"
        skipped=$((skipped + 1))
        continue
        ;;
    esac
    recipe="$root\\recipes\\$name"
    id=$(grep -o '"id": *"[^"]*"' "$recipe" | cut -d'"' -f4)
    ids+=("$id")
    names[$id]=$(grep -o '^  "name": *"[^"]*"' "$recipe" | cut -d'"' -f4)
    started=$SECONDS
    if ! zb build "$recipe" >"$logs\\$id.build.log" 2>&1; then
        fail "$id: builds" "$(last_line "$logs\\$id.build.log")"
        continue
    fi
    took=$((SECONDS - started))
    printf 'time  %s: built in %dm %02ds\n' "$id" $((took / 60)) $((took % 60))
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '| %s | %dm %02ds |\n' "$id" $((took / 60)) $((took % 60)) >>"$GITHUB_STEP_SUMMARY"
    slowest "$logs\\$id.build.log" | while IFS=$'\t' read -r dur step command; do
        printf 'slow    %8s  %s %s\n' "$dur" "$step" "$command"
        [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '| &nbsp;&nbsp;%s `%s` | %s |\n' "$step" "$(tr '|`' '/'"'" <<<"$command")" "$dur" >>"$GITHUB_STEP_SUMMARY"
    done
    built=$(ref_digest "$build_store" "$id")
    version=$(zb list | awk -v id="$id" '$1 == id { print $2 }')

    # Verbose, so the log shows where blob downloads were redirected.
    pull_log="$logs\\$id.pull.log"
    if ! zp -v pull --yes "$id:$version" >"$pull_log" 2>&1; then
        # Registries answer "not found" for a missing tag, and refuse an
        # anonymous token for a package that doesn't exist (or is private).
        if grep -qE "not found|doesn't exist, or needs credentials" "$pull_log"; then
            printf 'new   %s %s is not published yet\n' "$id" "$version"
            unpublished=$((unpublished + 1))
        else
            fail "$id $version: pulls anonymously by app id" "$(last_line "$pull_log")"
        fi
        continue
    fi
    pulled=$((pulled + 1))
    pass "$id $version: pulls anonymously by app id"
    published_versions+=("$id $version")

    published=$(ref_digest "$pull_store" "$id")
    if host_built "$build_store" "$built"; then
        printf 'host  %s %s is built with a host toolchain, so it isn'"'"'t compared\n' "$id" "$version"
    elif [ "$published" = "$built" ]; then
        pass "$id $version: has the digest of a fresh build"
    else
        manifest "$build_store" "$built" >"$logs\\$id.built-manifest.json"
        manifest "$pull_store" "$published" >"$logs\\$id.published-manifest.json"
        differ=""
        [ "$(listed "$build_store" "$built" config)" = "$(listed "$pull_store" "$published" config)" ] ||
            differ="the config (the recipe's settings)"
        if [ "$(listed "$build_store" "$built" layers)" != "$(listed "$pull_store" "$published" layers)" ]; then
            differ="${differ:+$differ and }the files"
            files_diff "$id" "$built" "$published"
        fi
        details=(
            "published $published"
            "built     $built"
            "They differ in ${differ:-the manifest alone}."
            "Either the build isn't reproducible, or the recipe changed without a new version."
        )
        [ -n "${LOG_DIR:-}" ] && details+=("Both manifests are in $LOG_DIR.")
        [ -n "${LOG_DIR:-}" ] && [ -f "$logs\\$id.files-diff.txt" ] && details+=("The files that differ: $id.files-diff.txt and $id.differ there.")
        fail "$id $version: has the digest of a fresh build" "${details[@]}"
    fi

    if [[ $stays_up_ids == *" $id "* ]]; then
        check "$id: runs, and is still running after ten seconds" stays_up "$id"
    elif [[ $serves_ids == *" $id "* ]]; then
        check "$id: runs, and serves its login page" serves "$id"
    else
        # shellcheck disable=SC2046 # The arguments are meant to split.
        check "$id: runs" smoke "$id" $(smoke_args "$id")
    fi
    # What Rust's toolchain links, GNU ld, must leave no import unbound
    # (docs/iteration-12.md).
    if grep -q '"org\.rust-lang\.rust[:@]' "$recipe"; then
        check "$id: the loader binds all its programs' imports" all_bound "$pull_store" "$published"
    fi
    latest_is_version() {
        zp -v pull --yes "$id" >>"$pull_log" 2>&1 || { last_line "$pull_log"; return 1; }
        local latest
        latest=$(ref_digest "$pull_store" "$id")
        [ "$latest" = "$published" ] || { echo "latest is $latest, $version is $published"; return 1; }
    }
    check "$id: latest is $version" latest_is_version
    up_to_date() {
        local out
        out=$(zp update --yes "$id" 2>&1)
        grep -q 'up to date' <<<"$out" || { echo "$out"; return 1; }
    }
    check "$id: is up to date" up_to_date
done
if [ $pulled -gt 0 ]; then
    redirected() { cat "$(cygpath -u "$logs")"/*.pull.log | grep -q 'redirected to .*, without the registry token'; }
    check "blob downloads were redirected to another host, without the token" redirected
fi

# The registry's catalog (scripts/publish.sh pushes it) lists the apps
# published at these versions, as `zigsaw search` shows it.
if [ ${#published_versions[@]} -gt 0 ]; then
    in_catalog() {
        local out entry missing=()
        out=$(zp search 2>&1) || { grep -v '^\s*$' <<<"$out" | tail -1; return 1; }
        for entry in "${published_versions[@]}"; do
            awk -v id="${entry% *}" -v v="${entry#* }" '$1 == id && $2 == v { found = 1 } END { exit !found }' <<<"$out" ||
                missing+=("$entry")
        done
        [ ${#missing[@]} -eq 0 ] || { echo "it doesn't list ${missing[*]}"; return 1; }
    }
    check "the registry's catalog lists the apps published at these versions" in_catalog
    # A catalog pushed before an app was republished with a name lists it by
    # its commands.
    named() {
        local out entry id unnamed=()
        out=$(zp search 2>&1) || return 1
        for entry in "${published_versions[@]}"; do
            id=${entry% *}
            [ -n "${names[$id]}" ] || continue
            awk -v id="$id" -v name="${names[$id]}: " '$1 == id && index($0, name) { found = 1 } END { exit !found }' <<<"$out" ||
                unnamed+=("$id")
        done
        [ ${#unnamed[@]} -eq 0 ] || { echo "it doesn't name ${unnamed[*]}"; return 1; }
    }
    check "the catalog describes each app by its recipe's name" named
fi

check "no run labelled or granted the repository" sh -c "! icacls '$root' | grep -q -e 'Mandatory Label' -e 'S-1-15-'"

# Installed apps are protected against deletion, so remove them through zigsaw.
for id in "${ids[@]}"; do zp rm --delete-data "$id" >/dev/null 2>&1; done
zp prune --downloads >/dev/null 2>&1
if [ -z "${BUILD_HOME:-}" ]; then
    for id in "${ids[@]}"; do zb rm --delete-data "$id" >/dev/null 2>&1; done
    zb prune --downloads >/dev/null 2>&1
fi
rm -rf "$work"
echo
echo "$failures check(s) failed; $unpublished version(s) not published yet; $skipped recipe(s) skipped${GROUP:+; $others in groups other than $GROUP}."
exit $((failures > 0))
