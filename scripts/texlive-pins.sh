#!/usr/bin/env bash
# Pins TeX Live's packages for recipes/texlive.json, which this writes from
# recipes/texlive/texlive.json.in. tlnet, TeX Live's repository, has one
# archive per package and replaces it in place when the package changes, so
# the recipe pins each archive the scheme needs by sha256, with the package
# database they come from (see docs/recipes.md, "TeX Live").
#
#   scripts/texlive-pins.sh            (then build recipes/texlive.json)
#
# It downloads tlnet's texlive.tlpdb, takes the scheme's packages for
# Windows (with what install-tl adds on Windows: tlperl, tlgs, and its
# required packages), downloads each archive, checks it against the
# database's sha512, and writes every archive's URL and sha256 into the
# recipe, with the version (2026.<repository revision>) and the exports (the
# packages' programs in bin/windows, but for those listed in `deny`). A
# package updated while it runs fails it; run it again.
#
# MIRROR is the tlnet URL the recipe pins (default: MIT's CTAN mirror);
# SCHEME the scheme (default scheme-small); TEXLIVE_PINS_CACHE keeps the
# downloads between runs (default: texlive-pins in TMPDIR). Needs curl, xz
# and Git Bash, not zigsaw.

set -eu
export MSYS_NO_PATHCONV=1

root=$(cd "$(dirname "$0")/.." && pwd)
mirror=${MIRROR:-https://mirrors.mit.edu/CTAN/systems/texlive/tlnet}
mirror=${mirror%/}
scheme=${SCHEME:-scheme-small}
cache=${TEXLIVE_PINS_CACHE:-${TMPDIR:-/tmp}/texlive-pins}
# curl is Windows' own, which MSYS_NO_PATHCONV leaves /d/... paths to.
command -v cygpath >/dev/null && cache=$(cygpath -m "$cache")
template=$root/recipes/texlive/texlive.json.in
out=$root/recipes/texlive.json
# Programs not exported: tlmgr and its GUIs (the tree is read-only), what
# writes the system trees, script runners, and documentation browsers (no
# documentation is installed).
deny=" runscript wrunscript utf8runscript tlmgr tlshell tlcockpit tl-tray-menu updmap updmap-sys fmtutil fmtutil-sys mktexlsr texhash texdoc texdoctk "
mkdir -p "$cache/archive"

fetch() { curl -fsSL --retry 3 --max-time 600 -o "$2" "$1"; }

echo "texlive.tlpdb from $mirror"
fetch "$mirror/tlpkg/texlive.tlpdb" "$cache/texlive.tlpdb"
tlpdb=$cache/texlive.tlpdb
release=$(awk '/^name 00texlive.config$/{f=1} f&&/^depend release\//{sub(/.*\//,""); print; exit}' "$tlpdb")
revision=$(awk '/^name 00texlive.config$/{f=1} f&&/^depend revision\//{sub(/.*\//,""); print; exit}' "$tlpdb")
[ -n "$release" ] && [ -n "$revision" ] || { echo "no release or revision in texlive.tlpdb" >&2; exit 1; }

# The packages: name, then the archive's sha512, for every package in the
# closure of the roots, with each `.ARCH` dependency for Windows. Roots as
# install-tl's calc_depends and TLConfig's InstallExtraRequiredPackages.
awk -v roots="$scheme texlive-scripts kpathsea hyphen-base luatex tlperl.windows tlgs.windows" '
/^name / { n = $2; next }
/^depend / { deps[n] = deps[n] " " $2; next }
/^containerchecksum / { sum[n] = $2; next }
END {
    qn = split(roots, q, " ")
    for (i = 1; i <= qn; i++) seen[q[i]] = 1
    for (i = 1; i <= qn; i++) {
        m = split(deps[q[i]], ds, " ")
        for (j = 1; j <= m; j++) {
            d = ds[j]
            sub(/\.ARCH$/, ".windows", d)
            if (!(d in sum) || (d in seen)) continue
            seen[d] = 1; q[++qn] = d
        }
    }
    for (p in seen) if (p in sum) print p, sum[p]
}' "$tlpdb" | sort >"$cache/packages.txt"
echo "$(wc -l <"$cache/packages.txt") packages of $scheme, TeX Live $release revision $revision"

# Downloads what the cache lacks or has another version of.
while read -r name sha512; do
    f=$cache/archive/$name.tar.xz
    if [ ! -f "$f" ] || [ "$(sha512sum <"$f" | cut -d' ' -f1)" != "$sha512" ]; then
        printf '%s\n' "$name"
    fi
done <"$cache/packages.txt" >"$cache/missing.txt"
if [ -s "$cache/missing.txt" ]; then
    echo "downloading $(wc -l <"$cache/missing.txt") archives"
    # shellcheck disable=SC2016
    xargs -P 8 -I{} sh -c 'curl -fsSL --retry 3 --max-time 600 -o "$1/archive/$2.tar.xz" "$3/archive/$2.tar.xz" || { echo "failed: $2" >&2; exit 255; }' _ "$cache" {} "$mirror" <"$cache/missing.txt"
fi
while read -r name sha512; do
    got=$(sha512sum <"$cache/archive/$name.tar.xz" | cut -d' ' -f1)
    if [ "$got" != "$sha512" ]; then
        echo "$name.tar.xz isn't what texlive.tlpdb says (updated meanwhile?): run again" >&2
        exit 1
    fi
done <"$cache/packages.txt"

echo "install-tl.zip"
fetch "$mirror/install-tl.zip" "$cache/install-tl.zip"

sha256() { sha256sum <"$1" | cut -d' ' -f1; }
source_line() { # url sha256 dest [type]
    printf '        { "url": "%s", "sha256": "%s", "dest": "%s"%s }' "$1" "$2" "$3" "${4:+, \"type\": \"$4\"}"
}
{
    source_line "$mirror/install-tl.zip" "$(sha256 "$cache/install-tl.zip")" install-tl
    printf ',\n'
    source_line "$mirror/tlpkg/texlive.tlpdb" "$(sha256 "$tlpdb")" repo/tlpkg/texlive.tlpdb
    while read -r name _; do
        printf ',\n'
        source_line "$mirror/archive/$name.tar.xz" "$(sha256 "$cache/archive/$name.tar.xz")" "repo/archive/$name.tar.xz" file
    done <"$cache/packages.txt"
    printf '\n'
} >"$cache/sources.json"
# install-tl.zip has a directory named after its date: strip it.
sed -i 's|"dest": "install-tl" }|"dest": "install-tl", "strip": 1 }|' "$cache/sources.json"

# The programs in bin/windows of the Windows packages.
awk -v pkgs="$(cut -d' ' -f1 "$cache/packages.txt" | grep '\.windows$' | tr '\n' ' ')" -v deny="$deny" '
BEGIN { n = split(pkgs, ps, " "); for (i = 1; i <= n; i++) want[ps[i]] = 1 }
/^name / { p = $2; files = 0; next }
/^[a-z]/ { files = ($1 == "binfiles" && (p in want)); next }
files && /^ bin\/windows\/[^\/]*\.exe$/ {
    e = $1; sub(/^bin\/windows\//, "", e); sub(/\.exe$/, "", e)
    if (index(deny, " " e " ") == 0 && e !~ /-sys$/) print e
}' "$tlpdb" | sort -u >"$cache/exports.txt"
{
    first=1
    while read -r e; do
        [ $first = 1 ] || printf ',\n'
        first=0
        printf '    "%s": { "command": "bin/windows/%s.exe" }' "$e" "$e"
    done <"$cache/exports.txt"
    printf '\n'
} >"$cache/exports.json"

# install-tl's profile: the scheme's collections, named, so install-tl
# doesn't add collection-wintools as it does on Windows; the tree in the
# build's prefix, portable (no registry, PATH or Start menu); without
# documentation or sources; without formats, which engines dump with the
# clock in them (each is made in the data directory on first use instead).
{
    printf '%s\n' "# Written by scripts/texlive-pins.sh: install-tl's answers for recipes/texlive.json." \
        "selected_scheme $scheme" "TEXDIR B:/prefix" "TEXMFLOCAL B:/prefix/texmf-local" \
        "TEXMFSYSVAR B:/prefix/texmf-var" "TEXMFSYSCONFIG B:/prefix/texmf-config" \
        "TEXMFVAR B:/prefix/texmf-var" "TEXMFCONFIG B:/prefix/texmf-config" "TEXMFHOME B:/prefix/texmf-local" \
        "binary_windows 1"
    awk -v s="$scheme" '$0 == "name " s {f = 1; next} f && /^name /{exit} f && /^depend collection-/{print $2 " 1"}' "$tlpdb"
    printf '%s\n' "collection-wintools 0" "instopt_adjustpath 0" "instopt_adjustrepo 0" "instopt_letter 0" \
        "instopt_portable 1" "instopt_write18_restricted 1" "tlpdbopt_autobackup 0" "tlpdbopt_create_formats 0" \
        "tlpdbopt_desktop_integration 0" "tlpdbopt_file_assocs 0" "tlpdbopt_generate_updmap 0" \
        "tlpdbopt_install_docfiles 0" "tlpdbopt_install_srcfiles 0" "tlpdbopt_post_code 1" "tlpdbopt_w32_multi_user 0"
} >"$root/recipes/texlive/texlive.profile"

epoch=$(($(date -u +%s) / 86400 * 86400))
awk -v version="$release.$revision" -v epoch="$epoch" -v sources="$cache/sources.json" -v exports="$cache/exports.json" '
/^ *@SOURCES@$/ { while ((getline l <sources) > 0) print l; next }
/^ *@EXPORTS@$/ { while ((getline l <exports) > 0) print l; next }
{ gsub(/@VERSION@/, version); gsub(/@EPOCH@/, epoch); print }' "$template" >"$out"
echo "wrote recipes/texlive.json: version $release.$revision, $(wc -l <"$cache/packages.txt") packages, $(wc -l <"$cache/exports.txt") exports"
