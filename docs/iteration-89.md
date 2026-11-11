# Iteration 89: Kept builds, round 2

Started 2026-11-12, from "plan iteration 89". Iteration 88 kept each recipe's build root so
that its next build goes on from it. Its Reproduce run was red in three jobs, and two of the
causes were 88's. Fixing those came first. Then came what 88 left unchecked: long chains
stopped and built again, a limit on the room kept builds take, and rows for the vendor step,
two builds at once and Ctrl+C. zigsaw is **0.89.0**. No image changes, so there's nothing to
publish. How it's used is in [recipes.md](recipes.md#going-on-from-the-last-build), what it
found in [findings.md](findings.md#kept-builds-round-2-iteration-89).

State at the start: 88 committed (`51664fd`), untagged; Reproduce 43056285992 red in
`pins`, `build (langs)` and `standard-user`.

## Outcome

- **88's red jobs are fixed, two of the three in zigsaw's tests, one in zigsaw.**
  - `pins`: the test of `scripts/rebuild.sh` stood in for zigsaw with a script that read the
    recipe as its second argument, which `--no-resume` now is.
  - `build (langs)`: **a build in 88's kept root made another image of a Rust program than a
    build in a new root.** The root's real path reaches GNU ld through rustc, and ld orders
    kernel32's imports by the names of the files they come from: `cache\…` sorts before the
    Rust image's `deploy\…`, `tmp\…` after it. The kept root is now `tmp\zigsaw-build-<key>`,
    where a new root is, under a name as long, and both give the published kind of image.
  - `standard-user`: `tests/shims.sh` builds BusyBox's recipe under another id, which can't
    fall back to the sources next to BusyBox's image when frippery.org refuses, as it seems
    to have started doing to GitHub's runners. It builds BusyBox's own recipe first now.
- **Long chains go on from where they stopped, to the published image, and none had to start
  over** (below). A file written into, which 88 feared would make GTK's and Qt's chains build
  every module again, never came up: so no copies of small files (your answer for that case).
- **Kept builds may take 10 GB together**, `ZIGSAW_KEPT_BUILDS_SIZE` to change it. A build
  records its own's size when it ends, and deletes the least recently used others past that,
  saying which: `deleted the kept build of <id> (<size>): kept builds may take <room> together
  (ZIGSAW_KEPT_BUILDS_SIZE)`.
- **What 88 left unchecked has rows now**: a vendor step's module in a build that goes on, two
  builds of one recipe at once, the cap, and a build stopped by Ctrl+C in a console.

### GTK's and Qt's chains, stopped and built again

On E: (a Dev Drive), in a store seeded from iteration 82's, with this iteration's zigsaw. Each
build stopped with `taskkill /F` in the middle of a module's compile.

| | GTK SDK base (22 modules) | Qt 6 SDK base (5 modules) |
|---|---|---|
| Stopped | in harfbuzz's compile, step 42 of 135, after 447 s | in qtbase's compile, step 960 of 1870, after 367 s |
| Built again | 15 modules skipped, going on at harfbuzz's command 2 of 2: 349 s | going on at qtbase's command 3 of 4, ninja with the 910 steps left, CMake not run again: 553 s |
| Its image | `68eb757e…`, the published one | `77492dcc…`, the published one |
| A late module changed (one more command) | gtk alone, 21 skipped: 207 s, the published image | qtshadertools and relocate, 3 skipped: 55 s, the published image |
| A file written into, so every module again | never | never |
| The kept build | 1.17 GB, 41,140 files; measuring it 2.2 s | 0.84 GB, 39,471 files; 2.6 s |

A full build of each wasn't timed here: stopped and built again, they took 796 s and 920 s
in all.

## Decisions

Yours (2026-11-12, by question):

- **Theme**: kept builds, round 2, over a BusyBox + Zig 0.17.1 round.
- **Disk**: a size cap in the store. Each build deletes the least recently used kept builds
  once all of them together take more, and says which.
- **If GTK or Qt show files written into often**: keep real copies of small prefix files.

Mine, say if you disagree:

- **The kept root moved to `tmp\zigsaw-build-<key>`**, where a new build's root is, under a
  name as long. 88 had it in `cache\work\<key>\zigsaw-build-root`, and a Rust program built
  there was another image (below). The record stays in `cache\work\<key>`.
- **A kept build of 0.88's is deleted**, as one this zigsaw can't read: its state's header
  went to 2.
- **The cap is `ZIGSAW_KEPT_BUILDS_SIZE`**, a variable as `ZIGSAW_UPLOAD_CHUNK_SIZE` is, not a
  setting in the store, which has none. 10 GB by default; `20GB`, `500MB`, bytes, `0`. A value
  that isn't a size warns, and 10 GB holds.
- **Only a build that keeps its own enforces it**, when it ends, failed or not, while it still
  holds its own: a `--no-resume` or MSVC build deletes nothing. "Least recently used" is the
  time of the state file, which every command's step writes.
- **Each kept build's size is written when its build ends** (`size`, beside `state`), and its
  app's id (`about`), for the message. The cap adds up those files; one without, of 0.88's, is
  measured once.
- **`prune` still measures**, rather than reading the `size` files: what it reports is what's
  there now. A kept build's root in `tmp\` is no leftover to `prune`: it's counted, and
  deleted with `--downloads`, as part of its kept build.
- **A record whose root is gone starts afresh, and a root without its record goes**, so that
  a `tmp\` cleared by hand, or a `cache\work` deleted, leaves nothing half kept.
- **No copies of small files**: the case they were for didn't come up (above).
- **shims.sh builds BusyBox's own recipe first**, and removes it, so that its copy under
  another id finds the download in the store.

## What changed

| File | What |
|---|---|
| `src/checkpoint.zig` | the root in `tmp\` (`rootFor`, `isKeptRoot`), a root without a record or a record without its root starts afresh, state 2; the cap (`parseSize`, `sizeOf`, `writeSize`, `enforceCap`), `about`; unit tests |
| `src/builder.zig` | the kept root's path; `keepWithinCap` when the build ends |
| `src/prune.zig` | kept roots in `tmp\` are kept builds, counted and deleted with them |
| `src/Store.zig` | `treeSize`, from prune |
| `src/main.zig` | usage: the cap |
| `tests/rebuild.sh` | the stand-in zigsaw takes the recipe last; a row for `--no-resume` |
| `tests/build.sh` | `same_rebuilt` says what it got; rows on the kept root's place, a vendor step, two builds at once, the cap; the kept root's new place; set-up builds say why they failed |
| `tests/shims.sh` | BusyBox's own recipe built first; set-up builds say why they failed; the taken-name row shows the build's error |
| `tests/ctrlc.sh`, `tests/ctrlc.zig` | a build stopped by Ctrl+C in a console, and built again |
| `README.md`, `docs/recipes.md`, `docs/how-it-works.md`, `docs/gaps.md`, `docs/findings.md` | the cap, the root's place, what was found |

## Tests

All with the kit's frozen 0.89.0, the build in the tree now, on this machine (Windows 11; E: a
Dev Drive).

| What | Result |
|---|---|
| Unit tests, 2 new (the cap, sizes) and 2 cases in the state's (a record without its root, a root without its record) | pass |
| `tests/rebuild.sh`, 1 new row | 0 failed (was 14 on CI) |
| `GROUP=base tests/build.sh`: 105 rows as before, 8 new | 113 ok, 68 s |
| `SECTIONS=rust GROUP=langs tests/build.sh` | 11 ok, 146 s (was 1 failed, here and on CI) |
| `tests/ctrlc.sh`, 2 new rows | 28 ok |
| `tests/shims.sh` with no downloads seeded, as CI's standard user has it | 0 failed |
| `tests/standard-user.sh` as zstest: shims, build-base, store | 55, 88, 17 ok |
| `tests/store.sh`, `tests/self.sh` | 0 failed; 20 ok |
| GTK's and Qt's SDK chains stopped and built again (above) | the published images |
| Microsoft Defender on the package's six programs | no threats |

The Rust program by hand: built in a kept root, `4d08264e…` before the fix, `9daf0dd3…` after;
`--rebuild` `9daf0dd3…` every time, ten builds in two stores of different path lengths.

## What I got wrong on the way

- **I took the langs failure for a vendor step's**, as 88's write-up had left that rule
  unchecked, and the row's name says "vendored". A first build with the vendor step's files
  already in the cache made the same other image: it was where the root was.
- **Then for zig's random object names**, the first difference in the build directories.
  They're in debug information that's stripped. The import table led to windows-sys's rlib,
  and the link commands to the path.
- **The first standard-user run here failed two suites at once**, each at its first build, in
  a second, with nothing said: the rows hid the build's output. They show it now. Run again,
  both passed, and I don't know what that first failure was.
- **I ran the tree's zigsaw with `--version` and no store set**, which my notes say never to
  do. Your real store wasn't touched (its newest change is from 2026-11-11).

## Not checked

- **CI**: the fixes on Windows Server 2025, and the new rows there. Whether frippery.org now
  refuses the runners is a guess from the shims rows: the CI logs keep only the rows' lines.
- **The matrix, `build.sh`'s zig and cmake-meson groups, and the other suites**: not run
  here; nothing they cover changed but where a kept root is. CI runs them.
- **A full build of GTK's and Qt's chains with this zigsaw**, for the time a build that goes
  on saves: they built in parts only.
- **A store on a volume where `tmp\` can't be hard-linked to `cache\work`**: they're always
  in the same store, so on the same volume.
- **The cap on a store with large kept builds of many recipes**: only the suite's tiny ones
  were deleted by it, and the unit test's.
- **An upgrade from 0.88 with a kept build**: it's deleted as unreadable (a unit test and a
  suite row have the old kind), but no real 0.88 store was upgraded.

## Yours to do

1. **Commit and push**: new `docs/iteration-89.md`. Nothing to publish. I'll read Reproduce:
   `pins`, `build (langs)` and `standard-user` first.
2. **Tag v0.89.0** when you want it released, rather than v0.88.0, whose tests were red. I'll
   read Release.
3. **Kits**: `E:\zs\i89` (the store `m` holds GTK's and Qt's kept builds, 2 GB, and `r`, `nb`,
   `r-a-longer-store-path`, test stores), `D:\zs\i88` and `E:\zs\i88` can go on your yes.

