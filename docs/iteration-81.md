# Iteration 81: Signing without hands

Started 2026-11-09. Since iteration 74, every image published and every release was signed by
hand with cosign: a key on the user's machine, named through Git Bash's quoting, a passphrase on
every run, the store's cosign with three flags so it stays off Sigstore, and "sign before you
push" as a step of its own. The user found it too bothersome, and picked **Sigstore keyless
signing in CI**, with the offline **backup key kept as a rescue** for releases. zigsaw is
**0.81.0**. No image changes, so nothing is to be published.

It started with what 80 left: Reproduce and Release v0.80.0 on dd7f48f were green.

A probe on a branch of its own (run 42511668073, after one that waited on a prompt for want of
`--yes`) signed a file and busybox's payload keyless on a runner: bundle v0.3, a hashedrekord
0.0.1 in rekor.sigstore.dev's log with its signed promise and an inclusion proof, and an RFC 3161
timestamp besides, which zigsaw doesn't need. Stock cosign verified both; so does zigsaw, against
the root built in, and those two bundles are now its golden tests. The job's own token got 403
from ghcr.io starting an upload to busybox's package, made with the user's token: hence
`GHCR_PUSH_TOKEN`.

## Outcome

- **CI signs what it has proven, keyless.** Nobody holds a key; GitHub gives the job an identity
  token, Sigstore's Fulcio a ten-minute certificate naming the workflow, and Rekor logs the
  signature publicly.
  - **Images**: each `published (group)` job of the Reproduce workflow, on `main` only, signs the
    images `tests/published.sh` has just shown to be what their recipes build (its new
    `compared.txt`), with `scripts/sign-images.sh`, now CI's. What's signed already is left
    alone, so an outage of Sigstore's (rekor.sigstore.dev answered 500 on 2026-11-07) only
    leaves the rest to the next run. The signature names
    `.../reproduce.yml@refs/heads/main`.
  - **Releases**: the Release workflow's new `sign` job, on a runner of its own, runs
    `scripts/sign-release.sh --keyless`: Reproduce passed on the tag's commit, a clean build of
    the tag there gives the release's six programs byte for byte, VERSION and SHA256SUMS agree;
    then cosign signs SHA256SUMS and the job uploads `SHA256SUMS.sigstore.json`, naming
    `.../release.yml@refs/tags/v<version>`. If Reproduce hasn't passed yet, the job fails saying
    so, and re-running it later keeps the tag.
- **zigsaw checks them offline** (`src/sigstore.zig`), against Sigstore's trusted root built in
  (`src/sigstore-root.json`; `scripts/sigstore-root.sh` refreshes it through cosign's TUF
  client): the Rekor entry's signed promise and time, the certificate's chain to Fulcio at
  that time, its identity and issuer, and that it signed exactly this file. The Zig standard
  library's X.509 does the chain; Fulcio's extensions are walked by hand. Only Rekor v1
  entries are taken, which is what Sigstore's public instance still writes by default.
- **Whose signature counts** is a key or an identity (`trust.Signer`):
  - zigsaw-io's images: Reproduce on main, keyless, and both old keys, so what was signed
    before stays good;
  - releases: Release at the release's own tag, keyless, and the **backup key**, the way to
    reach a zigsaw should Sigstore's keys ever change past what it knows;
  - your own: `zigsaw trust add <prefix> --keyless <identity> [--issuer <url>]`, beside keys.
  The key that signed until now no longer counts for releases from 0.81.0.
- **Old zigsaws keep working.** A keyless signature goes beside the image under
  `sha256-<digest>.sigstore`, not cosign's `.sig` tag, where a zigsaw from 0.74 to 0.80 would
  refuse what it can't check; there they find nothing, and warn. A store's keyless entries are
  a list of their own in `trust.json`, which those zigsaws skip. **v0.81.0 itself is signed
  with the key once more**, as they read only `SHA256SUMS.sig`.
- **`zigsaw signature push-bundle`** puts a bundle beside an image after checking it as a pull
  would, since a bundle that isn't good there would have every pull refuse the image.
- **`scripts/publish.sh` needs no key** and signs nothing; `check-pins.sh` reports an image
  not signed yet without failing, as CI signs after it runs.

What it costs: a signature is now as good as GitHub's account security, the branch protection
of `main` and the workflows' pinned actions, and it says CI rebuilt the image to the same
digest, not that someone looked. Every signature is public in Rekor, so one that shouldn't be
there can at least be found. [Gaps](gaps.md) has the rest: no TUF, no Rekor v2, no inclusion
proof, and an MSVC-built image is never compared, so never signed by CI.

## How it was checked

| What | Result |
|---|---|
| `zig build test` | passes; sigstore.zig's tests: the probe's two real bundles are good against the built-in root, and not for another workflow, file, root or promise; a fake Sigstore's bundle is good, and not for another file, workflow, branch, tag or issuer, a root without its log or authority, a certificate expired at the log's time, a changed SET, body, signature or time, Rekor v2, or what isn't a bundle |
| `tests/signing.sh` | 52 ok; 18 new rows: keyless images pushed, pulled, refused (another workflow, another image, a zigsaw without the test's root, a store trusting only a key), alongside a key's, removed; releases told about only when signed by Release for their own tag |
| `tests/updates.sh`, `tests/registry.sh` | all ok |
| `tests/oci.sh` | 35 ok, 2 known gaps: the real cosign's key signatures as before, and the key-naming rows now on `sign-release.sh`, which keeps them for the rescue |
| `tests/install.sh` on the package | all ok (367 s) |
| `scripts/defender-scan.sh` on the final package | all six programs clean; zigsaw.exe c05165ee, zigsaw-notify.exe 831e3109 |

`tests/fake-sigstore.sh` is the tests' Sigstore: a P-384 authority and a P-256 log key made
with openssl, and bundles as `cosign sign-blob --bundle` writes them, signed by a certificate
naming whatever workflow a row wants. Only a zigsaw built with `-Dsigstore-test-root` takes
them; `tests/signing.sh` builds one in Debug (21 s, where a safe build takes 1 min 47 s).

## What's left for the user, in order

1. **Add the secret `GHCR_PUSH_TOKEN`**: a classic token with only `write:packages`, as a
   repository secret of zigsaw-io/zigsaw (the user's pick, over granting Actions access in each
   package's settings). The probe showed the job's own token can't push there. Without it, the
   signing steps fail, red. Then delete the branch `probe/sigstore` (`git push origin
   --delete probe/sigstore`, and `git worktree remove D:\zs\i81\probe`).
2. **Commit and push main.** The first Reproduce run on main signs every image whose group
   runs: GTK's and Qt's on the weekly run, or by hand (Run workflow). I'll read it, and pull
   from ghcr.io with this zigsaw and with v0.80.0's.
3. **Tag v0.81.0.** The Release workflow signs it keyless; I'll read the `sign` job. Then
   **`scripts/sign-release.sh v0.81.0` once more with the key**, for zigsaws 0.74 to 0.80.
   After that the key that signed may be destroyed; keep the backup.
