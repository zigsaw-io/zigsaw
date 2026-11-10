#!/usr/bin/env bash
# A Sigstore of its own, for tests: a certificate authority standing in for Fulcio,
# keys standing in for Rekor's two logs (v1's ECDSA, v2's Ed25519) and a timestamp
# authority, made with openssl, and bundles as `cosign sign-blob --bundle` makes
# them keyless (bundle v0.3), signed by a certificate naming whichever workflow a
# test wants. Nothing here reaches the internet, and a zigsaw only takes its root if
# it was built with -Dsigstore-test-root.
#
#   tests/fake-sigstore.sh <dir> init
#       makes the authorities and the logs' keys in <dir>, and <dir>/root.json, a
#       trusted root as Sigstore's TUF repository hands out
#   tests/fake-sigstore.sh <dir> sign <file> <identity> [<issuer>] [<time>]
#       prints a bundle for <file>, its certificate's subject alternative name
#       being <identity> (a workflow's URI), its issuer extension <issuer>
#       (GitHub Actions' by default).
#       By default, as Rekor v1 logs: a hashedrekord 0.0.1 entry, the log's
#       promise of the time <time> (seconds since 1970, now by default), and its
#       proof, in a tree of two, with a checkpoint. The certificate is good for a
#       day from when it's made, so a <time> past that is a signature made with a
#       certificate that had expired.
#       With FAKE_REKOR=2, as Rekor v2 logs: a hashedrekord 0.0.2 entry, its proof
#       and checkpoint, no time of the log's, and the timestamp authority's
#       RFC 3161 timestamp of the signature, which is always now (<time> is
#       ignored). FAKE_LEAF_EXPIRED=1 makes a certificate that expired a day
#       before it was made, so one that wasn't good when it signed.
#
# Needs Git Bash and openssl (3.2 or later). openssl says nothing unless it fails,
# and then why: a quiet failure here is a test's row failing with no output.

set -euo pipefail
# openssl may be a Windows program, so nothing on its command line is rewritten as a
# path ("/CN=..." isn't one), and every path is C:/-style, which both sides read.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
usage="usage: tests/fake-sigstore.sh <dir> init | sign <file> <identity> [<issuer>] [<time>]"
[ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
command=$2
mkdir -p "$1"
dir=$(cygpath -m "$1")
shift 2
b64() { base64 -w0; }
# Hex on stdin, as bytes on stdout.
unhex() { local h; h=$(cat); printf '%b' "$(printf '%s' "$h" | sed 's/../\\x&/g')"; }
sha256_hex() { openssl dgst -sha256 -binary | od -An -v -tx1 | tr -d ' \n'; }
# Runs a command that writes its files itself, and shows what it said only if it fails.
quiet() {
    local said
    said=$("$@" 2>&1 >/dev/null) || { printf '%s failed:\n%s\n' "$*" "$said" >&2; return 1; }
}

# The names the logs go by: v1's is its URL's host; v2's checkpoints say it, and a
# signed note's key id is made from it.
v1_name=rekor.invalid
v2_name=rekor2.invalid

case $command in
init)
    quiet openssl ecparam -name secp384r1 -genkey -noout -out "$dir/ca.key"
    quiet openssl req -x509 -new -key "$dir/ca.key" -sha384 -subj "/O=zigsaw tests/CN=fake fulcio" -days 3650 \
        -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
        -out "$dir/ca.pem"
    # Rekor v1's log key, and v2's.
    quiet openssl ecparam -name prime256v1 -genkey -noout -out "$dir/rekor.key"
    quiet openssl ec -in "$dir/rekor.key" -pubout -outform DER -out "$dir/rekor.der"
    quiet openssl genpkey -algorithm ed25519 -out "$dir/rekor2.key"
    quiet openssl pkey -in "$dir/rekor2.key" -pubout -outform DER -out "$dir/rekor2.der"
    # The timestamp authority: a root, and the certificate it signs with, for time
    # stamping only, as Sigstore's is (P-384, signing with SHA-256).
    quiet openssl ecparam -name secp384r1 -genkey -noout -out "$dir/tsa-root.key"
    quiet openssl req -x509 -new -key "$dir/tsa-root.key" -sha384 -subj "/O=zigsaw tests/CN=fake tsa root" -days 3650 \
        -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
        -out "$dir/tsa-root.pem"
    quiet openssl ecparam -name secp384r1 -genkey -noout -out "$dir/tsa.key"
    quiet openssl req -new -key "$dir/tsa.key" -subj "/O=zigsaw tests/CN=fake tsa" -out "$dir/tsa.csr"
    printf '[ext]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,timeStamping\n' >"$dir/tsa.cnf"
    quiet openssl x509 -req -in "$dir/tsa.csr" -CA "$dir/tsa-root.pem" -CAkey "$dir/tsa-root.key" -sha384 -days 3650 \
        -set_serial 1 -extfile "$dir/tsa.cnf" -extensions ext -out "$dir/tsa.pem"
    rm -f "$dir/tsa.csr" "$dir/tsa.cnf"

    ca=$(openssl x509 -in "$dir/ca.pem" -outform DER | b64)
    rekor=$(b64 <"$dir/rekor.der")
    log_id=$(openssl dgst -sha256 -binary "$dir/rekor.der" | b64)
    rekor2=$(b64 <"$dir/rekor2.der")
    # A signed note's key id: SHA-256 of the name, a newline, 0x01 (Ed25519), the key.
    log2_id=$({ printf '%s\n\001' "$v2_name"; tail -c 32 "$dir/rekor2.der"; } | openssl dgst -sha256 -binary | b64)
    tsa=$(openssl x509 -in "$dir/tsa.pem" -outform DER | b64)
    tsa_root=$(openssl x509 -in "$dir/tsa-root.pem" -outform DER | b64)
    cat >"$dir/root.json" <<EOF
{"mediaType":"application/vnd.dev.sigstore.trustedroot+json;version=0.1","tlogs":[{"baseUrl":"https://$v1_name","hashAlgorithm":"SHA2_256","publicKey":{"rawBytes":"$rekor","keyDetails":"PKIX_ECDSA_P256_SHA_256","validFor":{"start":"2020-01-01T00:00:00Z"}},"logId":{"keyId":"$log_id"}},{"baseUrl":"https://$v2_name","hashAlgorithm":"SHA2_256","publicKey":{"rawBytes":"$rekor2","keyDetails":"PKIX_ED25519","validFor":{"start":"2020-01-01T00:00:00Z"}},"logId":{"keyId":"$log2_id"}}],"certificateAuthorities":[{"subject":{"organization":"zigsaw tests","commonName":"fake fulcio"},"uri":"https://fulcio.invalid","certChain":{"certificates":[{"rawBytes":"$ca"}]},"validFor":{"start":"2020-01-01T00:00:00Z"}}],"timestampAuthorities":[{"subject":{"organization":"zigsaw tests","commonName":"fake tsa"},"uri":"https://tsa.invalid","certChain":{"certificates":[{"rawBytes":"$tsa"},{"rawBytes":"$tsa_root"}]},"validFor":{"start":"2020-01-01T00:00:00Z"}}]}
EOF
    ;;
sign)
    [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
    file=$(cygpath -m "$1")
    identity=$2
    issuer=${3:-https://token.actions.githubusercontent.com}
    time=${4:-}
    rekor=${FAKE_REKOR:-1}
    work=$(cygpath -m "$(mktemp -d)")
    trap 'rm -rf "$work"' EXIT
    quiet openssl ecparam -name prime256v1 -genkey -noout -out "$work/leaf.key"
    quiet openssl req -new -key "$work/leaf.key" -subj "/" -out "$work/leaf.csr"
    cat >"$work/ext.cnf" <<EOF
[ext]
subjectAltName=critical,URI:$identity
keyUsage=critical,digitalSignature
extendedKeyUsage=codeSigning
1.3.6.1.4.1.57264.1.8=ASN1:UTF8String:$issuer
EOF
    if [ "${FAKE_LEAF_EXPIRED:-}" = 1 ]; then
        # Good from two days ago to one day ago. Not with x509 -days -1, whose end
        # before its start OpenSSL 3.6 refuses ("end date before start date"), and
        # -not_before isn't in 3.2: openssl ca takes both dates, in any 3.x.
        : >"$work/index.txt"
        openssl rand -hex 16 >"$work/serial"
        printf '[ca]\ndefault_ca=fake\n[fake]\ndatabase=%s\nnew_certs_dir=%s\nserial=%s\ndefault_md=sha384\npolicy=any\nunique_subject=no\n[any]\n' \
            "$work/index.txt" "$work" "$work/serial" >"$work/ca.cnf"
        quiet openssl ca -batch -notext -config "$work/ca.cnf" -cert "$dir/ca.pem" -keyfile "$dir/ca.key" -in "$work/leaf.csr" \
            -startdate "$(date -u -d '2 days ago' +%Y%m%d%H%M%SZ)" -enddate "$(date -u -d '1 day ago' +%Y%m%d%H%M%SZ)" \
            -extfile "$work/ext.cnf" -extensions ext -out "$work/leaf.pem"
    else
        quiet openssl x509 -req -in "$work/leaf.csr" -CA "$dir/ca.pem" -CAkey "$dir/ca.key" -sha384 -days 1 \
            -set_serial "0x$(openssl rand -hex 16)" -extfile "$work/ext.cnf" -extensions ext -out "$work/leaf.pem"
    fi
    # Now, once the certificate is made: its notBefore is when it was, to the second,
    # and a time read before it could fall a second earlier, before it was good.
    [ -n "$time" ] || time=$(date +%s)
    openssl dgst -sha256 -sign "$work/leaf.key" -out "$work/sig.der" "$file"
    signature=$(b64 <"$work/sig.der")
    hash=$(sha256_hex <"$file")
    digest=$(openssl dgst -sha256 -binary "$file" | b64)
    certificate=$(openssl x509 -in "$work/leaf.pem" -outform DER | b64)
    pem=$(b64 <"$work/leaf.pem")
    if [ "$rekor" = 2 ]; then
        body=$(printf '{"apiVersion":"0.0.2","kind":"hashedrekord","spec":{"hashedRekordV002":{"data":{"algorithm":"SHA2_256","digest":"%s"},"signature":{"content":"%s","verifier":{"x509Certificate":{"rawBytes":"%s"},"keyDetails":"PKIX_ECDSA_P256_SHA_256"}}}}}' "$digest" "$signature" "$certificate")
        log_name=$v2_name
        origin=$v2_name
        log_id=$({ printf '%s\n\001' "$v2_name"; tail -c 32 "$dir/rekor2.der"; } | openssl dgst -sha256 -binary | b64)
    else
        body=$(printf '{"apiVersion":"0.0.1","kind":"hashedrekord","spec":{"data":{"hash":{"algorithm":"sha256","value":"%s"}},"signature":{"content":"%s","publicKey":{"content":"%s"}}}}' "$hash" "$signature" "$pem")
        log_name=$v1_name
        origin="$v1_name - 1234"
        log_id=$(openssl dgst -sha256 -binary "$dir/rekor.der" | b64)
    fi
    body64=$(printf '%s' "$body" | b64)

    # The log: a tree of two leaves, this entry's and another, either way round.
    leaf=$({ printf '\000'; printf '%s' "$body"; } | sha256_hex)
    other=$(openssl rand -hex 32)
    index=$((RANDOM % 2))
    if [ $index = 0 ]; then pair="01$leaf$other"; else pair="01$other$leaf"; fi
    root=$(printf '%s' "$pair" | unhex | openssl dgst -sha256 -binary | b64)
    printf '%s\n2\n%s\n' "$origin" "$root" >"$work/note"
    hint=$(printf '%s' "$log_id" | base64 -d | head -c 4 | od -An -v -tx1 | tr -d ' \n')
    if [ "$rekor" = 2 ]; then
        openssl pkeyutl -sign -inkey "$dir/rekor2.key" -rawin -in "$work/note" -out "$work/note.sig"
    else
        openssl dgst -sha256 -sign "$dir/rekor.key" -out "$work/note.sig" "$work/note"
    fi
    note_sig=$({ printf '%s' "$hint" | unhex; cat "$work/note.sig"; } | b64)
    # As JSON: the note's newlines escaped, and its dash (U+2014) as it is.
    envelope="$(sed 's/$/\\n/' "$work/note" | tr -d '\n')\\n— $log_name $note_sig\\n"
    proof=$(printf '{"logIndex":"%s","rootHash":"%s","treeSize":"2","hashes":["%s"],"checkpoint":{"envelope":"%s"}}' \
        "$index" "$root" "$(printf '%s' "$other" | unhex | b64)" "$envelope")

    if [ "$rekor" = 2 ]; then
        # The timestamp authority's word for when it saw the signature.
        printf '01\n' >"$work/serial"
        cat >"$work/ts.cnf" <<EOF
[tsa]
default_tsa = fake
[fake]
serial = $work/serial
signer_cert = $dir/tsa.pem
signer_key = $dir/tsa.key
signer_digest = sha256
default_policy = 1.3.6.1.4.1.57264.2
digests = sha256, sha384, sha512
accuracy = secs:1
ess_cert_id_alg = sha256
EOF
        quiet openssl ts -query -data "$work/sig.der" -sha256 -no_nonce -out "$work/ts.tsq"
        quiet openssl ts -reply -config "$work/ts.cnf" -queryfile "$work/ts.tsq" -out "$work/ts.tsr"
        stamp=$(b64 <"$work/ts.tsr")
        printf '{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json","verificationMaterial":{"certificate":{"rawBytes":"%s"},"tlogEntries":[{"logIndex":"%s","logId":{"keyId":"%s"},"kindVersion":{"kind":"hashedrekord","version":"0.0.2"},"inclusionProof":%s,"canonicalizedBody":"%s"}],"timestampVerificationData":{"rfc3161Timestamps":[{"signedTimestamp":"%s"}]}},"messageSignature":{"messageDigest":{"algorithm":"SHA2_256","digest":"%s"},"signature":"%s"}}\n' \
            "$certificate" "$index" "$log_id" "$proof" "$body64" "$stamp" "$digest" "$signature"
    else
        log_hex=$(sha256_hex <"$dir/rekor.der")
        printf '{"body":"%s","integratedTime":%s,"logID":"%s","logIndex":%s}' "$body64" "$time" "$log_hex" "$index" >"$work/set"
        set_signature=$(openssl dgst -sha256 -sign "$dir/rekor.key" "$work/set" | b64)
        printf '{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json","verificationMaterial":{"certificate":{"rawBytes":"%s"},"tlogEntries":[{"logIndex":"%s","logId":{"keyId":"%s"},"kindVersion":{"kind":"hashedrekord","version":"0.0.1"},"integratedTime":"%s","inclusionPromise":{"signedEntryTimestamp":"%s"},"inclusionProof":%s,"canonicalizedBody":"%s"}]},"messageSignature":{"messageDigest":{"algorithm":"SHA2_256","digest":"%s"},"signature":"%s"}}\n' \
            "$certificate" "$index" "$log_id" "$time" "$set_signature" "$proof" "$body64" "$digest" "$signature"
    fi
    ;;
*)
    echo "$usage" >&2
    exit 2
    ;;
esac
