# Iteration 83: Rekor v2

Started 2026-11-10 on 43d2538. Iteration 82's push run reproduced and signed all 38 images,
red only in `tests/signing.sh`. That turned out to be a flake in the test's fake Sigstore,
fixed first. The rest of the iteration teaches zigsaw **Rekor v2**, Sigstore's new
transparency log. Until now zigsaw refused every entry in it. Should Sigstore move cosign's
default to v2, CI's `push-bundle` would refuse its own signatures, and every zigsaw would
refuse what was signed. zigsaw is **0.83.0**.

## Outcome

- **Keyless bundles logged in Rekor v2 verify.** An entry in a v2 log has no time of the
  log's. A timestamp authority's RFC 3161 timestamp of the signature, in the bundle beside it,
  gives the time instead. zigsaw checks:
  - that timestamp, against the authority in Sigstore's trusted root;
  - the entry's inclusion proof;
  - the log's signed checkpoint, by an Ed25519 key, the first log, `log2025-1`, being one.

  Nothing in the trusted root had to change: it already listed `log2025-1` and the timestamp
  authority.
- **Rekor v1 bundles get their inclusion proof checked too**, where zigsaw so far took the
  log's signed promise alone. Every bundle cosign 3 makes carries one, iteration 81's real
  ones included, and they pass.
- **`tests/signing.sh` no longer flakes.** Its fake Sigstore read the clock before it made
  the certificate, whose start is "now". In 22% of signs (9 of 40) the second ticked over in
  between, so the log's time fell before the certificate was good, and zigsaw rightly refused
  it. Read after instead: 0 of 40.
- **CI signs as it did** (your pick): with cosign's default, which is still Rekor v1. So
  nothing changes for v0.81.0 until Sigstore moves the default
  ([gaps](gaps.md)).

- **Real v2 bundles verify.** A probe on a runner (branch `probe/rekor-v2`, run 42752799354)
  signed two files in log2025-1. Stock cosign and zigsaw 0.83.0 both take them; they're
  now golden test data. On the same runner, cosign's default still logs in Rekor v1
  ([findings](findings.md#rekor-v2-iteration-83)).
- **v2 checkpoints carry witnesses' cosignatures**: four, after the log's own line. zigsaw
  reads only the log's.

## Decisions

Yours (2026-11-10):

- **Rekor v2**, over refusing unsigned images, a GTK advisories round, or BusyBox and
  Zig 0.17.1.
- **CI as it is**: no pinning cosign to Rekor v1, and no second, v2 bundle beside each
  image's. The consequence for v0.81.0, if Sigstore flips the default, is in gaps.md.

Mine, say if you disagree:

- **A v1 bundle's time stays its log's promise.** Its timestamps aren't read, so a timestamp
  authority's certificate that changes can't break v1 bundles that are otherwise good. Its
  proof, if there, has to hold.
- **A v2 bundle needs a proof, a checkpoint and a timestamp**; any one missing refuses it.
- **Which key signed a checkpoint is found by its 4-byte hint**, the start of the log's id
  in the trusted root. For v1 that's the SHA-256 of the key; for v2 it's a signed note's key
  id, SHA-256 of the log's name, a newline, 0x01 and the key, which already commits to the
  name. The checkpoint's origin line isn't compared with anything.
- **The timestamp's signer is the authority's certificate from the trusted root**, whatever
  the token names (Sigstore's has no certificates in it). It must be for time stamping and
  chain to the root at the timestamp's time.

## What changed

- `src/der.zig` (new): the bounded DER reader sigstore.zig had, shared, and GeneralizedTime.
- `src/merkle.zig` (new): RFC 9162 inclusion proofs, and signed-note checkpoints.
- `src/timestamp.zig` (new): RFC 3161 responses and tokens.
  - It checks the signed attributes against their TSTInfo, and the signature over the
    attributes retagged as a SET.
  - Algorithms: ECDSA on P-256 or P-384, with SHA-256 or SHA-384. Sigstore's authority signs
    with SHA-256 on a P-384 key, which std's ECDSA verifies.
- `src/sigstore.zig`:
  - the trusted root keeps Ed25519 logs and timestamp authorities;
  - `verify` takes hashedrekord 0.0.2 entries, and checks proofs for both versions;
  - certificates say whether they're for time stamping.
- `tests/fake-sigstore.sh`:
  - an Ed25519 log and a P-384 timestamp authority, as Sigstore's;
  - v1 bundles with a proof and checkpoint;
  - `FAKE_REKOR=2` for v2 bundles, and `FAKE_LEAF_DAYS=-1` for a certificate that was never
    good;
  - the flake fix.
- `src/testdata/sigstore/fake/`: regenerated, with `bundle-v2.json` and `late-v2.json`.
  How is in a comment above the tests.
- `src/testdata/sigstore/real/v2/`: the probe's two bundles, and the payload it signed.
- `tests/signing.sh`: 6 rows for v2: push-bundle, pull, `signature check`, a zigsaw without
  the test's root, a certificate that wasn't good when timestamped, a release.
- README's signatures section, docs/gaps.md, version 0.83.0.

## How it was checked

| What | Result |
|---|---|
| Unit tests | 203 pass, 11 of them new: DER, Merkle paths in trees of 1 to 20 leaves, checkpoints, the real timestamp, fake v2 good, its root and tampered (12 kinds), real v2 good and tampered; old ones got v1 proof cases |
| The probe's two real v2 bundles | good; tampered body, path, root, the log's checkpoint signature or the timestamp refused; a witness's cosignature changed, still good |
| Iteration 81's real bundles (Rekor v1, from a runner) | good, now with proof and checkpoint checked |
| Their real timestamp, from Sigstore's authority | parses, time 1794163745 (the log's own), of the bundle's signature, signed by the root's certificate; no byte flip inside what's signed passes |
| The flake's cause, 40 fake signs each | log time before the certificate: 9 with the old script, 0 with the new |
| `tests/signing.sh` under a local zot, with Git's openssl 3.2.4, as on CI | 58 ok, twice (71 s) |
| `tests/install.sh` | 0 failed |
| Defender, all six programs | clean (`zigsaw.exe` `dbf33914`) |
| `tests/self.sh` against the package | 19 ok, 0 failed: zigsaw builds itself to the package's bytes |

Iteration 82's owed checks:

| What | Result |
|---|---|
| `pull org.sqlite.sqlite3:3.54.1` from ghcr.io with v0.81.0 | "signed, by …/reproduce.yml@refs/heads/main" |
| The same with v0.80.0 | warns "isn't signed, though zigsaw knows a key for it", installs |
| llvm-mingw from ghcr.io with v0.81.0, full vs lazy, first `clang++` compile and link | see below |

| llvm-mingw | pull | first compile | in all | fetched on demand |
|---|---|---|---|---|
| 20261020, full | 17.4 s | 0.8 s | 18.3 s | |
| 20261020, lazy, no list | 5.0 s | 10.0 s | 15.0 s | 463 files, 145.4 MB |
| 20261104, full | 17.6 s | 0.8 s | 18.5 s | |
| 20261104, lazy, 464-file list | 5.5 s | 3.2 s | 8.8 s | 80 files (385 ahead) |

One run each. From ghcr.io the list shows what a local registry hid in 82: the first compile
goes from 10.0 s to 3.2 s. A lazy pull plus first compile now takes half as long as a full
pull.

## Not checked

- **v2 in production**: CI doesn't sign with it, by your pick. The probe's two bundles are
  the only real ones, and they're fixed test data.
- **Witnesses**: their cosignatures aren't verified, and nothing requires any.
- **A rotated v2 log** (log2026-…): the root built in knows only log2025-1. A bundle in a
  later log is refused as "a log zigsaw doesn't know" until `scripts/sigstore-root.sh`
  refreshes the copy ([gaps](gaps.md)).

## What's left for the user, in order

1. **Commit and push.** New files: `src/der.zig`, `src/merkle.zig`, `src/timestamp.zig`,
   `src/testdata/sigstore/fake/bundle-v2.json` and `late-v2.json`,
   `src/testdata/sigstore/real/v2/` (2 bundles and a payload), `docs/iteration-83.md`.
   Nothing to publish.
2. **I read Reproduce**: suites' `signing.sh` above all; nothing else should differ from 82's.
3. **Tag v0.83.0.** I read Release, whose sign job still uses cosign's default; then a real
   `zigsaw upgrade` from v0.81.0.
4. **Delete the probe branch**: `git push origin --delete probe/rekor-v2`, and
   `git worktree remove D:/zs/i83/probe` (I can do the worktree).
