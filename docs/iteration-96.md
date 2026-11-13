# Iteration 96: Lists that write themselves

Started 2026-11-13, from "plan to implement automatic prefetch recording". A lazy pull is fast
for what a recipe's `prefetch` list names: seven recipes have one, each recorded by hand from one
run of one command, and each needs its image published again. Everything else a run reads comes
as it asks. The helper behind a lazy layer already sees every such read, and threw that away at
the swap. Now it keeps it: **what runs read of an image while its layer was lazy is written down
in the store, and the next lazy pull of that image asks for those files before any run does.**
zigsaw is **0.96.0**. No recipe or image changes, so there's nothing to publish. How it's used is
in [the README](../README.md#pulling-lazily), how it works in
[how-it-works.md](how-it-works.md#lazy-pulls), what it gains in
[findings.md](findings.md#lists-that-write-themselves-iteration-96).

State at the start: 95 had landed (`e827433`, Reproduce 43276261112 and Release 43286620224
green).

## Outcome

- **`learned\<id>.txt`** in the store, one for each image, an app's or a runtime's: a line
  `<layer> <path>` for each file that anything but the helper read of that layer while it was
  lazy. The list is the paths of the last three layers the file has lines of.
- **`pull --lazy` and `update --lazy` say `N files that runs read before come first`**, and the
  layer's helper asks for those files' bytes as it starts: behind what a run waits for, before
  the download, joined into a few requests.
- **The files stay placeholders.** A run's read of one is served from the blob without a
  request, and is how the helper sees the file is still read. One nothing reads any more is off
  the list three lazy layers later.
- **On an update, what the version before has is still copied**, not fetched: the list costs
  requests only for what changed.
- **`rm` leaves a list; `prune` deletes those of images nothing installed is or uses.**
- **From ghcr.io**, TeX Live updated lazily, then `lualatex` (its recipe's list is
  `pdflatex`'s): 6 s with the list against 18 to 20 s without, where the store had nothing to
  copy from, and the update itself no slower in one pair of two. Where 97% was copied, 6 s
  against 11, in one pair.

## Decisions

Yours, by the question dialogs, all the ones I recommended:

- **Learned on the user's machine**, over a recipe naming its run, `zigsaw build` recording, or a
  CI job.
- **Fetch only**: learned files come ahead into the blob and aren't hydrated, so that their reads
  are still seen.
- **A list lives until `prune`.**
- **A line on pull, a plain file, no command or switch.**

Mine:

- **A layer counts by when it last got a line, not when it first did.** A version pulled lazily
  again (after a rollback) is then the latest, and the helper needs no memory of what earlier
  helpers of its layer wrote: the same line twice counts once.
- **Every reader counts, not only runs**, as the plan had it: Defender, Explorer, the pull's own
  `zigsaw`. It's the rule `scripts/record-prefetch.sh` has, and what those read on one version
  they read on the next. A one-off walk of the store is off the list three layers later, with
  no check in the callback of whether a run is going.
- **Neighbours within a MiB go out as one request**, in the order runs first read a file of each.
  The download wants the bytes between them anyway; TeX Live's 249 files became 10 spans.
- **Asked for while the pull still runs**, as the prioritized files are, not held back with the
  download. Overlapping the pull's own work can't make the first use later, and the second pair
  of runs shows the update no slower.
- **A priority of its own in `BlobReader`** (`ahead`), not a run's: a read never queues behind the
  list, a read of a queued piece moves it up, and one thread of the four is always left free.
  The bytes are counted apart (`ahead` in `state.json`).
- **The pull's line says "come first"**, not the plan's "are fetched first": on an update most of
  them are copied.
- **`learned\` is a folder of the store's own**, not under `lazy\`, which is what a layer has
  while it's lazy.
- **llvm-mingw's test compile is for x86_64**, not the plan's `i686`: the image has no i686
  libraries. So that row shows a recipe's list already covering the run, not the list's gain.

## Files

- `src/learned.zig` (new): the file, `select`, `read` (which rewrites it), `record`,
  `pruneUnused`.
- `src/BlobReader.zig`: `Priority.ahead`, `prefetchAhead`, `ahead_bytes`; `promote` moves a
  piece from either lower queue.
- `src/lazy.zig`: `Meta.image`, `State.ahead`, `learnedAhead`, the pull's line.
- `src/remote.zig`: which image each layer is the own one of.
- `src/LazyHelper.zig`: `learn` in the fetch callback, `fetchAhead` at the start.
- `src/prune.zig`, `src/Store.zig`: the lists of images in use are kept; `learned` in the layout.
- `tests/lazy.sh`: four rows, a store `j`.

## Results

| what | result |
|---|---|
| unit tests | 238 pass, three times over; 4 new (`learned.select`, a list in a store, the `ahead` priority's order) |
| `tests/lazy.sh` | 37 ok (4 new), 54 s; the same inside `jobprobe injob`, as CI's job is |
| `tests/store.sh`, `oci.sh`, `registry.sh`, `rollback.sh`, `updates.sh`, `volumes.sh`, `sandbox.sh`, `upgrade.sh`, `build.sh` (base) | 17, 35, 113, 55, 42, 135, 142, 32 and 113 ok; 0 failed |
| TeX Live `99b0c1d4` to `7d55caed` from ghcr.io, then `lualatex`, nothing to copy | with the list 60.4 + 5.8 s and 55.2 + 6.1 s; without 52.6 + 17.5 s and 55.1 + 19.9 s |
| the same, 97% copied from the version before | with 42.0 + 6.4 s; without 42.6 + 10.6 s |
| llvm-mingw 20261020 to 20261104 from ghcr.io, then `clang hello.c` | 8.2 + 2.1 s; 1 of the 32 learned files isn't in the recipe's list |
| the package | `zigsaw.exe` `fbaa45b4`, `zigsaw-relay.exe` `03f45666`, 0.96.0; Defender finds nothing in its six programs; `tests/self.sh` with it, 19 ok |

## Not checked

- **More than a pair or two of runs.** Pulls of TeX Live took 38 to 51 s on the day. The 12 to
  14 s the list saves `lualatex` with nothing to copy is well outside that; the 4 s with 97%
  copied isn't.
- **A GUI app, and a runtime's list shared by two apps.** The code path is the same (a layer's
  image id); only an app's own layer was measured, and `lazy.sh`'s fixture has no runtime.
- **A list that's gone stale.** That a file drops off after three layers is a unit test
  (`learned.select`), not something watched over three real updates.
- **Two helpers writing one list at once** (two versions of a runtime lazy together): the lock
  is there, and nothing ran it.
- **A slow link, or a fast one.** On a link faster than the disk, asking ahead may gain
  nothing.
- **A standard user**, `tests/matrix.sh`, the GUI suites and the other `build.sh` groups weren't
  run: nothing they cover changed but the store gaining a folder.

## Yours to do

- Commit and push (`src/learned.zig` and this file are new). I read the Reproduce run,
  `tests/lazy.sh` first.
- The tag `v0.96.0` is yours; I read the Release run after it.
