#!/usr/bin/env bash
# Checks that no script or workflow calls zigsaw by a command name it had before
# 0.105, when its commands were Docker's: those fail now, saying the new name
# (main.zig's movedCommand). v0.105.0's Release signed nothing because
# scripts/sign-release.sh still pulled cosign with `zigsaw pull`, on a line no
# test reaches.
#
#   scripts/check-commands.sh
#
# A call is a word ending in "zigsaw" or "zigsaw.exe" (a path or a variable,
# quoted or not) followed by the command; comments don't count. tests/ isn't
# looked at: its suites run the zigsaw they test, so an old name fails there
# by itself, and some call old names on purpose to see them fail. Needs grep
# and bash; reads nothing but scripts/ and .github/.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
moved='pull|push|rm|prune|ls|cat|stop|exec|hold|unhold|grants|login|logout|trust|signature'
call="[Zz][Ii][Gg][Ss][Aa][Ww](\\.exe)?[\"'}]*[ ]+($moved)([ \"')]|\$)"

found=$(cd "$root" && grep -nE "$call" scripts/*.sh scripts/*.ps1 .github/workflows/*.yml 2>/dev/null |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [ -n "$found" ]; then
    echo "These call zigsaw by a name it no longer has (\`zigsaw help\` lists the new ones):"
    echo "$found"
    exit 1
fi
echo "ok: no script or workflow calls zigsaw by a name from before 0.105"
