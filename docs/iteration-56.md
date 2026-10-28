# Iteration 56: the store stays medium, and programs written at low start at medium

Built 2026-10-29. zigsaw **0.56.0**. No image changed: nothing to publish.

## Outcome

- **No run labels zigsaw's store any more.** Iteration 55's run reproduced
  every group; its one red row, Kanboard's smoke run, served "The directory
  … must be writeable": PHP's `is_writable()` at low integrity, under an
  image that asks for soft. tests/published.sh ran its smoke runs from its
  scratch folder, which held the pull store; MinGit, low with `cwd`,
  labelled the folder, the label reached every deployment, and Windows
  started php.exe at low. Any user running a low app with `cwd` from a
  folder that holds their store would have done the same (v0.54.0 was never
  tagged, so no release has the low default). zigsaw now treats the store,
  the folder `zigsaw.exe` is in, a folder that holds either, and a folder
  inside them, as it treats your profile: a working directory there is
  read-only for the run, an explicit path is refused, under
  `--sandbox=appcontainer` too (for writing), and a label an older zigsaw
  recorded there is taken back by the app's next run's end or `zigsaw
  repair`. A soft run of a program labelled low says it'll run at low.
- **Programs a run writes start at medium integrity.** What a run writes
  comes out labelled low, by its folder's label or because a low-integrity
  process wrote it (an AppContainer's), and Windows starts a program
  labelled low at low integrity wherever it's started from: 7-Zip extracting
  a program, MinGit checking one out, or a soft build in a folder a low run
  labelled, made programs that ran at low everywhere. zigsaw now watches the
  folders a run may write, and when the app's runs have all ended, gives
  each low-labelled program written there (`.exe`, `.com`, `.scr`) a medium
  label of its own; the app's next low or AppContainer run labels them low
  again while it goes, so the app can still write them.

## Starting decisions

From the planning session (plan file `plan-iteration-56-breezy-emerson.md`):

- **Programs written at low** as the iteration's feature (your pick, over
  fixes only, Zig 0.17.0, or AF_UNIX sockets).
- **Unlabel at run end** (your pick, over a warning only, or a command):
  watch the run's writable host folders, take the label off when the app's
  runs end, label low again for its next low or AppContainer run, in all
  three sandboxes.
- Mine: the store rule covers zigsaw's own folder too (iteration 55's
  `zig-out\bin\zigsaw.exe` ran at low after a run in the repository), and
  AppContainer write grants, which would let an app change other apps'
  files.

## What was built

### Slice 0: probe

Facts in [findings](findings.md#programs-written-at-low-integrity-iteration-56).
The plan's way to take a label off, a protected SACL without one, fails
with 1314: changing whether a file inherits its label takes
SeSecurityPrivilege. An own medium label works unelevated, beats the
inherited low one, and survives the folder being labelled again; an own low
label lets low-integrity processes write the file again. ReadDirectoryChangesW
sees what low and AppContainer processes write, renames into place too.

### Slice 1: never the store

- [src/grants.zig](../src/grants.zig): `Own` (the store, zigsaw's folder)
  and `Own.refusal`; `isWithin` moved here from run.zig. `Standing.keeps`
  doesn't keep a label, nor write access, where `Own.refusal` says no, so
  `settle` takes back what an older zigsaw recorded there.
- [src/run.zig](../src/run.zig): `labelRefusal` asks `Own.refusal` after the
  drive root and the profile; AppContainer write grants get the same rule.
  The advice says "a folder elsewhere" where no folder inside would do.
  A soft run warns when its program's label (its own or inherited, new
  `acl.effectiveLabel`) is low.
- [src/acl.zig](../src/acl.zig): `belowMedium`. Found while checking repair
  by hand: a zigsaw that itself runs at low (its program was labelled)
  writing an empty label leaves an own low label on the folder and
  everything in it. `acl.unlabel` refuses below medium, and `settle`
  leaves the app's grants to the next zigsaw that isn't (a shim a low run
  starts runs zigsaw at low).
- [tests/published.sh](../tests/published.sh) and
  [tests/registry.sh](../tests/registry.sh) run from `$work\cwd`, outside
  their stores (registry.sh's Prettier, low with `cwd`, had the same latent
  bug). The other suites' stores are separate temporary folders.

### Slice 2: programs written at low

- [src/written.zig](../src/written.zig): `Watcher` (one thread, an I/O
  completion port, ReadDirectoryChangesW over each folder, 64 KB buffers;
  when a folder's changes overflow, a walk of it for programs written since
  the run started, up to 50,000 entries), `record` (into
  `grants\<id>.programs`, under grants.lock, saying how many are new),
  `relabel` (an own low label, for low and AppContainer runs), `settle` (an
  own medium label, when the app's last run ends; forgets programs that are
  gone).
- run.zig watches the run's writable host folders: not the data directory,
  not what the run may only read after all; under soft, only folders
  labelled low already.
- [src/Store.zig](../src/Store.zig): `readPrograms`/`writePrograms`;
  `deleteGrants` (rm) and `listGrantIds` (repair) know the file.
- [tests/sandbox.sh](../tests/sandbox.sh): 11 rows, with tests/hostprobe.zig
  as the program, as it prints its own integrity level.

## Results

| check | result | time |
|---|---|---|
| `zig build test` | 134 passed (2 new: `Own.refusal`, `isProgram`; `isWithin` moved) | |
| tests/sandbox.sh | 119 ok, 0 failed (11 new rows) | 24 s |
| tests/matrix.sh (`D:\zs\i55\p`, missing apps built) | 0 differ, 3 known gaps | 129 s of checks, 14 min with the builds |
| `GROUP=base` tests/build.sh, from a scratch directory | 92 ok | 61 s |
| tests/network.sh | 26 ok | 68 s |
| CI's failure, by hand (`D:\zs\i56\kbrepro.sh`: MinGit `--version` at low from the folder holding the pull store, then Kanboard) | 0.54.0: folder and php.exe labelled low, "must be writeable"; 0.56.0: read-only cwd warning, nothing labelled, login page served | |
| `zigsaw repair` (0.56.0) on the store 0.54.0 labelled | label taken back, php.exe unlabelled, MinGit's grant gone | |
| the repository's ACL after all of it | no label, no AppContainer entry | |

Not run again: tests/published.sh (CI's apps group runs it from its new
working directory), and the suites of apps whose images didn't change.

## Known gaps

In [gaps](gaps.md), rewritten: programs written by other names, while
zigsaw didn't watch, or started before the app's runs ended still start at
low; another app's low run can't write into a program zigsaw took the label
off for this app; a zigsaw running at low takes nothing back. New: the
store, zigsaw's folder, and folders that hold them can't be a run's
writable working directory.

## Next

- Commit and push (nothing to publish), then tag **v0.56.0**: v0.54.0 was
  never tagged.
- Then I read the run: published (apps) with Kanboard's smoke row, and
  sandbox.sh's new rows on Server 2025.
