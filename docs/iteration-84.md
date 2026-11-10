# Iteration 84: The fake Sigstore on a newer openssl

Started 2026-11-10 on 1f5787b. Iteration 83's push run reproduced and signed every image,
red only in `tests/signing.sh`, on one row: "one whose certificate wasn't good when it was
timestamped is refused", which printed nothing. v0.83.0 was tagged anyway; its Release run
published the release, and its sign job then refused to sign it, as it should, since
Reproduce on its commit had failed. So no zigsaw is told about 0.83.0 yet. This iteration
fixes the test (your pick: nothing else) and leaves the release's rescue to you, with the
backup key. zigsaw stays **0.83.0**: nothing under `src/` changed, nothing to publish, no
new tag.

## Outcome

- **The cause: OpenSSL 3.6 refuses a certificate that ends before it starts.** The row's
  fake certificate came from `openssl x509 -req -days -1`. Git's OpenSSL 3.2.4, which the
  kit ran, makes one good from now until a day ago. OpenSSL 3.6.3 stops with "Error: end
  date before start date". `tests/fake-sigstore.sh` sent openssl's errors to `/dev/null`
  and runs with `set -e`, so the signer died without a word, and the row failed with empty
  output. Which openssl the runner has is in the next run's log (see below); MSYS2's 3.6.3
  here reproduces the failure exactly.
- **The fix: an expired certificate, made with `openssl ca`.** `FAKE_LEAF_EXPIRED=1`
  (was `FAKE_LEAF_DAYS=-1`) makes a leaf good from two days ago to one day ago, with
  `openssl ca -startdate -enddate`, which every 3.x takes. (`x509 -not_before` would be
  shorter, but Git's 3.2.4 doesn't have it.) A certificate that expired before the
  signature still tests what the row is about: zigsaw refuses it, as "wasn't good when it
  was signed". Every other row's certificate is made as before.
- **openssl no longer fails quietly.** Every openssl command in the fake Sigstore that
  wrote its errors to `/dev/null` now goes through `quiet`, which prints the command and
  what openssl said, only when it fails.
- **`signing.sh` says which openssl it uses**, before it makes the fake Sigstore.

## Decisions

Yours (2026-11-10):

- **The CI fix only**, over a GTK advisories round, BusyBox and Zig 0.17.1, or refusing
  unsigned images.
- **v0.83.0 is rescued with the backup key**, the path iteration 81 kept for a release
  that can't be signed keyless (`src/trust.zig`, `src/upgrade.zig`: a zigsaw takes
  `SHA256SUMS.sig` by the backup when there's no keyless bundle).

Mine, say if you disagree:

- **Expired, not never-good.** A certificate whose end is before its start can't be made
  with OpenSSL 3.6 any more, and zigsaw's check (the time inside the validity) refuses
  both kinds alike.
- **No openssl pinned in the workflow.** The fake now works with 3.2 to 3.6, and the log
  says which one ran.

## What changed

- `tests/fake-sigstore.sh`: `quiet` helper; the expired leaf through `openssl ca`;
  `FAKE_LEAF_EXPIRED=1`; the header says both.
- `tests/signing.sh`: prints `openssl: <path>, <version>`; the row sets
  `FAKE_LEAF_EXPIRED=1`.

## How it was checked

Kit `D:\zs\i84` (`signing.sh <openssl dir>`, under tests/zot.sh, fake user folders).

| | openssl | 83's fake Sigstore | 84's |
|---|---|---|---|
| `x509 -days -1`, by hand | Git 3.2.4 | good now → a day ago | — |
| | MSYS2 3.6.3 | "end date before start date", exit 1 | — |
| expired row's signer alone | MSYS2 3.6.3 | exit 1, **no output** (CI's FAIL) | bundle; leaf good 2 days ago → 1 day ago |
| `tests/signing.sh`, whole | Git 3.2.4 first on PATH | 0 failed (83's kit) | **0 failed**, 84 s |
| | MSYS2 3.6.3 first on PATH | — | **0 failed**, 79 s |
| | this machine's plain PATH (3.6.3) | — | **0 failed**, 89 s |
| 83's flake: log time before notBefore | MSYS2 3.6.3 | 10 of 40 before 83's fix | **0 of 40** |

With the CA's key taken away, the signer now prints the `openssl ca` command and
"Could not open file or uri for loading CA private key", where it used to print nothing.

Not run: unit tests and the other suites (nothing under `src/` changed); Defender (nothing
built to ship).

**83's kit wasn't "as on CI".** It put Git's `usr\bin` first, OpenSSL 3.2.4. CI's Git Bash
has `/mingw64/bin` first, and what's there on a runner is the next run's `openssl:` line.

## What's left for the user, in order

1. **Commit and push.** Changed: `tests/fake-sigstore.sh`, `tests/signing.sh`; new:
   `docs/iteration-84.md`. Nothing to publish.
2. **I read Reproduce**: suites' `signing.sh`, and its `openssl:` line, recorded here.
3. **Sign v0.83.0 with the backup key**, once that run is green:

   ```sh
   COSIGN_KEY=<the backup cosign.key> scripts/sign-release.sh --anyway v0.83.0
   ```

   `--anyway` because Reproduce on v0.83.0's own commit stays red; the green run on this
   iteration's commit is what shows the red was the test's openssl, with the same `src/`.
   Everything else is still checked: the six programs must rebuild to the release's bytes
   from a clean worktree, or nothing is signed.
4. **I check the release**: `SHA256SUMS.sig` is there, `zigsaw updates check` on v0.81.0
   tells about 0.83.0, a real `zigsaw upgrade` from v0.81.0 to v0.83.0 (83's owed one).
5. **Delete the probe branch** from 83: `git push origin --delete probe/rekor-v2` (and
   `git branch -D probe/rekor-v2` here). Its worktree `D:/zs/i83/probe` is already removed.
