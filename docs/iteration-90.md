# Iteration 90: Iteration 89's red run

Started 2026-11-12, from "plan iteration 90". Iteration 89's Reproduce run was red, and this
iteration only fixes that, by your pick, so that v0.89.0 can be tagged. zigsaw stays
**0.89.0**, which was never released: the fix goes into it. No image changes, so there's
nothing to publish. What it found is in
[findings.md](findings.md#a-kept-root-with-no-record-iteration-90).

State at the start: 89 committed (`29985aa`), untagged; Reproduce 43092858003 red in
`build (zig)` and 15 `published (…)` jobs.

## Outcome

- **`build (zig)`: a failed build left its kept root behind, with no record.** A kept build's
  root, `tmp\zigsaw-build-<key>`, is made with the build root, and its record,
  `cache\work\<key>`, only once the first module has its sources. Two of `tests/build.sh`'s
  rows fail a vendor step on purpose, before that, and their roots stayed. Two later rows
  found them, as they check that nothing but kept builds is left in `tmp\`. In 88 the root was
  inside the record, so nothing was left; 89 moved it to `tmp\` and didn't run this group.
  Now a build that lets go of its kept build deletes the root if there's no record beside it,
  however the build ended: at a vendor step, with `B:` taken, or writing a module's sources.
- **15 published jobs failed only uploading their logs.** Every image reproduced and was
  signed; GitHub's artifact service answered with a web page for ten minutes. Those jobs
  upload on every run. An upload that fails no longer fails a job (`continue-on-error` on
  every job's upload step).

## Decisions

- **The fix is in zigsaw, not the test.** The rows were right: a build that failed is meant to
  leave nothing behind, and a root with no record is one nothing goes on from. `prune` and the
  recipe's next build did delete it, so it was no leak for good.
- **In `Kept.release`**, which every way out of a build goes through: the end of a build, a
  build root that couldn't be set up (`B:` taken), and a kept build that couldn't be brought
  back. Deleting it can fail without failing the build: zigsaw says so, and `prune` retries.
- **0.89.0 stays.** Nothing was released as 0.89.0, so the tag goes on this iteration's
  commit.

## What changed

| File | What |
|---|---|
| `src/checkpoint.zig` | `Kept.release` deletes a root with no record before letting go; unit test cases |
| `src/builder.zig` | `releaseKept`, at the three places a build lets go of its kept build |
| `tests/build.sh` | `no_build_root` names what it finds; a row after the two failed vendor steps; the `B:` row builds a recipe never built |
| `.github/workflows/reproduce.yml` | `continue-on-error` on the log uploads |
| `docs/findings.md` | the two causes |

## Tests

All on this machine (Windows 11; E: a Dev Drive), stores in `E:\zs\i90`.

| What | Result |
|---|---|
| Unit tests, 2 new cases in the kept build's state test | pass |
| `SECTIONS=commands tests/build.sh` with 89's zigsaw (HEAD's bytes) | 4 failed: CI's 2, and the 2 new rows, naming 3 roots |
| The same with this zigsaw | 35 ok |
| `GROUP=zig tests/build.sh`, the job that was red | 37 ok, 297 s |
| `GROUP=base tests/build.sh` (the kept builds' own rows) | 113 ok, 70 s |
| `tests/ctrlc.sh` (a build stopped by Ctrl+C keeps its root and record) | 28 ok, 34 s |
| Microsoft Defender on the package's six programs | no threats |

## Not checked

- **CI**, until you push.
- **A build killed before its first module**: its root stays until the recipe's next build or
  `prune`, as before; nothing runs when zigsaw is killed.

## Yours to do

1. **Commit and push**: new `docs/iteration-90.md`. Nothing to publish. I'll read Reproduce,
   `build (zig)` first.
2. **Tag v0.89.0** on that commit, when it's green. I'll read Release.
