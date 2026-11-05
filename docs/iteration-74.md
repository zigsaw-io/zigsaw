# Iteration 74: Signed images and releases

Started 2026-11-05. Iteration 73 made a daily check tell everyone what to install, and gave
zigsaw `upgrade`, and both trusted whatever the registry's tags and the release's files said. Now
images and releases are signed with a key that's on neither, and zigsaw checks. zigsaw is
**0.74.0**. No recipe changed and no digest moves: signatures go beside images. How it's used is in
[the README](../README.md#signatures), how it works in [how-it-works.md](how-it-works.md#signatures),
what it doesn't do in [gaps.md](gaps.md), and findings in
[findings.md](findings.md#signing-with-cosign).

It started by fixing what 73 left red: Reproduce on 83bc6ab failed in `standard-user`, and v0.73.0
went out on that run.

## Outcome

- **`pull` and `update` check an image's signature** before downloading anything of it. A wrong one
  is refused, and what's installed keeps running. A missing one warns.
- **`zigsaw upgrade` requires a signature**, of `SHA256SUMS`, which now lists `VERSION` too, and
  nobody is told about a release until it has one.
- **`scripts/sign-release.sh`** signs by hand, only once a build of the tag here gives the same six
  programs and Reproduce has passed on it.
- **`scripts/sign-images.sh`** signs what's published, without rebuilding anything.
- **`zigsaw trust`** gives anyone's registry the same check, with a key of theirs. Signatures are
  cosign's, in its classic layout: stock `cosign verify` reads them.
- **`standard-user`** can now run `install.sh`'s upgrade and daily-check rows, and has a row saying a
  standard user's account really got its task.

## Starting decisions

Yours: signing, with zlib 1.4 next; the release key on your machine, signed by hand; cosign signs and
zigsaw only verifies; a missing image signature warns for now.

Mine, in the plan: one day-to-day key and one offline backup, both good for both; keys for
`ghcr.io/zigsaw-io` only, plus `zigsaw trust`; only current versions signed; `sign-release.sh` wants
Reproduce green, or `--anyway`; a registry's 5xx is an error, not "unsigned".

**What the warning means:** until the refusal ships, someone who can change what ghcr.io serves can
leave the signature off, and only a warning stands in the way, which `--yes` doesn't stop for. I
propose refusing in v0.75.0, once a weekly `check-pins` has seen every image signed.

Changed during (mine, say if you disagree):

- **cosign only does the arithmetic**: the plan had that, and it's what the first probe confirmed.
  `cosign sign` could push too, but would need the registry login, and flags it deprecates.
- **`signature check` as a third `zigsaw signature` command**, which the plan didn't list, so that
  `sign-images.sh` can be run again after it stops.
- **`release.yml` is unchanged**, though the plan listed it: `install.sh` builds its helper itself.

## What was built

- `src/signature.zig`: keys, signatures and payloads, with no I/O. Unit tests use a real cosign key,
  payload and signature, in `src/testdata/cosign/` (its private key is gone).
- `src/trust.zig`: which keys count; `zigsaw trust add|rm`; `trust.json` in the store.
- `remote.checkSignature` and `pushSignature`; `Registry.fetchManifestIfThere`, where a 404 is
  "not there" and anything else is an error; `info`'s signature line.
- `upgrade.readSums`; `newer` says nothing about a release until it's signed.
- `scripts/signing-key.sh`, `sign-images.sh`, `sign-release.sh`, `sign-lib.sh`; `publish.sh` signs what it
  publishes, and stops before building without a key; `check-pins.sh` fails on an unsigned current image.
- `tests/signing.sh`, `tests/p256sign.zig` (signs as cosign does, from a word, so that `install.sh` and
  `updates.sh` don't need cosign), `tests/next-release.sh`, and a `--answer-500` for `tests/resetproxy.zig`.

## Found

- **Stock `cosign verify` doesn't compare the image's name with what's signed.** An image and its
  signature copied to another repository passed it. zigsaw refuses that, which a row checks.
- **`sign-blob` writes only a bundle unless told otherwise**, and `--output-signature` needs
  `--new-bundle-format=false --use-signing-config=false --tlog-upload=false`.
- **The reason a refusal gave was wrong for an image with two signatures**: "not by any key" overwrote
  "of another image". Refused either way; a test caught the message.
- **Why 73's `standard-user` was red**: `install.sh` needs git and a real Zig to package a later release,
  which that account hasn't, and `real_clean` didn't know `grants` now lists the daily task. Its rows and
  the reason it stopped weren't in the log, which they are now.

## Results

With the real keys built in, key `d58861ca1b29cc78` to sign and `5b6599a6da9c0ed0` as the backup.

| What | Result |
|---|---|
| `zig build test` | passed, 8 of them new |
| `tests/signing.sh` | 34 ok (new), about 25 s |
| `tests/install.sh` | 45 ok (5 new rows), also from a copy with no git and a stand-in Zig |
| `tests/updates.sh` | 42 ok (2 new rows) |
| `tests/oci.sh` | 35 ok, 2 known gaps, real cosign in 8 of 11 new rows |
| `tests/registry.sh` | 111 ok |
| `tests/store.sh`, `tests/shims.sh`, `tests/self.sh` | 16, 55 and 20 ok |
| `standard-user`, on CI at faf49a8 | every row, on a real standard account, with the daily task and all 40 of `install.sh`'s rows there were then |
| Defender on the package | all six clean |

An earlier run of `registry.sh` had 1 failure: a ghcr.io download broke off in a row this doesn't touch.
`published (gtk)` on faf49a8 failed once, on a garbled target name from BusyBox's `make`
([gaps](gaps.md)); that commit changed only tests.

The reason for a separate backup key is in [gaps.md](gaps.md): the first pair handed over were one key
twice, which protects against losing it, and not against it leaking.

## Not checked

- **The new `standard-user.sh` rows**: only CI has a standard account.
- **`sign-release.sh`'s GitHub half** (Reproduce's result, `gh release download` and `upload`, the
  worktree build): its checks and signing were tested from folders.
- **ghcr.io taking a signature**, which waits for you. It does answer a missing one with a 404,
  seen for real, which is what "not signed" rests on.
- **The passphrase prompts in `signing-key.sh` and `sign-images.sh`**: tests set `COSIGN_PASSWORD`.

## Next

Each after the one before:

- **Sign every current image, before pushing**, about 79, with no rebuilds, from Git Bash at the
  repository's root, with the zigsaw just built, and a login that may push (`zigsaw login ghcr.io`):
  `COSIGN="$(find /e/zs/i74/oci/deploy -maxdepth 2 -iname cosign.exe | head -1)" COSIGN_KEY='<the signing key>\cosign.key' bash scripts/sign-images.sh`
  It asks for the passphrase once, and can be run again if it stops.
- **Commit and push**: `git add --chmod=+x scripts/sign-images.sh scripts/sign-release.sh scripts/signing-key.sh tests/signing.sh`,
  and the new `src/signature.zig`, `src/trust.zig`, `src/testdata/cosign/`, `scripts/sign-lib.sh` and
  `tests/p256sign.zig`. It's a long run, and `check-pins` fails on anything unsigned. I'll read it.
- **Tag v0.74.0**, your call. I'll read Release and its scan.
- **`COSIGN_KEY=... bash scripts/sign-release.sh v0.74.0`**. Nobody on 0.74 or later is told about a
  release until this has run. I'll then try real upgrades in a scratch store: from v0.73.0, which is
  its first real one and unchecked, and from a build labelled 0.73.99, which checks the real signature.
- **Next iteration**: zlib 1.4, with Monday's report and any 1.4.1 in hand; refusing missing signatures
  in v0.75.0; Notes on the newer runner image, read from the 2026-11-09 weekly run.
