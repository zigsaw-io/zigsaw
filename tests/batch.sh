#!/usr/bin/env bash
# Batch files as commands, end to end. A test app's command and export are
# .cmd files that pass %* on to a program that prints its arguments. Every
# argument must arrive exactly as given, and none may run a command of its own.
#
#   tests/batch.sh [path\to\zigsaw.exe]
#
# Needs Git Bash. Builds the argument printer (tests/argv.zig) and the app
# (tests/batch/app.json) in a temporary store, whose path has characters that
# cmd.exe treats specially, so the batch file's own path has to survive them.

set -u
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.." || exit 1
root=$(cygpath -w "$(pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
zig build argv-echo || { echo "building the argument printer failed"; exit 1; }

tmp=$(cygpath -w "$(mktemp -d)")
export ZIGSAW_HOME="$tmp\\store & ^ %PATH% ü"
work="$tmp\\work"
mkdir -p "$work"
APP=test.batch.args

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

"$zigsaw" build "$root\\tests\\batch\\app.json" >/dev/null 2>&1 || { echo "building the test app failed"; exit 1; }
# The app's files are the deployment of its manifest's last layer.
manifest="$ZIGSAW_HOME\\blobs\\sha256\\$(grep -o 'sha256:[0-9a-f]*' "$ZIGSAW_HOME\\refs\\$APP.json" | cut -d: -f2)"
deploy="$ZIGSAW_HOME\\deploy\\$(grep -o 'sha256:[0-9a-f]*' "$manifest" | tail -1 | cut -d: -f2)"

# What cmd.exe would act on if it reached it unquoted, and the edge cases of quoting.
injected="$work\\injected.txt"
args=(
    plain "" " " "two words" 'C:\dir\' 'C:\dir with space\' 'a\b' '\\server\share\'
    'say "hi"' '"' '""' 'a\"b' 'a\\"b' 'trailing\\'
    '%PATH%' '%ZIGSAW_ID%' '%' '%%' '%~dp0' '%1' '%cd:~,%' '!ZIGSAW_ID!' '!'
    '&' '|' '<' '>' '^' '(' ')' '& | < > ^ ( )' '^&' ',;=' "'single'"
    "\" & echo injected> \"$injected\" & \""
    "& echo injected> \"$injected\""
    $'tab\there' 'héllo wörld' '✓ 😀'
)
hex() { printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n'; echo; }
want=$(for a in "${args[@]}"; do hex "$a"; done)
# Runs a command with the arguments above and compares what the printer got.
gets_args() {
    local got
    got=$("$@" "${args[@]}" | tr -d '\r') || return 1
    [ "$got" = "$want" ] || { diff <(echo "$want") <(echo "$got") | head -4; return 1; }
}

check "the printer alone gets the arguments exactly (the control)" gets_args "$root\\zig-out\\test\\zigsaw-argv.exe"
check "the app's .cmd command gets them exactly" gets_args "$zigsaw" run $APP
check "an exported .cmd gets them exactly" gets_args "$zigsaw" run --command=echo-args $APP
check "so does its shim" gets_args "$ZIGSAW_HOME\\bin\\echo-args.exe"
check "and under --sandbox=appcontainer" gets_args "$zigsaw" run --sandbox=appcontainer $APP
check "and under --sandbox=low" gets_args "$zigsaw" run --sandbox=low $APP
check "no argument ran a command" test ! -e "$injected"
# Attempts to run a command, one per run, so no other argument changes how
# cmd.exe reads them.
injections=(
    "\" & echo injected> \"$injected\" & \""
    "\"&echo injected>\"$injected\"&\""
    "& echo injected> \"$injected\""
    "\\\" & echo injected> \"$injected\" & \\\""
    "%cd:~,1%\" & echo injected> \"$injected\""
)
one_at_a_time() {
    local a got
    for a in "${injections[@]}"; do
        got=$("$zigsaw" run $APP "$a" | tr -d '\r')
        [ "$got" = "$(hex "$a")" ] || { echo "\"$a\" came back as $got"; return 1; }
    done
    [ ! -e "$injected" ] || { echo "a command ran"; return 1; }
}
check "attempts to run a command, one at a time, don't" one_at_a_time

export_args() {
    local want got
    want=$(for a in "$deploy" "a b" "%PATH%" x; do hex "$a"; done)
    got=$("$zigsaw" run --command=echo-args-pre $APP x | tr -d '\r')
    [ "$got" = "$want" ] || { diff <(echo "$want") <(echo "$got") | head -4; return 1; }
}
check "an export's own arguments come first, also exactly" export_args
exit_code() { "$zigsaw" run --command=exit-code $APP 7; [ $? -eq 7 ]; }
check "--command finds a .cmd, and its exit code comes back" exit_code
line_break() {
    local out
    out=$("$zigsaw" run $APP $'a\nb' 2>&1) && return 1
    grep -q "can't pass it an argument with a line break" <<<"$out" || { echo "$out"; return 1; }
}
check "an argument with a line break is refused" line_break
verbose() {
    local out
    out=$("$zigsaw" -v run $APP x 2>&1 >/dev/null)
    grep -q '^exe .*\\System32\\cmd\.exe$' <<<"$out" &&
        grep -q '^script .*\\echo-args\.cmd$' <<<"$out" &&
        grep -q '^cmdline .*cmd\.exe /d /e:ON /v:OFF /c ""' <<<"$out"
}
check "-v shows cmd.exe, the script and the command line" verbose

# Installed apps are protected against deletion, so remove them through zigsaw.
"$zigsaw" rm --delete-data $APP >/dev/null 2>&1
rm -rf "$tmp"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
