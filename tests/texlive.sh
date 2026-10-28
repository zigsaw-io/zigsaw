#!/usr/bin/env bash
# TeX Live end to end (recipes/texlive.json: TeX Live's small scheme, its
# prebuilt Windows programs, on the Perl and Ghostscript images as runtimes).
# pdfLaTeX, XeLaTeX and LuaLaTeX typeset a document each, the last two with
# a font found by name (XeTeX through fontconfig, whose configuration in the
# image names its directories relative to itself); each makes its format in
# the app's data directory on first use, as the image has none (formats
# hold the time they were made). BibTeX, MakeIndex and MetaPost run, Biber
# starts, latexmk runs on Perl's image (TeX Live's own Perl isn't in the
# image), and epstopdf and ps2pdf on Ghostscript's. kpathsea's variable
# trees are in the data directory; nothing is written in the deployment; a
# PDF made twice with SOURCE_DATE_EPOCH is the same bytes. All at low
# integrity, the default; pdfLaTeX and LuaLaTeX under soft too, and pdfLaTeX
# in an AppContainer.
#
# Where Windows denies AppContainers listing the drive root
# (tests/acprobe.sh: self-long-name, as on Windows 11 26300), kpathsea can't
# find its own long path in one and every program stops at once: the
# AppContainer check is a known gap there.
#
#   TEXLIVE_HOME=path\to\store bash tests/texlive.sh [path\to\zigsaw.exe]
#
# Building TeX Live takes some 15 minutes, most of them downloading 430
# packages, so this uses a store that has it (TEXLIVE_HOME, or BUILD_HOME as
# tests/published.sh leaves it), and says so and stops if neither has.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
ZIGSAW_HOME=${TEXLIVE_HOME:-${BUILD_HOME:-}}
APP=org.tug.texlive
if [ -z "$ZIGSAW_HOME" ] || [ ! -f "$ZIGSAW_HOME\\refs\\$APP.json" ]; then
    echo "tests/texlive.sh needs a store with $APP in TEXLIVE_HOME or BUILD_HOME;"
    echo "build recipes\\texlive.json into one first."
    exit 1
fi
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")
data="$ZIGSAW_HOME\\data\\$APP"

failures=0
gaps=0
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

# check_want <ok|gap> <label> <command...>: check, but a failure where the
# probe says a known gap's causes are there counts as that gap.
check_want() {
    local want=$1 label=$2
    shift 2
    [ "$want" = gap ] || { check "$label" "$@"; return; }
    local out
    if out=$("$@" 2>&1); then
        printf 'ok    %s  (a known gap that passes now)\n' "$label"
    else
        printf 'gap   %s  (known gap)\n      %s\n' "$label" "$(grep -v '^\s*$' <<<"$out" | tail -1 | cut -c1-110)"
        gaps=$((gaps + 1))
    fi
}

z() { "$zigsaw" "$@"; }
# tl <program> [args...]: a TeX Live program, run from the work directory.
tl() {
    local program=$1
    shift
    timeout 300 "$zigsaw" run ${SANDBOX:+--sandbox=$SANDBOX} --command "bin/windows/$program.exe" $APP -interaction=nonstopmode "$@"
}
tl_plain() {
    local program=$1
    shift
    timeout 300 "$zigsaw" run ${SANDBOX:+--sandbox=$SANDBOX} --command "bin/windows/$program.exe" $APP "$@"
}

. "$(dirname "$0")/acprobe.sh"
acprobe_run "$zigsaw" "$root" "$work"

cp -r "$root\\tests\\texlive\\." "$work\\"
# Runs from the work directory: the app has the cwd permission.
cd "$work" || exit 1
touch "$work\\start"

# typeset <program> <file> <jobname>: a PDF, and no errors in the log.
typeset() {
    rm -f "$3.pdf" "$3.log"
    tl "$1" -jobname="$3" "$2" >"$3.out" 2>&1 || { tail -5 "$3.out"; return 1; }
    test -s "$3.pdf" || { echo "no $3.pdf"; return 1; }
    ! grep -q '^!' "$3.log" || { grep -m1 -A2 '^!' "$3.log"; return 1; }
}
check "pdfLaTeX typesets a document" typeset pdflatex hello.tex hello
format_in_data() { test -f "$data\\texmf-var\\web2c\\$1\\$2.fmt" || { echo "no $2.fmt in the data directory"; return 1; }; }
check "it made its format in the data directory" format_in_data pdftex pdflatex
check "XeLaTeX typesets with a font found by name, through fontconfig" typeset xelatex fonts.tex xe
check "fontconfig keeps its cache in the data directory" sh -c "ls '$data\\texmf-var\\fonts\\cache' | grep -q 'cache-'"
check "LuaLaTeX typesets with a font found by name" typeset lualatex fonts.tex lua
check "luaotfload keeps its font names in the data directory" test -d "$data\\texmf-var\\luatex-cache"
check "LuaLaTeX again, with its format and font names made" typeset lualatex fonts.tex lua2

var_is() { local got; got=$(tl_plain kpsewhich -var-value="$1" | tr -d '\r'); [ "$(cygpath -w "$got")" = "$2" ] || { echo "$1 is $got"; return 1; }; }
check "kpathsea's TEXMFVAR is in the data directory" var_is TEXMFVAR "$data\\texmf-var"
check "and TEXMFHOME" var_is TEXMFHOME "$data\\texmf"

bib() {
    tl pdflatex cite.tex >cite.out 2>&1 && tl_plain bibtex cite >>cite.out 2>&1 && tl_plain makeindex cite >>cite.out 2>&1 &&
        tl pdflatex cite.tex >>cite.out 2>&1 || { tail -5 cite.out; return 1; }
    grep -q 'Knuth' cite.bbl || { echo "no Knuth in cite.bbl"; return 1; }
    grep -q 'TeX' cite.ind || { echo "no TeX in cite.ind"; return 1; }
}
check "BibTeX and MakeIndex run" bib
check "Biber starts" sh -c "\"\$0\" run --command bin/windows/biber.exe $APP --version 2>&1 | tr -d '\r' | grep -q '^biber version: '" "$zigsaw"
mp() { tl_plain mpost fig.mp >mpost.out 2>&1 || { tail -5 mpost.out; return 1; }; test -s fig-1.mps; }
check "MetaPost draws a figure" mp
latexmk() {
    rm -f mk.pdf
    timeout 300 "$zigsaw" run $APP -pdf -jobname=mk hello.tex >latexmk.out 2>&1 || { tail -5 latexmk.out; return 1; }
    test -s mk.pdf
}
check "latexmk, on Perl's image, makes a PDF" latexmk
eps() { tl_plain epstopdf fig.eps >eps.out 2>&1 || { tail -5 eps.out; return 1; }; test -s fig.pdf; }
check "epstopdf, on Ghostscript's image, converts EPS to PDF" eps
ps2pdf() {
    tl latex hello.tex >dvi.out 2>&1 && tl_plain dvips -q hello.dvi -o hello.ps >>dvi.out 2>&1 &&
        tl_plain ps2pdf hello.ps fromps.pdf >>dvi.out 2>&1 || { tail -5 dvi.out; return 1; }
    test -s fromps.pdf
}
check "LaTeX, dvips and ps2pdf make a PDF through PostScript" ps2pdf

dated() {
    timeout 300 "$zigsaw" run --env=SOURCE_DATE_EPOCH=1767225600 --env=FORCE_SOURCE_DATE=1 --command bin/windows/pdflatex.exe $APP \
        -interaction=nonstopmode -jobname=same hello.tex >same.out 2>&1 || { tail -5 same.out; return 1; }
}
same_pdf() {
    dated && mv same.pdf first.pdf && sleep 2 && dated && cmp first.pdf same.pdf
}
check "a PDF made twice with SOURCE_DATE_EPOCH is the same bytes" same_pdf

tree=$(cygpath -w "$(tl_plain kpsewhich -var-value=SELFAUTOPARENT | tr -d '\r')")
written() {
    local new
    new=$(find "$tree" -newer "$work\\start" -print 2>/dev/null | head -3)
    [ -z "$new" ] || { echo "written: $new"; return 1; }
    ! find "$tree" -name '*.fmt' | grep -q . || { echo "the image has formats"; return 1; }
}
check "nothing was written in the deployment, which has no formats" written

SANDBOX=soft check "pdfLaTeX under soft" typeset pdflatex hello.tex soft
# A format made at low integrity, in the data directory as soft runs see it.
SANDBOX=soft check "LuaLaTeX under soft" typeset lualatex fonts.tex softlua
SANDBOX=appcontainer check_want "$(ac_if self-long-name)" "pdfLaTeX in an AppContainer" typeset pdflatex hello.tex ac

check "no run labelled or granted the repository" sh -c "! icacls '$root' | grep -q -e 'Mandatory Label' -e 'S-1-15-'"

cd "$root" || exit 1
acprobe_rm "$zigsaw"
rm -rf "$work"
echo
acprobe_report
echo
echo "$failures check(s) failed, and $gaps known gap(s)."
exit $((failures > 0))
