# Iteration 35: ZLS's gap on Server 2025, incremental project builds, and GTK back in CI

Built 2026-10-20. Temurin's OpenJDK 25.0.5 still isn't released (Adoptium's
latest is 25.0.4.1; 25.0.5+7 is still early access), so the Java images stay
on it, and the re-pin stays a session of its own.

## Outcome

- **Iteration 34's Reproduce run was red** on one step: `tests/zls.sh`, in
  an AppContainer.
  - The runner is Windows Server 2025. There, Windows still denies an
    AppContainer the Mount Manager, so `zig env` fails, as the matrix's zig
    gap does, and ZLS finds neither zig's library nor the modules
    `build.zig` declares.
  - Those two checks are now a known gap where the probe finds that cause,
    as the matrix's are; on this machine they still pass.
  - The rest of that run was green, in 13.5 minutes: the parallel jobs of
    iterations 33 and 34 work.
- **A project's builds are incremental** (zigsaw 0.35.0).
  - A module built from a project's own files keeps its work directory,
    `B:\src\<module>`, between builds, as makepkg keeps `src/`, with what
    its build left there: `.zig-cache`, `build`, `target`.
  - Each build brings the sources up to date in it, writing only the files
    whose contents differ, so make, ninja and cargo see only those as new.
  - A file the last build edited in place is written afresh too, so a
    `sed -i` doesn't apply twice.
  - It starts afresh when zigsaw or the recipe changes, and with `zigsaw
    build --clean`.
  - Published recipes, with only pinned sources, are untouched.
- **GTK's family is back in CI**, after iteration 11 took it out.
  - Its 17 recipes are in five published groups of their own.
  - `tests/gtk.sh` and `tests/gtk3.sh` run in a new job, `gtk-suites`, in a
    store of the published images, which they now install again rather
    than build.
  - Not seen yet: the first run is after your push.

## Starting decisions

Made with you at planning (plan:
`C:\Users\Test\.claude\plans\plan-iteration-35-floating-breeze.md`):

- **Incremental project builds**: the module's **work directory is kept**,
  sources synced into it (over keeping only named cache directories),
  **by default, with `--clean`** (over opt-in per build or in the manifest).
- **GTK's family back in CI**, as groups, with its suites.
- Not picked: `jlink` runtimes, a new app.
- ZLS's gap first, whatever else.

## What was built

### ZLS's gap

- [`tests/acprobe.sh`](../tests/acprobe.sh) is new: the matrix's probe,
  sourced by [`tests/matrix.sh`](../tests/matrix.sh) and
  [`tests/zls.sh`](../tests/zls.sh). It builds and runs the probe, gives
  `ac_if <check...>`, and prints the probe's report.
- zls.sh expects `ac_if self-path-dos` of its two AppContainer hovers.
  - A failure where the probe finds the cause is reported as `gap`.
  - A gap that passes says so.
  - Syntax errors and the clean exit must pass everywhere.

### Incremental builds

[`src/builder.zig`](../src/builder.zig) (`Work`):

- **Which modules**: a module keeps one when it has build commands, no
  vendor step, and a directory among its sources. Host-toolchain builds
  never do, as they're never reused either.
- **Where**: the store's `cache\work\<key>\<module>`, with the key a hash of
  the recipe's real path and the app's id. It's moved into the build root
  before the module's sources are written, and back afterwards, as tool
  caches are, a failed build's too.
- **Its state**: `<module>.state` beside it holds a stamp, then the files
  the last build brought.
  - The stamp is `inputHash` without the project's files: zigsaw, the
    recipe, its other local files.
  - A different stamp, or no state, starts afresh.
- **Syncing**: [`Tree.syncFiles`](../src/Tree.zig) writes a file only if
  the work directory's copy differs in contents. It deletes the files of the
  last sync that the tree no longer has, and leaves anything else alone.
- **Command line**:
  - `--clean` deletes the project's work directories and builds even if
    nothing changed.
  - `--keep-build-dir` leaves them in the kept root, so the next build
    starts afresh.
- **Pruning**: `zigsaw prune` reports them, and `--downloads` deletes them.
  The store makes `cache\work`.
- **Version**: 0.35.0.

Docs: [recipes.md](recipes.md#incremental-builds), the README (projects,
commands, the store's layout), [gaps.md](gaps.md) and
[findings.md](findings.md).

### GTK's family in CI

- [`scripts/published-groups.txt`](../scripts/published-groups.txt) has five
  groups instead of `skip`:

  | group | recipes |
  |---|---|
  | `gtk-tools` | Perl, cargo-c, gettext |
  | `gtk` | GTK's SDK, its runtime, the two dictionaries |
  | `gtk-apps` | Text Editor, GTK 3's SDK and runtime, its demos, PyGObject's SDK and runtime, Meld, Gaphor |
  | `rnote` | Rnote |
  | `gnumeric` | Gnumeric |

  A group pulls what it doesn't build, so none waits on another.
- [`.github/workflows/reproduce.yml`](../.github/workflows/reproduce.yml):
  - the `published` jobs of those groups get 75 minutes; the others keep 30;
  - the new `gtk-suites` job (45 minutes) seeds a store with the 18 images
    with `tests/seed-store.sh --pull`, then runs gtk.sh and gtk3.sh.
- [`tests/published.sh`](../tests/published.sh):
  - every smoke run is stopped after two minutes, so a GUI app that ignores
    its arguments fails rather than holding up the job;
  - Rnote's smoke run is `--help`, as GTK's option parser has no
    `--version`;
  - the rest exit 0 as they are, Meld and Gaphor with their own versions.
- [`tests/gtk.sh`](../tests/gtk.sh) and [`tests/gtk3.sh`](../tests/gtk3.sh):
  - `install_again` re-installs an app the store has (for the test's
    shortcut folder and registry key) as the store got it: from the build
    cache if it built it, from the registry it was pulled from otherwise.
    So a pulled store isn't rebuilt: Rnote is 20 minutes, Gnumeric 25.
  - gtk.sh's OpenGL check is a known gap on a machine without a GPU (only
    Windows' basic display adapter, or Hyper-V's).
  - Pinta and .NET's images are still built from their recipes, there too:
    they're never published.

## Results

### Tests

| suite | result | time |
|---|---|---|
| unit tests | 97 | |
| `GROUP=base tests/build.sh` | 91 (84 + 7 new, the incremental fixture) | 42 s |
| `tests/self.sh` | 14 (6 + 8 new) | 6.5 min |
| `tests/zls.sh` | 19 | |
| `tests/matrix.sh` (with the shared probe) | 0 differ, 3 known gaps | 132 s |
| `tests/gtk3.sh`, on a store of pulled images only | 45 | 200 s |
| `tests/gtk.sh`, on the same store | 94 (MSVC's GTK skipped, not in the store) | 694 s |
| `GROUP=c tests/published.sh`, with zigsaw 0.35.0 | 38: all seven images have the published digests | 9 min |

- **The incremental fixture** runs BusyBox's make on two inputs. Checked:
  - a change remakes only its target, and the image equals a `--clean`
    build's;
  - a file the build edits in place is edited once;
  - a file the project lost is gone;
  - a recipe change starts afresh;
  - the project's directory gets no output;
  - prune keeps the work directories.
- **self.sh** builds a copy of the checkout, changes one of zigsaw's
  messages, and builds again: 51 s, against 60 s for the same files in a new
  work directory (zig's `${cache}` warm both times).
  - zig compiles `zigsaw.exe` as one unit, so the kept `.zig-cache` saves
    only the build runner and the shims. A project of many objects keeps
    more.
  - The three programs are the bytes of a `--clean` build and of a
    `zig build -Dstrip` of the copy.
- **Seeding** the GTK store from ghcr.io took 145 s here.
- `prune --downloads` empties `cache\work`; checked by hand too.

### Reproducibility

- No image changed, so nothing is republished. zigsaw's builds of published
  recipes don't go through `Work`.
- The GTK family hasn't been built on a runner since iteration 10. Its
  first run is the check, so a red GTK group is a finding, to fix next.

## Decisions made along the way

- **The work directory's files are compared with the sources' contents, not
  with the last sync's record** (my call). Recipes edit their sources in
  build commands, so a file whose source didn't change may still differ
  from it. Rewriting it makes the build edit a fresh copy, as a first build
  does. It costs a read of each file, which hashing the project reads
  anyway.
- **The stamp is the recipe's bytes and zigsaw's, not finer.** A change to
  build commands or SDK pins can leave a build directory configured for the
  old ones (CMake keeps cache entries a later configure no longer sets).
- **`--clean` also builds when nothing changed**, so that it can be
  compared with an incremental build.
- **Pinta stays in gtk.sh in CI** (over skipping it there, as planned):
  .NET's downloads come from Microsoft, which a runner reaches, and only
  publishing is ruled out.
- **The GTK groups' timeout is 75 minutes**, not the plan's 60: none has
  been timed on a runner.
- **The probe's id is now `test.acprobe`**, shared by both suites.

## Known gaps

- ZLS on Windows Server 2025, in an AppContainer: no hover on the standard
  library or a project's modules.
- `mlugg/setup-zig` v2.2.1, the latest, still runs on Node 20, so the
  workflow warns that GitHub forces it onto Node 24.
- An incremental build is as right as the project's tools; `--clean` is the
  way out.
- Still on OpenJDK 25.0.5 early access.

## For you

1. Commit and push. I then check the Reproduce run:
   - each GTK group's time, and whether it reproduces;
   - `gtk-suites`;
   - `suites`, green with ZLS's gap;
   - the run's total time.
2. Tag v0.35.0: zigsaw changed.
3. Nothing to republish.

## Suggested for iteration 36

- Whatever the first run with GTK shows.
- The Temurin 25.0.5 re-pin, when it's released.
- `jlink` runtimes made for each Java app.
- A C project of many files as an incremental proof, with CMake or Meson.
