# Iteration 76: Going back

Started 2026-11-06. Iterations 69 to 75 made updates seen, signed, and frequent. The other half was
missing: an update that broke an app couldn't be undone, as installing a version deleted the one it
replaced and `prune` later deleted its blobs. The only way to keep `update` away from an app was
pulling it by digest. Now `zigsaw rollback` goes back, updates pass over the version it left, and
`zigsaw hold` keeps updates away. zigsaw is **0.76.0**. No image changes, so there's nothing to publish.
How it's used is in [the README](../README.md#going-back-and-holding), how it works in
[how-it-works.md](how-it-works.md#going-back), and what it doesn't do in [gaps.md](gaps.md).

It started with what 75 left: Reproduce and Release had gone green, `SHA256SUMS.sig` was there, and
v0.75.0's six programs were the bytes of 75's table.

## Outcome

- **The version an update replaces is kept**, as blobs: `update`, `pull` and `build` all record it,
  `prune` keeps its manifest, config and layers, and deletes its unpacked files as before.
  `prune --previous` deletes it too, and `prune` says what it costs.
- **`zigsaw rollback <app-id>` goes back to it**, with no network, unpacking it again. If the earlier
  version may reach more than the installed one, it asks first, as `update` does, unless given `--yes`.
  Running it again returns to the version left.
- **Updates pass over the version a rollback left**, and only that one: `update`, `update --check` and
  the daily check say "skipping" and install nothing, and the next new version gets through, as any
  update. With a skip, `update` asks the registry for the tag's digest first, so nothing of the
  version passed over is downloaded or asked about.
- **`zigsaw hold` and `unhold`**: a held app is treated as one pinned by digest. `update` leaves it,
  named or not, and nothing contacts its registry, so the daily check never lists it. `pull`, `build`
  and `rollback` still install what they're asked to.
- **`zigsaw list`** shows `(previous <v>)`, `(skips <v>)` and `(held)`. `rm` forgets all of it, and
  `prune` removes what's left of apps that aren't installed.

## Decisions

Yours:

- **Going back** as the theme, over a round of toolchain updates, the report's blind spots, or
  refusing missing signatures.
- **Separate commands**: `rollback`, `hold`, `unhold`, rather than flags on `update`.
- **A rollback skips the version it left**, rather than holding the app, or doing nothing.
- **Blobs only** are kept, not the unpacked files: going back unpacks again.
- **Apps only**: going back from `zigsaw upgrade` stays `install.ps1 -Version`.

Mine, say if you disagree:

- **One version kept**, the one the installed version replaced. Two updates in a row, and the first is
  gone.
- **Files of their own** under `versions\` rather than fields of the ref. Refs and overrides are parsed
  strictly, so a zigsaw before 0.76 would refuse every ref on a store with a field it doesn't know. One
  file per concern, so that `hold` and an update never rewrite the same one.
- **Any install of another version clears the skip**: installing is asking for that version. An
  install of the same version leaves it.
- **A held app named on `update`'s command line is still left**, with a note and exit 0, as a pinned
  one is. `unhold` is the way on.
- **No signature check on going back**: the image was checked when it came in.
- **`prune --previous`**, which the plan only mentioned, so that the space can be had back without `rm`.

## Results

| What | Result |
|---|---|
| `tests/rollback.sh`, new, under `tests/zot.sh` | 32 ok, 10 s |
| `tests/store.sh`, two blob counts now 6 (the version replaced is kept), and a `prune --previous` row | 17 ok |
| `tests/updates.sh`, `registry.sh`, `signing.sh` | 42, 113, 34 ok |
| `tests/shims.sh`, `install.sh` | 55, 45 ok |
| `tests/build.sh`, base group, which has `prune`'s rows | 92 ok |
| Unit tests, with new ones for `versions\` and the skip | pass |
| Real images from ghcr.io, in a scratch store: fzf 0.74.4, then 0.74.5, `rollback` | back in 149 ms, `fzf --version` says 0.74.4 |
| The same, with the ref following `latest`: `update --check`, `update`, the daily check | "skipping 0.74.5", stays, tells nothing |
| `hold`, then `-v update --check` | "held", and no request |
| `rollback` again, then `update` | 0.74.5, up to date; `rm` leaves nothing in `versions\` |
| Real upgrades to v0.75.0, from the real v0.74.0 and v0.73.0 | both, to the release's own bytes |
| v0.74.0 against v0.75.0's files with a changed `SHA256SUMS` | refused, over its signature |
| `published (gtk)` of 42115229955, rerun twice | both green: three in a row for 75's `make` fix |
| `scripts/package.sh`, then `defender-scan.sh` | 0.76.0's six programs clean |
| `tests/self.sh` against that package | 19 ok: zigsaw builds itself to the same bytes |

Your six folders and the repository have no low labels or capability ACEs afterwards. `zigsaw grants`
lists only scratch folders under `D:\zs` and `E:\zs`, from suites' and earlier iterations' stores.

0.76.0's programs here, to compare with the release's. Only `zigsaw.exe` has new code; the others
differ from 0.75.0's by the version they carry.

| Program | SHA-256 |
|---|---|
| `zigsaw.exe` | `02f7dcf38c5f0ac79211d498aed720d11379a1cf7af8c26c50be2970e8822649` |
| `zigsaw-shim.exe` | `b73feb069b7727ce73a38435a41b34fc5a513637bc467b8d7c8642a59d415e6f` |
| `zigsaw-shimw.exe` | `28551c6051f3941833735def1914dfaf510bcadf3e4df4c0c220c2b95e75d08a` |
| `zigsaw-relay.exe` | `e3ff6130db08c3e8569885bc30206f00dca462376149ee3a0cd78865e87cbe51` |
| `zigsaw-host.exe` | `ba0350a1b02f579f07be89593cf17ad32ada08ec41175087c1db1ca602004d6a` |
| `zigsaw-notify.exe` | `da820f606cd639ef40be225d6ac18b3380a3b93e082cd018d745c33d46add5bd` |

## What went wrong

- **The real-upgrade kit's first run failed every row**: in my heredoc, a double backslash became one,
  so `"$base\$d"` kept `$d` as it was, and named a folder `upg$d`. Rewritten with `cygpath -w`, from the
  Write tool. That's a trap my notes already had.
- **One row of the new suite failed on its first run**, on my grep: the permission reads "the network".
- **A count in `prune`'s note** would have included a previous version that is the installed one, as
  an install that stops between its two writes leaves. Fixed before packaging; `rollback` already
  refused it.

## Not checked

- **CI**, the new step on Server 2025. Changing `reproduce.yml` re-checks GTK's and Qt's families, so
  the push gets a long run.
- **A rollback of a large image**, such as an SDK, for how long unpacking takes: fzf is small. It's an
  install from blobs already here, which every warm `pull` is, so nothing new.
- **A rollback while the app runs.** It goes through the same install as an update, whose rows in
  `store.sh` cover that.
- **A rollback across a real change of data format.** Nothing published has one between two kept
  versions; gaps.md says what happens.
- **A zigsaw before 0.76 on a store 0.76 used**: by reading, it ignores `versions\`, which the rows
  that delete a previous version's blobs by hand stand in for.

## On this machine

Scratch is in `E:\zs\i76`. `E:\zs\i76\real` and `upg` hold scratch stores, and their apps were removed
by the kits; `HKCU\Software\ZigsawTest\i76-*` is gone. No scheduled task was made.

## Next

Each after the one before; yours unless it says otherwise.

1. **Commit and push**, with `git add --chmod=+x tests/rollback.sh`, and the new `src/rollback.zig`,
   `tests/rollback.sh` and this file. Nothing to publish. It's a long run, as the workflow changed;
   I'll read Reproduce, the `rollback.sh` step first.
2. **Tag v0.76.0.** I'll read Release and its scan, and compare its programs with the table above.
3. **`COSIGN_KEY=... bash scripts/sign-release.sh v0.76.0`.** I then try a real upgrade from v0.75.0.
4. **Run Upstream once**, if you'd like the issue current: it's from 2026-11-04, before iterations 72
   to 75. I read it, and Monday's weekly run.
5. **File `draft/i75/pdpmake-empty-macro.md`** upstream, if you agree with it.

Later, from the report: a toolchain round (BusyBox FRP-6354 from source, as frippery.org still answers
403, zig 0.17.1, llvm-mingw 20261104, CMake 4.4.5, Rust 1.99.1, and Python 3.14.10 for Meson and Qt's
SDK, the last row with a network-reachable advisory). One round, as each moves 18 to 67 images.
