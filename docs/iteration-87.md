# Iteration 87: Going back with data

Started 2026-11-11, from "plan to support rollback with data". Until now `zigsaw rollback` brought
back an app's files and left its data as the newer version wrote it, which an older version may not
read: the first of the rollback gaps in [gaps.md](gaps.md). Now an install over a version keeps a
copy of the app's data as that version left it, and `rollback` takes it back if you say so. zigsaw
is **0.87.0**. No image changes, so there's nothing to publish. How it's used is in
[the README](../README.md#going-back-and-holding), how it works in
[how-it-works.md](how-it-works.md#going-back).

State at the start: 86 had landed (`dd7ac44`, Reproduce 42892228321 and the v0.86.0 Release green).

## Outcome

- **An install that replaces a version copies the app's data first**, its own volume
  `volumes\<id>`, to `snapshots\<id>`, and says how much it was and how long it took. `update`,
  `pull` and `build` all do. One copy for each app, as one previous version is kept; the record
  beside it names the version that left the data so. Its temporary files and cache are left out.
- **`zigsaw rollback` asks whether the data goes back too**, saying what is kept, from when, and
  how large. `[y/N]`: Enter alone, a "no", or nothing to answer all leave the data. `--data`
  answers yes, `--keep-data` no.
- **Taking the data back is a swap, not a copy**: three renames in the store, 0.1 s whatever the
  size. What the version left wrote since is set aside in the copy's place, so `rollback --data`
  again returns to it, with the version.
- **`zigsaw rollback --data-only <app>`** takes the data back and leaves the version: for after
  a rollback that left the data, when the older version turns out not to read it.
- **Only the app's own volume.** A volume it mounts, and a folder of yours it may use, are
  junctions in its data: the copy passes over them, and the app's next run makes them again in
  data taken back. Data mounted at `.` gets no copy, and the install says so.
- **An app that runs while its version is replaced** has the copy owed: its next run takes it
  before it starts, if no other run of it goes on. `rollback --data` refuses while the app runs.
- **`zigsaw override --nosnapshot <app>`** turns the copy off for an app (`--global` for all),
  `--snapshot` on again. `zigsaw list` says `(previous 1.2, with data)`. `prune` keeps the copies
  and says what they take, `prune --previous` deletes them, `rm` deletes an app's and says so.
- **With real PostgreSQL**, two published images of 18.6 from ghcr.io and a new cluster: the copy
  was 39.9 MiB in 978 files, taken in 280 ms; a table's rows followed the data each way through
  four rollbacks, and each side kept what it wrote after the swap.
- **The copy uses up to eight threads.** My first version copied one file after another, and
  20,000 small files took 15 s; robocopy on the same files took 13.2 s with one thread and 4.7 s
  with eight. Now it's 6.0 s, and PostgreSQL's cluster went from 715 ms to 280 ms.

## Decisions

Yours (2026-11-11, by question):

- **Rollback asks each time**, over data that always follows the version (snap's way) and over
  an opt-in `--data` alone.
- **Every app gets a copy, with an opt-out**, over a size limit, opt-in only, or a recipe field.
- **Own volume only**, over also copying named volumes that only the app mounts.

Mine, say if you disagree:

- **`rollback --data-only`.** It wasn't among your picks. Without it, answering no and then
  finding the older version can't read the data leaves no way to the copy but going forward and
  back again.
- **Data a rollback set aside goes at the app's next install**, as any copy does: one is kept.
  The install says "dropped". Keeping it longer would need a second place and a rule for when
  that goes.
- **The question's default is no.** Rollback's other question, "Go back to it?", defaults to yes;
  this one moves a week of work out of sight, so only a yes does it.
- **The copy is taken at the install, not at the new version's first run**, where a console is
  there to say what it costs. Only when the app runs meanwhile is it left to the next run.
- **A copy that fails doesn't fail the install.** A file something holds open, or a full disk,
  makes a warning, and the update goes on without a copy.
- **`rm` deletes the copy**, with the previous version: nothing could take it back any more. The
  app's data itself stays unless `--delete-data`, as before.
- **The swap leaves links where they are**, where the plan had it remove the ones zigsaw made.
  Nothing follows a link in data set aside (deleting and measuring stop at them, as for any data
  directory), and the app's next run puts right what the data taken back lacks. Fewer steps that
  can stop halfway.
- **`CopyFileW`, with `\\?\` paths**, rather than std's copy: it keeps times, attributes and
  streams, and clones on a Dev Drive. zigsaw's manifest doesn't ask for long paths, and a profile
  may hold some.
- **Threads for the files only**, at most eight, a batch of 2048 files at a time: the walk stays
  one thread, which makes every folder before a file goes into it, and the paths of a large
  tree are never all in memory at once.
- **The folder a swap uses is `snapshots\.swap-<id>`**: no app's id starts with a dot, so `prune`
  can't take it for a copy, nor an app named `x.swap` for a swap.
- **`snapshot` in the app's overrides**, a field older zigsaws don't know: it's written only when
  set, as `real_folders` is, so only a store where someone used it stops an older zigsaw reading
  that app's overrides.

## What changed

| File | What |
|---|---|
| `src/snapshot.zig` (new) | `keep` (the copy at install), `beforeRun` (an owed copy, a swap to finish), `swap`, `forget`, `prune`, the walk that copies or counts |
| `src/install.zig` | `Image.data`: `keep` by default, `leave` for a rollback that has the version's data |
| `src/rollback.zig` | `Data` (`ask`, `take`, `keep`, `only`), the question, the swap after the install, `--data-only` |
| `src/Store.zig` | `snapshots\`, `versions\<id>.data.json` and `.data-owed.json`, `KeptData` |
| `src/run.zig` | `snapshot.beforeRun` before a run that isn't `--ephemeral` joins the app's runs |
| `src/prune.zig`, `src/main.zig` | copies in `prune`'s report and notes, `--previous`; `rm`; `list`; the flags; usage |
| `src/override.zig` | `snapshot: ?bool` |
| `src/prompt.zig` | `askNoYes`: a question whose default is no |
| `src/win32.zig`, `src/updates.zig` | `CopyFileW`, `GetFileAttributesExW`; `Ago` made public |
| `tests/rollback.sh` | 23 new rows, 55 in all |
| `README.md`, `docs/how-it-works.md`, `docs/gaps.md` | the section on going back, the store's layout and the order of writes, and what stays open |

## Tests

All with the kit's frozen 0.87.0 on this machine (Windows 11, D: NTFS). "Final" is the build
that is in the tree now; "before" is the one before the threaded copy and my review's three
fixes (below), which differ from it in `src/snapshot.zig` only.

| What | Build | Result |
|---|---|---|
| `tests/rollback.sh` under `tests/zot.sh`: 32 rows as before, 23 new | final | 55 ok, 26 s |
| Unit tests, with new ones for the walk (a junction, what's left out, a copy over files, 2348 files by several threads) and the records | final | pass |
| `tests/store.sh`, `volumes.sh` | final | 17, 100 ok |
| `scripts/package.sh`, then `tests/install.sh`, `tests/upgrade.sh` on the package | final | 45, 30 ok |
| Microsoft Defender on the package's six programs (`zigsaw.exe` 6400bde4) | final | no threats |
| `tests/self.sh` on the package | final | 19 ok |
| Real PostgreSQL 18.6 from ghcr.io, `f0f2fa89` then `0198588f` over it, soft sandbox | final | see below |
| Data taken back, then written, under `--sandbox=appcontainer` and `--sandbox=low` (by hand) | final | read and written both ways |
| zigsaw 0.86.0 on a store 0.87 used, then 0.87 again (by hand) | final | see below |
| `tests/sandbox.sh`, `shims.sh`, `updates.sh`, `signing.sh`, `registry.sh` | before | 142, 55, 42, 58, 113 ok |

The new rows use an app whose every version reads only what it wrote itself: a file in its home
and a registry key it keeps. They cover the copy (hive included, Temp left out), `list`, `prune`,
the question with nothing, `y`, `n` and Enter answered, `--data`, `--keep-data`, `--data-only`,
both flags together, a run going on (refusals, the owed copy, the next run taking it), a swap
stopped after its first and after its second rename, a mounted volume, a write under the low
sandbox after taking data back, `--nosnapshot` and back, a record that names another version,
`prune --previous`, `rm`, and a stray folder.

**PostgreSQL.** A cluster made by the older image with one row; the newer image pulled over it
(`kept its data as 18.6 left it (39.9MiB in 978 file(s), copied in 280 ms)`); a second row. Then:

| Step | Rows the server has |
|---|---|
| on the newer image | first, second |
| `rollback --data` | first |
| a third row there, then `rollback --data` | first, second |
| `rollback --data` | first, third |
| `rollback --keep-data` (forward, data left) | first, third |

Both images are PostgreSQL 18.6, so this shows the data moving, not an older server refusing a
newer cluster: ghcr.io has no two majors to try that with. The suite's fixture stands in for it.

**What the copy costs.** A store on each drive, an app with that much data in its home, then an
install over it. The files had just been written, so they were read from memory: a copy of data
that isn't cached takes as long as reading it from the disk does.

| Data | Drive | Copied in | Free space fell by | `rollback --data` |
|---|---|---|---|---|
| 78 MiB in 20,000 files | D: (NTFS) | 6.0 s | 89 MiB | 0.4 s |
| 78 MiB in 20,000 files | E: (Dev Drive, ReFS) | 6.5 s | 53 MiB | 0.4 s |
| 100 MB in 1000 files | D: (NTFS) | 285 ms | 97 MiB | 0.1 s |
| 100 MB in 1000 files | E: (Dev Drive, ReFS) | 335 ms | 9 MiB | 0.1 s |
| 1 GB in 10 files | D: (NTFS) | 469 ms | 1000 MiB | 0.1 s |
| 1 GB in 10 files | E: (Dev Drive, ReFS) | 290 ms, 425 ms | 7, 8 MiB | 0.1 s |

One more run of the last row took 2.5 s, and its free-space figure was useless (the drive was
still freeing the run before). On the Dev Drive large files are clones; 4 KiB files save
little there, and take as long as on NTFS: it's opening and closing them that costs. The
0.4 s for a rollback with 20,000 files is counting what was set aside, for the record.

**An older zigsaw.** 0.86.0 on a store with a copy: `list`, `build` over the app, `rollback` and
`prune` all worked and left `snapshots\` alone. 0.87 afterwards didn't offer that copy, whose
record named a version no longer the previous one: `rollback --data` refused ("none of its data
is kept as 3 left it"), and a plain `rollback` kept a copy of its own. After 0.86's `rm`, which
leaves the folder and its record, 0.87's `prune` deleted both.

## What I got wrong on the way

- **A suite row expected the wrong copy.** After a rollback that left the data and a
  `--keep-data` forward again, the copy kept is of the data as it is by then, not the older
  version's first one. The row was mine to fix, but the behaviour is worth knowing: it's in
  gaps.md.
- **My first PostgreSQL check verified nothing**: its query had `","` for `','`, so every "rows"
  line was empty while the mechanics went through. Run again with the query right.
- **My first AppContainer probe read nothing** either (`type` with a `/` in the path). Fixed and
  run again; the result above is from the second run.
- **The first run of `tests/sandbox.sh` stopped in 1 s**: its helper's build failed reading a
  file of zig's own library while the unit tests were compiling beside it. Run alone it passed.
- **Three things my own review of `snapshot.zig` found**, after the suites were green, none of
  which a row had caught: a swap whose rename failed put the folders back but not the copy's
  record, so the copy was no longer offered and `prune` would have deleted it; an install over
  a swap that had stopped halfway dropped the copy before putting the data back; and the swap's
  folder, `<id>.swap` then, was a name an app's id could have. All fixed; the last has a row.
  The first two have none: I didn't find a way to make a rename fail on purpose in a suite.
- **The copy was one thread at first**, which I only saw as a problem when I measured many
  small files.

## Not checked

- **`tests/build.sh`'s base group and the matrix**: they need zig's download, which this kit has
  no seed for. `prune`'s report gained a part and a note, both silent while no copy exists. CI
  runs them.
- **CI itself**: `tests/rollback.sh`'s new rows on Windows Server 2025, the low-sandbox row
  among them.
- **A real change of data format** between two published versions of an app: none exists on
  ghcr.io.
- **A copy stopped by a file held open, or a full disk**: the code path warns and goes on; I
  didn't provoke either. Nor a swap whose rename fails.
- **`sandbox`, `shims`, `updates`, `signing` and `registry` on the final build**: they passed on
  the one before, and the difference is in the copy alone. CI runs them.
- **An owed copy taken by a run from a shortcut** (no console): the same code as from a command.
- **Data of many gigabytes, or read cold from the disk.**

## Yours to do

1. **Commit and push**: new `src/snapshot.zig` and `docs/iteration-87.md`. Nothing to publish.
   `reproduce.yml` didn't change, so it's a short run. I'll read Reproduce, `rollback.sh` first.
2. **Tag v0.87.0** when you want it released. I'll read Release.
