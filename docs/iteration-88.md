# Iteration 88: Builds that go on from the last one

Started 2026-11-11, from "plan to implement incremental build caching". zigsaw already reused a
whole image when a build's inputs were the same, kept tools' caches, and kept a project's
module's directory. Nothing worked between a recipe's modules: a recipe of 21 started at the
first after any change, failure or Ctrl+C, and nearly every kit since iteration 15 has a
`resume.sh` written by hand for that. Now a recipe's build root is kept, and its next build goes
on from it. zigsaw is **0.88.0**. No image changes, so there's nothing to publish. How it's used
is in [recipes.md](recipes.md#going-on-from-the-last-build), what it found in
[findings.md](findings.md#builds-that-go-on-from-the-last-one-iteration-88).

State at the start: 87 had landed (`8179442`, Reproduce 42941800184 and the v0.87.0 Release
green).

## Outcome

- **A module whose inputs are the same isn't built again.** Its inputs: zigsaw, the SDK and
  runtime images, the module as the recipe has it, its local files, the modules before it. What
  only shapes the image (`cleanup`, `exports`, the version) is no module's input: the layer is
  written again and nothing is built.
- **A module that stopped goes on at the command that didn't finish**, in its directory as that
  command left it. The commands before it aren't run again.
- **The prefix is put back first**, to how the last command that counts left it: files added
  since are deleted, files replaced since come back from a hard link zigsaw kept. A file that
  was written into, rather than replaced, can't come back: every module is then built again, and
  the build names the file.
- **With PostgreSQL's SDK**, 11 modules, killed at step 667 of 2084 of its compile: the next
  build skipped 8 modules and 7 commands, ninja went on with the 1417 steps left, and it ended
  in 2 min 16 s with the published digest, `sha256:4000d6e9…`. A build of every module takes
  7 min 17 s there. `--clean=sdk` then built the last module alone, which renames and rewrites
  other modules' files, in 4.8 s, to the same digest.
- **`--clean=<module>`** starts that module and those after it afresh. **`--no-resume`** builds
  every module in a new directory and reuses an image only if such a build made it; the scripts
  that publish or compare digests use it. **`--rebuild`** now also builds in a new directory
  and leaves the kept build alone.
- **A kept build is a whole build root**: 767 MB for PostgreSQL's SDK. `zigsaw prune` says how
  much they take; `prune --downloads` deletes them.

## Decisions

Yours (2026-11-11, by question):

- **Scope**: per-module resume, and kept directories for modules with only pinned sources. Not
  keys that survive a new zigsaw, nor a cache shared with CI.
- **The build root itself is kept**, one per recipe, over a snapshot of the prefix after each
  module.
- **A resumed build's image counts as any other, and scripts build in full.**

Mine, say if you disagree:

- **Steps are commands, not modules.** The plan you approved recorded the prefix after each
  module and ran a stopped module's commands again from the first. The proof showed why that
  isn't enough (below), so the record is now after each command.
- **A successful build keeps its root too**, as I said when you approved: going on at a module
  that *changed* needs it. This is the disk cost above.
- **`--rebuild` builds every module in a new directory.** Otherwise it would skip them all and
  only write the layer again, and the suites use it to build for real. In a project it used to
  go on in the kept directory; `tests/self.sh` uses `--clean` for that now.
- **A project's module still runs every command**, on its files as they are now, as since
  iteration 35. Only a module of pinned sources goes on at a command.
- **Keys are finer than "the recipe's bytes"**, which is what started a project afresh before.
  A change of version no longer does; a change to the module or one before it does.
- **A file is told by its size and modification time**, not Windows' change time, which making
  the hard link itself moves.
- **If a vendor step's commands have to run, every module is built again.** They run before
  anything is built, and the tools' folders start again after them, as only a first build's can.
- **The tools' folders (`B:\home`, `B:\data`) are kept with the root.** With no module skipped
  and no command to go on at, they start empty.
- **Another build of the same recipe meanwhile** builds every module in a directory of its own,
  and says so. A lock beside the kept build decides.
- **A record that can't be written doesn't fail the build.** It warns, and the next build goes
  back to what the record says.
- **`tests/build.sh` deletes the kept builds at each section**, and `published.sh` and
  `seed-store.sh` build with `--no-resume`: a runner's disk is small, and I can't measure it
  from here.
- **`prune` doesn't count the hard links**, which take no room of their own.
- **A kept build this zigsaw can't read is deleted**, as the work directories of 0.87 are.
- **The `resumed` mark is a second line in `cache\builds\<hash>`.** A zigsaw before 0.88 takes
  such a file for no entry and builds.

## What changed

| File | What |
|---|---|
| `src/checkpoint.zig` (new) | module keys, the state file, the lock, the prefix journal and its hard links, going back, the unit tests |
| `src/builder.zig` | `Resume` in place of `Work`; the root in place; skipping, going on at a command, a step after each command; `Sources.record`; alias shims left as they are |
| `src/Store.zig` | `EarlierBuild`: the build cache's digest and `resumed` mark |
| `src/main.zig` | `--clean=<module>`, `--no-resume`, usage |
| `src/prune.zig` | kept builds: wording, locks, sizes without the links |
| `src/win32.zig` | `CreateHardLinkW` |
| `scripts/rebuild.sh`, `scripts/publish.sh`, `tests/published.sh`, `tests/seed-store.sh` | `build --no-resume` |
| `tests/build.sh` | a `resume` section of 12 rows in the base group; the project rows on the new layout; kept builds deleted at each section |
| `tests/self.sh` | the copy's first build is `--clean` |
| `README.md`, `docs/recipes.md`, `docs/gaps.md`, `docs/how-it-works.md`, `docs/findings.md` | the new section, the project section, what stays open, what was found |

## Tests

All with the kit's frozen 0.88.0, the build that is in the tree now, on this machine (Windows
11; D: NTFS, E: a Dev Drive).

| What | Result |
|---|---|
| Unit tests, 5 new: keys, the state, the prefix going back, going on at a command, a file written into | pass |
| `GROUP=base tests/build.sh`: 93 rows as before, 12 new | 105 ok, 62 s |
| PostgreSQL's SDK, killed in its compile, built again (E:) | the published digest, 2 min 16 s |
| The same, `--clean=sdk` | the published digest, 4.8 s |
| The same, `--no-resume`: every module, though the store had the resumed build's image | the published digest, 7 min 17 s, no root left in `tmp\` |
| `tests/self.sh`: an incremental build of a copy = `--clean`'s = `zig build -Dstrip`'s | 20 ok |
| `tests/store.sh` | 17 ok, 23 s |
| Microsoft Defender on the six programs | no threats |

The 12 new rows, each on three BusyBox modules: a first build; the last module changed (only it
runs, and the image is `--rebuild`'s); only `cleanup` changed (nothing runs); a command that
fails once (the modules before aren't built again, then it goes on at that command, without what
it had left in the prefix, and its first command isn't run again); a file a later module
replaced (it comes back); one it wrote into (every module again, and the build says so);
`--clean=<module>`; `--no-resume` after a resumed build (builds in full, once); a module the
recipe lost; a kept build that can't be read.

The record costs little: 40 steps took 0.6 s in all while PostgreSQL's dependencies built, and
the 11 steps of the second build 3.7 s, most of it the step after `meson install` put 2,400
files in the prefix.

## What I got wrong on the way

- **The first design, which you approved, failed on the first real recipe.** Going on "in the
  module's directory" ran PostgreSQL's five `patch` commands again on fresh copies, which made
  Meson configure again, without the `PATH` its setup command has. The fixture's rows had all
  passed. The record went from one step a module to one a command.
- **Then the build still regenerated**, because I wrote the alias shims in `B:\bin` again at the
  start of each build, and Meson notes `strip.exe` as an input. Found by asking ninja
  (`-d explain`), with `B:` mapped to the kept root by hand.
- **A row of mine expected a project's module to be skipped after a version change.** Its
  `zigsaw.json` is one of the project's files, so it's built again, where it was.
- **`resume` is a keyword in Zig**, and the unit tests didn't say so: nothing in them reaches the
  build's code, so only `zig build` compiled it.
- **One `zig build` failed reading a file of zig's own library**, and my command went on to copy
  the old program to the kits. I saw it before anything ran with it, and guard on the build's
  result since.

## Not checked

- **CI**: the `resume` section on Windows Server 2025, and whether the base group's disk use is
  fine with a root kept through a section.
- **The matrix, `standard-user.sh`, and `build.sh`'s other groups** (zig, cmake-meson, langs):
  not run here. They build with a root that's now kept, and CI runs them.
- **Ctrl+C in a console**, rather than `taskkill /F`, and a power loss: the state and the journal
  are each written beside and renamed, but neither was provoked.
- **GTK's and Qt's chains.** Only PostgreSQL's SDK was stopped and built again. A module there
  that writes into another's file (CMake's `file(INSTALL)`, Python's `shutil.copy`) means every
  module again, which the build says; how often that is, I don't know.
- **A vendor step's module in a resumed build**: its rule is in the code, and no row has one.
- **Two builds of one recipe at once**: the lock has a unit test, no suite row.
- **A store on a volume without hard links** (FAT): a file replaced later then can't come back,
  so such builds start afresh more often.
- **A recipe whose module reads what another wrote into `B:\home` or its `B:\src`**: not tracked,
  as gaps.md says.

## Yours to do

1. **Commit and push**: new `src/checkpoint.zig` and `docs/iteration-88.md`. Nothing to
   publish. I'll read Reproduce, the base build group first.
2. **Tag v0.88.0** when you want it released. I'll read Release.
3. **`scripts/rebuild.sh` and `scripts/publish.sh` need a zigsaw of 0.88** from now on: an
   older frozen copy doesn't know `--no-resume`.
