# What the scripts that sign have in common: sourced, not run.
#
# They use cosign's program from a store, as it is there, and not `zigsaw run`: what
# they'd give a run goes on a command line, which the passphrase mustn't, and a low run
# would label the key's folder so that any low program may write in it. It only does
# the arithmetic: nothing it runs here reaches a registry or the internet.

# cosign's program, in the store: COSIGN names another.
find_cosign() {
    [ -z "${COSIGN:-}" ] || { printf '%s\n' "$COSIGN"; return; }
    local store=${ZIGSAW_HOME:-$LOCALAPPDATA\\zigsaw} found
    found=$(find "$(cygpath -u "$store\\deploy")" -maxdepth 2 -iname cosign.exe 2>/dev/null | head -1)
    [ -n "$found" ] || { echo "error: no cosign in $store: run \`zigsaw pull dev.sigstore.cosign\` first, or set COSIGN" >&2; return 1; }
    printf '%s\n' "$found"
}

# Checks COSIGN_KEY names a file, and writes it as cosign can read it, however it was
# written: cosign is no Git Bash program, so it can't read /e/keys/cosign.key. Says what
# looks wrong if it doesn't. A key's file name is all this ever looks at.
check_key() {
    if [ -z "${COSIGN_KEY:-}" ]; then
        echo "error: COSIGN_KEY must name the key: see scripts/signing-key.sh" >&2
        exit 2
    fi
    if [ -f "$COSIGN_KEY" ]; then
        COSIGN_KEY=$(cygpath -w "$COSIGN_KEY")
        export COSIGN_KEY
        return
    fi
    echo "error: no key at \"$COSIGN_KEY\"" >&2
    case $COSIGN_KEY in
    *\\* | */*)
        local dir
        dir=$COSIGN_KEY
        [ -d "$dir" ] || dir=$(dirname "$(cygpath -u "$COSIGN_KEY")")
        if [ -d "$COSIGN_KEY" ]; then echo "  That's a folder: name the key's file in it." >&2; fi
        if [ -d "$dir" ]; then
            local found
            found=$(cd "$dir" && ls -- *.key 2>/dev/null | tr '\n' ' ')
            echo "  In that folder, .key files: ${found:-none}" >&2
        else
            echo "  There's no such folder." >&2
        fi
        ;;
    *) echo "  It has no slashes. If you wrote some, Git Bash ate them: put it in single quotes, COSIGN_KEY='E:\\keys\\cosign.key'" >&2 ;;
    esac
    exit 2
}

# The passphrase of the key, for this script and what it starts, once.
ask_passphrase() {
    [ -z "${COSIGN_PASSWORD:-}" ] || return 0
    IFS= read -rs -p "Passphrase of the key: " COSIGN_PASSWORD
    echo
    export COSIGN_PASSWORD
}

# sign_blob <file> <signature file>: as cosign does, with the key in COSIGN_KEY, and
# with no Sigstore: nothing's logged anywhere, and a signature stands by itself.
sign_blob() {
    "$cosign" sign-blob --key "$COSIGN_KEY" --new-bundle-format=false --use-signing-config=false \
        --tlog-upload=false --yes --output-signature "$2" "$1" >/dev/null 2>"$2.log" ||
        { echo "error: cosign couldn't sign: $(tail -1 "$2.log")" >&2; rm -f "$2.log"; return 1; }
    rm -f "$2.log"
}
