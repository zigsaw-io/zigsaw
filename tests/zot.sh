#!/usr/bin/env bash
# Runs a command with two local zot registries (https://zotregistry.dev), as
# tests/registry.sh wants them: one on localhost:5000 without logins, and one
# on localhost:5001 that wants a login, with AUTH_REGISTRY, AUTH_USER and
# AUTH_PASSWORD set for it. The password is new each time, and the
# registries and what they stored are gone afterwards.
#
#   tests/zot.sh <path\to\zot.exe> <command> [args...]
#   e.g. tests/zot.sh bin/zot.exe bash tests/registry.sh
#
# Needs Git Bash, curl, and zig, for the password's bcrypt hash.

set -u
zot=$1
shift
root=$(cd "$(dirname "$0")/.." && pwd)
dir=$(mktemp -d)
user=zigsaw-test
password="test-$RANDOM$RANDOM$RANDOM"
zig run "$root/tests/htpasswd.zig" -- "$user" "$password" >"$dir/htpasswd" || { echo "making the htpasswd file failed"; exit 1; }

# config <port> <more "http" settings>
config() {
    printf '{ "distSpecVersion": "1.1.1", "storage": { "rootDirectory": "%s" },\n  "http": { "address": "127.0.0.1", "port": "%s"%s }, "log": { "level": "warn" } }\n' \
        "$(cygpath -m "$dir/data-$1")" "$1" "$2" >"$dir/zot-$1.json"
}
config 5000 ""
config 5001 ", \"auth\": { \"htpasswd\": { \"path\": \"$(cygpath -m "$dir/htpasswd")\" } }"
"$zot" serve "$(cygpath -w "$dir/zot-5000.json")" >"$dir/zot-5000.log" 2>&1 &
plain=$!
"$zot" serve "$(cygpath -w "$dir/zot-5001.json")" >"$dir/zot-5001.log" 2>&1 &
login=$!

# Up when the plain one answers, and the other asks for a login.
up=false
for _ in $(seq 60); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5000/v2/)" = 200 ] &&
        [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5001/v2/)" = 401 ]; then
        up=true
        break
    fi
    sleep 0.5
done
if $up; then
    AUTH_REGISTRY=localhost:5001 AUTH_USER=$user AUTH_PASSWORD=$password "$@"
    code=$?
else
    echo "zot didn't start:"
    cat "$dir"/zot-*.log
    code=1
fi
kill $plain $login 2>/dev/null
wait 2>/dev/null
rm -rf "$dir"
exit $code
