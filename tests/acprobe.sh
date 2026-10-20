# What this Windows denies AppContainers, for the suites whose known gaps
# depend on it (tests/matrix.sh, tests/zls.sh). Sourced, not run:
#
#   . "$(dirname "$0")/acprobe.sh"
#   acprobe_run <zigsaw.exe> <repository> <work dir>   # sets $probe, or exits
#   want=$(ac_if self-path-dos nul)                     # "ok", or "gap"
#   acprobe_rm <zigsaw.exe>
#
# The probe (tests/acprobe.zig, built with `zig build acprobe`) is installed
# as an app of its own and run in an AppContainer from a granted directory.
# Its output is a line per check, "<check> ok" or "<check> error <n> (...)".

ACPROBE_ID=test.acprobe

acprobe_run() {
    local zigsaw=$1 root=$2 work=$3 out
    (cd "$root" && zig build acprobe) || { echo "building the AppContainer probe failed"; exit 1; }
    mkdir -p "$work\\acprobe\\cwd" && cp "$root\\zig-out\\test\\zigsaw-acprobe.exe" "$work\\acprobe\\"
    printf '{ "id": "%s", "version": "1", "command": "zigsaw-acprobe.exe", "exports": {}, "permissions": { "filesystem": ["cwd"] },\n  "modules": [{ "name": "probe", "sources": [{ "path": "zigsaw-acprobe.exe" }] }] }\n' \
        $ACPROBE_ID >"$work\\acprobe\\acprobe.json"
    out=$("$zigsaw" build "$work\\acprobe\\acprobe.json" 2>&1) || { echo "$out"; exit 1; }
    probe=$(cd "$work\\acprobe\\cwd" && "$zigsaw" run --sandbox=appcontainer $ACPROBE_ID 2>/dev/null | tr -d '\r')
    grep -q '^nul ' <<<"$probe" || { echo "the AppContainer probe didn't run: $probe"; exit 1; }
}

# ac_if <check...>: the intended outcome under AppContainer of a known gap
# whose causes are those probe checks: "ok" where they all passed, else "gap".
ac_if() {
    local check
    for check in "$@"; do
        grep -qx "$check ok" <<<"$probe" || { echo gap; return; }
    done
    echo ok
}

# The probe's report, for the end of a suite.
acprobe_report() {
    echo "In an AppContainer on $(cmd /c ver | tr -d '\r' | grep -v '^$') (tests/acprobe.zig):"
    grep -v '^#' <<<"$probe" | sed 's/^/  /'
}

acprobe_rm() {
    "$1" rm --delete-data $ACPROBE_ID >/dev/null 2>&1
}
