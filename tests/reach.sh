#!/usr/bin/env bash
# What a run may reach of the rest of the machine, end to end, in a store of
# its own, with small test apps:
#
# - --share=commands: the store's commands on a soft run's PATH, after the
#   system's, each running as its own app, with its own data and sandbox and
#   the user's folders, ending with the run;
# - --share=host: zigsaw-host, which runs a program in the user's real
#   environment, with the run's rights;
# - an image saying it can't run under a sandbox, on the console, in a saved
#   override, and in the GUI shim's report;
# - URL schemes and Default apps, in a scratch key: what's registered, what
#   stays someone else's, what's taken back from an app that registered
#   itself, what the shim refuses; and one private scheme in the real
#   HKCU\Software\Classes, followed through Windows, which `rm` removes.
#
#   bash tests/reach.sh [path\to\zigsaw.exe]
#
# Needs Git Bash and PowerShell. Opens a console window for a moment.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
work=$(cygpath -w "$(mktemp -d)")
ZIGSAW_HOME="$work\\store"
export ZIGSAW_HOME
export ZIGSAW_SHORTCUTS_DIR="$work\\links"
# Its own record of what stores changed: the rows below look at what's left of
# zigsaw in the real registry, which a real store's record would be part of.
export ZIGSAW_GRANTS_KEY="Software\\ZigsawTest\\reach-$$-grants"
classes="Software\\ZigsawTest\\reach-$$"
export ZIGSAW_CLASSES_KEY="$classes"
bin="$ZIGSAW_HOME\\bin"
scratch="$work\\cwd"
mkdir -p "$scratch"
# For the sandboxes that label what an app may write; a soft run's links are
# only links.
fake="$work\\folders"
for f in Documents; do mkdir -p "$fake\\$f"; done

failures=0
check() {
    local label=$1
    shift
    local out
    if out=$("$@" 2>&1); then
        printf 'ok    %s\n' "$label"
    else
        printf 'FAIL  %s\n      %s\n' "$label" "$(tail -1 <<<"$out" | cut -c1-150)"
        failures=$((failures + 1))
    fi
}
has() { grep -qF -- "$2" <<<"$1" || { echo "no \"$2\" in: $1"; return 1; }; }
hasnt() { ! grep -qF -- "$2" <<<"$1" || { echo "\"$2\" in: $1"; return 1; }; }

(cd "$root" && zig build && zig build hostprobe argv-echo gui-fixture) || { echo "building the test programs failed"; exit 1; }
cd "$scratch" || exit 1
for app in tool hold docs outer shared gui; do
    "$zigsaw" build "$root\\tests\\reach\\$app.json" >/dev/null 2>&1 || { echo "building $app failed"; exit 1; }
done

# in_run <run options...> -- <cmd.exe command>: runs it in test.reach.outer.
in_run() {
    local opts=()
    while [ "$1" != -- ]; do opts+=("$1"); shift; done
    shift
    printf '@%s\r\n' "$1" >"$work\\inner.cmd"
    "$zigsaw" run "${opts[@]}" --command=cmd test.reach.outer /c "$work\\inner.cmd" 2>&1
}

# --- --share=commands ---
commands_path() {
    local out
    out=$(in_run --share=commands -- 'echo %PATH%')
    has "$out" "System32\\Wbem;$bin" || return 1
}
check "commands: the store's bin is on PATH, after the system's" commands_path
commands_off() {
    local out
    out=$(in_run -- 'echo %PATH%')
    hasnt "$out" "$bin" || return 1
    out=$(in_run --share=commands --unshare=commands -- 'where reach-probe')
    hasnt "$out" "reach-probe.exe" || return 1
}
check "commands: not without it, nor after --unshare" commands_off
commands_own_app() {
    local out
    out=$(in_run --share=commands -- 'reach-probe')
    has "$out" "# integrity low" || return 1
    has "$out" "env USERPROFILE = $ZIGSAW_HOME\\data\\test.reach.tool\\home" || return 1
}
check "commands: a tool runs as its own app, with its data and its sandbox" commands_own_app
docs_link() { powershell -NoProfile -Command "(Get-Item -LiteralPath '$ZIGSAW_HOME\\data\\test.reach.docs\\home\\Documents' -ErrorAction SilentlyContinue).Target" | tr -d '\r'; }
# This store isn't the default one, so its apps don't get your real folders. In
# a throwaway account (tests/standard-user.sh), it's told they may: a tool's
# folders are then the user's, as the nested zigsaw finds them, not those of the
# app that started it. The tool asks for soft, so nothing's labelled.
if [ -n "${REACH_REAL_FOLDERS:-}" ]; then
    commands_folders() {
        local real target
        "$zigsaw" override --global --real-folders >/dev/null 2>&1 || return 1
        in_run --share=commands -- 'reach-docs' >/dev/null || return 1
        real=$(powershell -NoProfile -Command "[Environment]::GetFolderPath('MyDocuments')" | tr -d '\r')
        target=$(docs_link)
        "$zigsaw" override --reset --global >/dev/null 2>&1
        [ "$target" = "$real" ] || { echo "linked to \"$target\", not \"$real\""; return 1; }
    }
    check "commands: a tool's folders are yours, not the app's that started it" commands_folders
else
    commands_folders() {
        in_run --share=commands -- 'reach-docs' >/dev/null || return 1
        [ -z "$(docs_link)" ] || { echo "linked to \"$(docs_link)\""; return 1; }
    }
    check "commands: a tool in a store that isn't the default gets none of your folders" commands_folders
fi
commands_ends() {
    local out n
    in_run --share=commands -- 'start /b reach-hold & ping -n 3 127.0.0.1 >nul' >/dev/null
    sleep 1
    n=$(powershell -NoProfile -Command "@(Get-CimInstance Win32_Process -Filter \"Name='PING.EXE' AND CommandLine LIKE '%-n 47 %'\").Count" | tr -d '\r')
    [ "$n" = 0 ] || { echo "$n still running"; return 1; }
}
check "commands: a tool ends with the run that started it" commands_ends
commands_refused() {
    local out sb
    for sb in low appcontainer; do
        out=$(in_run --sandbox=$sb --share=commands -- 'echo %PATH%')
        hasnt "$out" "$bin" || return 1
        has "$out" "only under soft" || return 1
    done
}
check "commands: a low or AppContainer run doesn't get them, and says so" commands_refused
image_asks() {
    local out
    printf '@echo %%PATH%%\r\n' >"$work\\shared.cmd"
    out=$("$zigsaw" run --command=cmd test.reach.shared /c "$work\\shared.cmd" 2>&1)
    has "$out" "$bin" || return 1
    has "$out" "$ZIGSAW_HOME\\host" || return 1
}
check "an image may ask for commands and host" image_asks
override_saves() {
    local out
    "$zigsaw" override --share=commands test.reach.outer >/dev/null 2>&1 || return 1
    has "$("$zigsaw" override --show test.reach.outer 2>&1)" "--share=commands" || return 1
    out=$(in_run -- 'echo %PATH%')
    has "$out" "$bin" || return 1
    "$zigsaw" override --reset test.reach.outer >/dev/null 2>&1
}
check "an override may give them" override_saves

# --- --share=host ---
real_home=$(powershell -NoProfile -Command "[Environment]::GetFolderPath('UserProfile')" | tr -d '\r')
host_env() {
    local out sb
    for sb in soft low; do
        out=$(in_run --sandbox=$sb --share=host -- 'zigsaw-host cmd /c set USERPROFILE')
        has "$out" "USERPROFILE=$real_home" || return 1
        hasnt "$out" "$ZIGSAW_HOME" || return 1
    done
}
check "host: the program gets your real environment, under soft and low" host_env
host_rights() {
    local out
    out=$(in_run --sandbox=low --share=host -- "zigsaw-host \"$root\\zig-out\\test\\zigsaw-hostprobe.exe\"")
    has "$out" "# integrity low" || return 1
    out=$(in_run --share=host -- "zigsaw-host \"$root\\zig-out\\test\\zigsaw-hostprobe.exe\"")
    hasnt "$out" "# integrity low" || return 1
}
check "host: it keeps the run's rights: at low in a low run" host_rights
host_exit() {
    local code
    printf '@zigsaw-host cmd /c exit 9\r\n@exit /b %%errorlevel%%\r\n' >"$work\\inner.cmd"
    "$zigsaw" run --share=host --command=cmd test.reach.outer /c "$work\\inner.cmd" >/dev/null 2>&1
    code=$?
    [ "$code" = 9 ] || { echo "exit code $code"; return 1; }
}
check "host: its exit code comes back" host_exit
host_missing() {
    local out code
    printf '@zigsaw-host zigsaw-no-such-program\r\n@exit /b %%errorlevel%%\r\n' >"$work\\inner.cmd"
    out=$("$zigsaw" run --share=host --command=cmd test.reach.outer /c "$work\\inner.cmd" 2>&1)
    code=$?
    [ "$code" = 127 ] || { echo "exit code $code"; return 1; }
    has "$out" "isn't on your PATH" || return 1
}
check "host: a program it can't find is an error" host_missing
host_batch() {
    local out
    out=$(in_run --share=host -- "zigsaw-host \"$root\\tests\\reach\\echo.cmd\" \"a b\"")
    has "$out" 'batch got "a b"' || return 1
}
check "host: it runs a batch file" host_batch
host_off() {
    local out
    out=$(in_run -- 'where zigsaw-host')
    hasnt "$out" "zigsaw-host.exe" || return 1
    out=$(in_run --sandbox=appcontainer --share=host -- 'where zigsaw-host')
    hasnt "$out" "zigsaw-host.exe" || return 1
    has "$out" "doesn't get zigsaw-host" || return 1
}
check "host: not without it, nor in an AppContainer, which says so" host_off

# --- an image that can't run under a sandbox ---
warns() {
    local out
    out=$("$zigsaw" run --sandbox=appcontainer --command=cmd test.reach.outer /c ver 2>&1)
    has "$out" "warning: test.reach.outer can't run under the appcontainer sandbox: the test says it can't" || return 1
    has "$out" "--sandbox=soft" || return 1
    out=$("$zigsaw" run --command=cmd test.reach.outer /c ver 2>&1)
    hasnt "$out" "can't run under" || return 1
    out=$("$zigsaw" run --sandbox=low --command=cmd test.reach.outer /c ver 2>&1)
    hasnt "$out" "can't run under" || return 1
}
check "a run under a sandbox the image can't use warns, and others don't" warns
override_warns() {
    local out
    out=$("$zigsaw" override --sandbox=appcontainer test.reach.outer 2>&1)
    has "$out" "can't run under the appcontainer sandbox" || return 1
    "$zigsaw" override --reset test.reach.outer >/dev/null 2>&1
}
check "so does saving it as an override" override_warns
gui_reports() {
    local report="$work\\report.txt" record="$work\\gui-record.txt"
    rm -f "$report"
    "$zigsaw" override --sandbox=low test.reach.gui >/dev/null 2>&1
    ZIGSAW_SHIM_REPORT="$report" powershell -NoProfile -Command \
        "(Start-Process -FilePath '$bin\\reach-gui.exe' -ArgumentList '\"$record\" 3' -PassThru -Wait).ExitCode" >/dev/null
    "$zigsaw" override --reset test.reach.gui >/dev/null 2>&1
    grep -q "can't run under the low sandbox: the test says it can't" "$report" || { echo "report: $(cat "$report" 2>&1)"; return 1; }
}
check "and a GUI shim's report, when the run fails" gui_reports

# --- schemes, in a scratch key ---
reg_has() { reg query "HKCU\\$classes\\$1" ${2:+/v "$2"} >/dev/null 2>&1; }
reg_value() { powershell -NoProfile -Command "(Get-ItemProperty -LiteralPath 'HKCU:\\$classes\\$1' -ErrorAction Stop).'${2:-(default)}'" | tr -d '\r'; }
URL=test.reach.url
prog="Zigsaw.$URL.url.reachtest68"
urlshim="$ZIGSAW_HOME\\open\\$URL\\urls\\reach-open.exe"
# Someone else's scheme; a key an app wrote for itself from inside a run, as
# VSCodium's did; and another that nothing declares.
reg add "HKCU\\$classes\\reachtaken68" /v "URL Protocol" /t REG_SZ /d "" /f >/dev/null
reg add "HKCU\\$classes\\reachtaken68\\shell\\open\\command" /ve /t REG_SZ /d '"C:\Other\other.exe" "%1"' /f >/dev/null
for s in reachstale68 reachunclaimed68; do
    reg add "HKCU\\$classes\\$s" /v "URL Protocol" /t REG_SZ /d "" /f >/dev/null
    reg add "HKCU\\$classes\\$s\\shell\\open\\command" /ve /t REG_SZ /d "\"$ZIGSAW_HOME\\deploy\\abc\\app.exe\" --open-url -- \"%1\"" /f >/dev/null
done
build_out=$("$zigsaw" build "$root\\tests\\reach\\url.json" 2>&1)
registered() {
    has "$build_out" "opens    .reachtest, " || return 1
    has "$build_out" "reachtest68:" || return 1
    has "$build_out" "offered  for" || return 1
    has "$(reg_value "reachtest68\\shell\\open\\command")" "$urlshim" || return 1
    reg_has reachtest68 "URL Protocol" || { echo "no URL Protocol"; return 1; }
    has "$(reg_value reachtest68)" "URL:Zigsaw test link" || return 1
    reg_has "$prog" "URL Protocol" || { echo "no key for the app"; return 1; }
    [ -f "$urlshim" ] || { echo "no shim"; return 1; }
}
check "a free scheme is registered, with a key for the app and a shim" registered
default_apps() {
    local caps="Apps\\$URL\\Capabilities"
    has "$(reg_value RegisteredApplications "Zigsaw.$URL")" "$classes\\$caps" || return 1
    [ "$(reg_value "$caps" ApplicationName)" = "Zigsaw link test" ] || return 1
    [ "$(reg_value "$caps" ApplicationDescription)" = "Records the link it was given" ] || return 1
    [ "$(reg_value "$caps\\URLAssociations" reachtest68)" = "$prog" ] || return 1
    [ "$(reg_value "$caps\\URLAssociations" http)" = "Zigsaw.$URL.url.http" ] || return 1
    [ "$(reg_value "$caps\\FileAssociations" .reachtest)" = "Zigsaw.$URL.reachtest" ] || return 1
}
check "the app is listed for Default apps, with its schemes and file types" default_apps
http_offered() {
    ! reg_has http || { echo "it took http's own key"; return 1; }
    reg_has "Zigsaw.$URL.url.http" "URL Protocol" || { echo "no key for the app"; return 1; }
    has "$build_out" "http:" || return 1
}
check "http, which Windows has, is only offered" http_offered
taken_stays() {
    has "$(reg_value "reachtaken68\\shell\\open\\command")" 'C:\Other\other.exe' || return 1
    ! reg_has reachtaken68 ZigsawStore || { echo "it took the key"; return 1; }
    has "$(reg_value "Zigsaw.$URL.url.reachtaken68\\shell\\open\\command")" "$urlshim" || return 1
}
check "a scheme something else has stays as it is, and is offered" taken_stays
stale_taken() {
    has "$(reg_value "reachstale68\\shell\\open\\command")" "$urlshim" || return 1
    reg_has reachstale68 ZigsawStore || { echo "it isn't the store's now"; return 1; }
}
check "a key an app wrote for itself, naming its deployment, is taken over" stale_taken
stale_repaired() {
    local out
    reg_has reachunclaimed68 || { echo "it's gone too early"; return 1; }
    out=$("$zigsaw" repair 2>&1)
    ! reg_has reachunclaimed68 || { echo "repair left it: $out"; return 1; }
    reg_has reachtaken68 || { echo "repair took someone else's"; return 1; }
    reg_has reachtest68 || { echo "repair took the app's own"; return 1; }
}
check "repair removes such a key that no app declares, and nothing else" stale_repaired

opens_link() {
    local record="$ZIGSAW_HOME\\data\\$URL\\record.txt"
    rm -f "$record"
    "$urlshim" 'reachtest68://a/b?c=1&d=2' >/dev/null 2>&1 || { echo "exit code $?"; return 1; }
    has "$(cat "$record")" 'reachtest68://a/b?c=1&d=2' || return 1
    rm -f "$record"
    "$urlshim" 'HTTP://example.test/x y' >/dev/null 2>&1 || { echo "exit code $?"; return 1; }
    has "$(cat "$record")" 'HTTP://example.test/x y' || return 1
}
check "a scheme's shim passes on a link of it, in any case" opens_link
refuses() {
    local record="$ZIGSAW_HOME\\data\\$URL\\record.txt" out
    rm -f "$record"
    out=$("$urlshim" 'reachtest68://a' --gpu-launcher=calc 2>&1) && { echo "two arguments were taken"; return 1; }
    has "$out" "came as several" || return 1
    out=$("$urlshim" --gpu-launcher=calc 2>&1) && { echo "a switch was taken"; return 1; }
    has "$out" "isn't one" || return 1
    out=$("$urlshim" 'https://example.test/' 2>&1) && { echo "another scheme was taken"; return 1; }
    out=$("$urlshim" 2>&1) && { echo "nothing was taken"; return 1; }
    [ ! -e "$record" ] || { echo "the app ran: $(cat "$record")"; return 1; }
}
check "and refuses several arguments, a switch, and other schemes" refuses
listed() {
    local out
    out=$("$zigsaw" list 2>&1)
    has "$out" "reachtest68:" || return 1
    has "$out" ".reachtest" || return 1
}
check "list shows them" listed
narrowed() {
    local out
    out=$("$zigsaw" build "$root\\tests\\reach\\url2.json" 2>&1)
    has "$out" "no longer opens" || return 1
    ! reg_has "Zigsaw.$URL.url.http" || { echo "http's still there"; return 1; }
    ! reg_has "Zigsaw.$URL.url.reachtaken68" || { echo "the offer's still there"; return 1; }
    reg_has reachtaken68 || { echo "someone else's went too"; return 1; }
    ! reg_has reachstale68 || { echo "what it took over stays"; return 1; }
    reg_has reachtest68 || { echo "what it still declares went"; return 1; }
    ! reg_has "Apps\\$URL\\Capabilities\\FileAssociations" || { echo "file types are still listed"; return 1; }
    [ ! -e "$ZIGSAW_HOME\\open\\$URL\\reach-open.exe" ] || { echo "the file type's shim stays"; return 1; }
    [ -f "$urlshim" ] || { echo "the scheme's shim went"; return 1; }
}
check "an update takes back what it no longer declares, and only that" narrowed
removed() {
    local out
    out=$("$zigsaw" rm "$URL" 2>&1)
    has "$out" "no longer opens reachtest68:" || return 1
    ! reg_has reachtest68 || { echo "the scheme stays"; return 1; }
    ! reg_has "$prog" || { echo "the app's key stays"; return 1; }
    ! reg_has "Apps\\$URL" || { echo "Default apps' key stays"; return 1; }
    ! reg_has RegisteredApplications "Zigsaw.$URL" || { echo "it's still registered"; return 1; }
    reg_has reachtaken68 || { echo "someone else's went too"; return 1; }
    [ ! -e "$ZIGSAW_HOME\\open\\$URL" ] || { echo "its shims stay"; return 1; }
}
check "rm removes all of that" removed
not_default() {
    local out
    out=$(ZIGSAW_CLASSES_KEY='' "$zigsaw" build "$root\\tests\\reach\\url2.json" 2>&1)
    has "$out" "opens    nothing: only the default store" || return 1
    ZIGSAW_CLASSES_KEY='' "$zigsaw" rm "$URL" >/dev/null 2>&1
}
check "a store other than the default one registers nothing" not_default

# --- one private scheme, in the real classes, followed through Windows ---
REAL=test.reach.real
real_key='HKCU\Software\Classes\reachreal68'
registered_key='HKCU\Software\RegisteredApplications'
through_windows() {
    local record="$ZIGSAW_HOME\\data\\$REAL\\record.txt" i
    ZIGSAW_CLASSES_KEY='Software\Classes' "$zigsaw" build "$root\\tests\\reach\\real.json" >/dev/null 2>&1 || { echo "building it failed"; return 1; }
    reg query "$real_key" /v "URL Protocol" >/dev/null 2>&1 || { echo "not registered"; return 1; }
    reg query "$registered_key" /v "Zigsaw.$REAL" >/dev/null 2>&1 || { echo "not on Windows' list"; return 1; }
    powershell -NoProfile -Command "Start-Process 'reachreal68://hello/there?a=1&b=2'" || return 1
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$record" ] && break; sleep 0.5; done
    has "$(cat "$record" 2>&1)" 'reachreal68://hello/there?a=1&b=2' || return 1
}
check "a link Windows follows reaches the app, through its shim" through_windows
injected() {
    local record="$ZIGSAW_HOME\\data\\$REAL\\record.txt" i
    rm -f "$record"
    # What Electron's CVE-2018-1000006 was: Windows encodes or splits a quote.
    powershell -NoProfile -Command "Start-Process 'reachreal68://x\" --evil \"y'" || return 1
    for i in 1 2 3 4 5 6; do [ -s "$record" ] && break; sleep 0.5; done
    [ -e "$record" ] || return 0
    hasnt "$(cat "$record")" '--evil"' || return 1
}
check "a quote in a link doesn't give the app another argument" injected
real_removed() {
    ZIGSAW_CLASSES_KEY='Software\Classes' "$zigsaw" rm --delete-data "$REAL" >/dev/null 2>&1 || return 1
    ! reg query "$real_key" >/dev/null 2>&1 || { echo "the scheme stays"; return 1; }
    ! reg query "$registered_key" /v "Zigsaw.$REAL" >/dev/null 2>&1 || { echo "still on Windows' list"; return 1; }
    ! reg query 'HKCU\Software\Zigsaw' >/dev/null 2>&1 || { echo "HKCU\\Software\\Zigsaw stays"; return 1; }
    reg query "$registered_key" >/dev/null 2>&1 || { echo "Windows' list went"; return 1; }
}
check "rm takes it all out of the real registry" real_removed

cd "$root" || exit 1
check "no run labelled or granted the repository" sh -c "! icacls '$root' | grep -q -e 'Mandatory Label' -e 'S-1-15-'"
reg delete "HKCU\\$classes" /f >/dev/null 2>&1
reg query 'HKCU\Software\ZigsawTest' 2>/dev/null | grep -q . || reg delete 'HKCU\Software\ZigsawTest' /f >/dev/null 2>&1
rm -rf "$work" 2>/dev/null
echo
echo "$failures check(s) failed."
exit $((failures > 0))
