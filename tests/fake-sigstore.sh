#!/usr/bin/env bash
# A Sigstore of its own, for tests: a certificate authority standing in for Fulcio
# and a key standing in for Rekor's, made with openssl, and bundles as
# `cosign sign-blob --bundle` makes them keyless (bundle v0.3, a hashedrekord
# 0.0.1 entry with its signed entry timestamp), signed by a certificate naming
# whichever workflow a test wants. Nothing here reaches the internet, and a
# zigsaw only takes its root if it was built with -Dsigstore-test-root.
#
#   tests/fake-sigstore.sh <dir> init
#       makes the authority and the log's key in <dir>, and <dir>/root.json, a
#       trusted root as Sigstore's TUF repository hands out
#   tests/fake-sigstore.sh <dir> sign <file> <identity> [<issuer>] [<time>]
#       prints a bundle for <file>, its certificate's subject alternative name
#       being <identity> (a workflow's URI), its issuer extension <issuer>
#       (GitHub Actions' by default), and the log's time <time> (seconds since
#       1970, now by default). The certificate is good for a day from now, so
#       a <time> past that is a signature made with a certificate that had
#       expired.
#
# Needs Git Bash and openssl.

set -euo pipefail
# openssl may be a Windows program, so nothing on its command line is rewritten as a
# path ("/CN=..." isn't one), and every path is C:/-style, which both sides read.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
[ $# -ge 2 ] || { echo "usage: tests/fake-sigstore.sh <dir> init | sign <file> <identity> [<issuer>] [<time>]" >&2; exit 2; }
command=$2
mkdir -p "$1"
dir=$(cygpath -m "$1")
shift 2
b64() { base64 -w0; }

case $command in
init)
    openssl ecparam -name secp384r1 -genkey -noout -out "$dir/ca.key" 2>/dev/null
    openssl req -x509 -new -key "$dir/ca.key" -sha384 -subj "/O=zigsaw tests/CN=fake fulcio" -days 3650 \
        -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
        -out "$dir/ca.pem" 2>/dev/null
    openssl ecparam -name prime256v1 -genkey -noout -out "$dir/rekor.key" 2>/dev/null
    openssl ec -in "$dir/rekor.key" -pubout -outform DER -out "$dir/rekor.der" 2>/dev/null
    ca=$(openssl x509 -in "$dir/ca.pem" -outform DER | b64)
    rekor=$(b64 <"$dir/rekor.der")
    log_id=$(openssl dgst -sha256 -binary "$dir/rekor.der" | b64)
    cat >"$dir/root.json" <<EOF
{"mediaType":"application/vnd.dev.sigstore.trustedroot+json;version=0.1","tlogs":[{"baseUrl":"https://rekor.invalid","hashAlgorithm":"SHA2_256","publicKey":{"rawBytes":"$rekor","keyDetails":"PKIX_ECDSA_P256_SHA_256","validFor":{"start":"2020-01-01T00:00:00Z"}},"logId":{"keyId":"$log_id"}}],"certificateAuthorities":[{"subject":{"organization":"zigsaw tests","commonName":"fake fulcio"},"uri":"https://fulcio.invalid","certChain":{"certificates":[{"rawBytes":"$ca"}]},"validFor":{"start":"2020-01-01T00:00:00Z"}}]}
EOF
    ;;
sign)
    [ $# -ge 2 ] || { echo "usage: tests/fake-sigstore.sh <dir> sign <file> <identity> [<issuer>] [<time>]" >&2; exit 2; }
    file=$(cygpath -m "$1")
    identity=$2
    issuer=${3:-https://token.actions.githubusercontent.com}
    time=${4:-$(date +%s)}
    work=$(cygpath -m "$(mktemp -d)")
    trap 'rm -rf "$work"' EXIT
    openssl ecparam -name prime256v1 -genkey -noout -out "$work/leaf.key" 2>/dev/null
    openssl req -new -key "$work/leaf.key" -subj "/" -out "$work/leaf.csr" 2>/dev/null
    cat >"$work/ext.cnf" <<EOF
[ext]
subjectAltName=critical,URI:$identity
keyUsage=critical,digitalSignature
extendedKeyUsage=codeSigning
1.3.6.1.4.1.57264.1.8=ASN1:UTF8String:$issuer
EOF
    openssl x509 -req -in "$work/leaf.csr" -CA "$dir/ca.pem" -CAkey "$dir/ca.key" -sha384 -days 1 \
        -set_serial "0x$(openssl rand -hex 16)" -extfile "$work/ext.cnf" -extensions ext -out "$work/leaf.pem" 2>/dev/null
    signature=$(openssl dgst -sha256 -sign "$work/leaf.key" "$file" | b64)
    hash=$(sha256sum <"$file" | cut -d' ' -f1)
    digest=$(openssl dgst -sha256 -binary "$file" | b64)
    certificate=$(openssl x509 -in "$work/leaf.pem" -outform DER | b64)
    pem=$(b64 <"$work/leaf.pem")
    body=$(printf '{"apiVersion":"0.0.1","kind":"hashedrekord","spec":{"data":{"hash":{"algorithm":"sha256","value":"%s"}},"signature":{"content":"%s","publicKey":{"content":"%s"}}}}' "$hash" "$signature" "$pem" | b64)
    log_index=$((time % 100000))
    log_hex=$(sha256sum <"$dir/rekor.der" | cut -d' ' -f1)
    log_id=$(openssl dgst -sha256 -binary "$dir/rekor.der" | b64)
    printf '{"body":"%s","integratedTime":%s,"logID":"%s","logIndex":%s}' "$body" "$time" "$log_hex" "$log_index" >"$work/set"
    set_signature=$(openssl dgst -sha256 -sign "$dir/rekor.key" "$work/set" | b64)
    printf '{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json","verificationMaterial":{"certificate":{"rawBytes":"%s"},"tlogEntries":[{"logIndex":"%s","logId":{"keyId":"%s"},"kindVersion":{"kind":"hashedrekord","version":"0.0.1"},"integratedTime":"%s","inclusionPromise":{"signedEntryTimestamp":"%s"},"canonicalizedBody":"%s"}]},"messageSignature":{"messageDigest":{"algorithm":"SHA2_256","digest":"%s"},"signature":"%s"}}\n' \
        "$certificate" "$log_index" "$log_id" "$time" "$set_signature" "$body" "$digest" "$signature"
    ;;
*)
    echo "usage: tests/fake-sigstore.sh <dir> init | sign <file> <identity> [<issuer>] [<time>]" >&2
    exit 2
    ;;
esac
