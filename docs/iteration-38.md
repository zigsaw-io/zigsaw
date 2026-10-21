# Iteration 38: gettext compiled in parallel

Built 2026-10-21. Temurin's OpenJDK 25.0.5 still isn't released (Adoptium's
latest is 25.0.4.1), so the Java images stay on 25.0.5 early access.

## Outcome

- **Iteration 37's run** (cb9df8e) took 39 minutes, down from 60, and every
  published group reproduced, GTK's SDK in its two halves included (the
  base's job 34 minutes, the SDK's 31).
  - One check failed: in `tests/gtk.sh`, an icon from an extension under
    `--sandbox=appcontainer` printed nothing.
  - The job passed when run again: a flake, once in four runs.
  - The check now shows the run's exit status, and the program flushes each
    line it prints, so if it happens again we'll know more.
- **BusyBox's `make` runs one command at a time**: its `-j` isn't
  implemented. gettext's longest step was a serial build.
- **gettext now compiles `$(nproc)` files at a time** and installs with
  BusyBox's `install`. Its image is the same, `f3f85ba5`, in three fresh
  stores. Here:

  | step | iteration 37 | now |
  |---|---|---|
  | gettext's `make` | 26m 41s | 10m 09s |
  | gettext's `make install` | 8m 32s | 4m 29s |
  | gettext's `configure` | 7m 22s | 7m 32s |
  | libiconv's three steps | 2m 58s (zig's cache warm) | 4m 19s (zig's cache cold) |
  | all the steps | 45m 37s | 26m 33s |

Expected on the next run: gettext's job, 39 minutes in iteration 37's run,
should take about 25. GTK's base half (34 minutes) is then the longest job,
so the run should take about 35. I haven't seen this yet: the first run
comes after your push.

## Starting decisions

Made with you at planning (plan:
`C:\Users\Test\.claude\plans\plan-iteration-38-stateless-hare.md`):

- **gettext's build time** (over a many-file C project, jlink runtimes, or
  the low sandbox as the default).
- **gettext and libiconv only**. Gnumeric's and GTK's SDK's autotools
  builds run serially too, and are left as a candidate.
- The image must stay byte for byte the same, and I'd stop and ask if only
  cuts that change it were left. That never came up.

Found while planning: an image's config records the files a recipe adds to
a build, but not its build commands or a module's environment. So the
wrapper is written by a build command. As a file of the recipe's, it would
have changed gettext's digest.

## What was built

### The red check

- [`tests/gtk.sh`](../tests/gtk.sh) `icon()`: fails on a non-zero exit as
  well, and says `got (exit N): …`.
- [`tests/gtk/icon.c`](../tests/gtk/icon.c): `fflush(stdout)` after each
  line, so a crash at exit still shows what it printed.
- [`tests/published.sh`](../tests/published.sh) `up_to_date()`: on failure
  it prints `zigsaw update`'s output, which went to `grep -q` before. A
  local run failed there once with nothing to show, and passed again
  straight away.

### gettext's build

[`recipes/gettext.json`](../recipes/gettext.json):

- The first module, crt-noexport, writes `pmake.sh` with `printf`. It's
  passed as `MAKE="sh B:/src/crt-noexport/pmake.sh"`, which BusyBox's make
  hands to every sub-make through `MAKEFLAGS`. For each call it:
  - lets dry runs (`-n`) and every target but `all-am` (or an `all` that is
    `all-am` alone) through to make;
  - takes `make -n`'s list, makes the `.dirstamp` files it names, and runs
    its ` -c -o ` lines with `xargs -0 -r -P "$(nproc)"`;
  - leaves a failed compile to make, which then compiles it again;
  - runs make, which links.
- Why it waits for `all-am`: by then the directory's `BUILT_SOURCES` exist,
  gnulib's replacement headers among them. An object compiled earlier could
  include another header of the same name and still compile.
- Why the `.dirstamp` files: objects in subdirectories (`glthread/`,
  `unictype/`, …) depend on their directory's `.dirstamp`, which make
  creates as it first needs it. Made after the objects, it's newer, and
  make compiled them all again. A timed run of the wrapper found 380 such
  compiles among the 1,400.
- libiconv's `make` uses the wrapper too. Its gnulib directory goes
  parallel; its own Makefiles aren't automake's and stay serial, with few
  objects.
- gettext's `make install` gets `INSTALL="install -c"`. Under BusyBox,
  configure finds no `install` and falls back to automake's `install-sh`, a
  shell script run for each of about 2,200 files. With BusyBox's own, the
  prefix is the same, file for file. libiconv's install takes 10 seconds
  either way, and is left as it was.
- The `make` lines lose `-j"$(nproc)"`, which did nothing.

Where gettext's `make` spends its 10 minutes now (from the timed run,
before the `.dirstamp` fix; seconds, here):

| directory | compiles in parallel | then make |
|---|---|---|
| gettext-tools/gnulib-lib | 436 in 86 s | 147 s, of which 119 compiles again |
| libtextstyle/lib | 230 in 52 s | 98 s, 96 again |
| gettext-tools/libgettextpo | 220 in 40 s | 93 s, 95 again |
| gettext-tools/src | 174 in 28 s | 100 s: 21 links, 27 compiles again |
| gettext-runtime/gnulib-lib | 150 in 10 s | 4 s |
| gettext-tools/gnulib-tests | 78 in 6 s | 38 s: 7 links |
| the rest | 130 | |

With the `.dirstamp` fix, make compiles 6 files after the parallel passes
instead of 390. What's left is mostly libtool's 44 links, one at a time.

### Docs

- [docs/findings.md](findings.md): the serial make, the `.dirstamp` files,
  `install-sh`. This corrects iteration 37's reading.
- [docs/recipes.md](recipes.md): gettext's wrapper and install.
- [docs/gaps.md](gaps.md): which builds still compile one file at a time.

## Results

| check | result | time |
|---|---|---|
| toy Makefiles shaped like automake's, with BusyBox's make | `MAKE` reaches nested sub-makes; parallel only at `all-am` or a plain `all`; dry runs pass through; each object compiled once | seconds |
| gettext, first version (fresh store) | `f3f85ba5` | 33m 41s |
| gettext with the `.dirstamp` fix (fresh store, kept) | `f3f85ba5`; make compiles 6 files itself | 34m 36s |
| `make install` again in that build, with BusyBox's `install` | the same 2,590 files (35 HTML pages differ, because my run had the host's Perl and texi2html rebuilt them; a build has no Perl) | 4m 43s |
| gettext, final recipe (fresh store) | `f3f85ba5` | 33m 03s, of which 5m 39s pulling zig's image |
| `GROUP=gettext tests/published.sh` on that store | 0 failed (the first run: one transient "is up to date" failure) | |
| the rerun of iteration 37's failed job | passed | 17 min |
| `tests/gtk.sh` on a store of pulled images | 94, 0 failed (GTK with MSVC skipped: not in the store) | about 12 min |

## Decisions made along the way

- **The `.dirstamp` files first** (my call): the timed run showed the
  objects compiled twice.
- **gettext installs with BusyBox's `install`** (my call): a build command,
  the same files.
- **Left as they are:** `configure` (7½ minutes here, 7 on a runner), the
  44 links, and the 2,200 calls to `install`. Below the base half's 34
  minutes, a shorter gettext doesn't shorten the run.
- **No version, no republish:** zigsaw didn't change, and neither did the
  image.

## Known gaps

- Gnumeric's and goffice's builds, and hunspell's and enchant's in GTK's
  SDK, still compile one file at a time.
- The AppContainer icon check's flake isn't explained. It passed in the
  rerun and here.
- Still on OpenJDK 25.0.5 early access.

## For you

1. Commit and push. The run checks every group, since gettext's recipe and
   the GTK suites changed. Then I read gettext's job time and its slowest
   commands.
2. Tag v0.36.0, which is still untagged. zigsaw itself hasn't changed
   since.

## Suggested for iteration 39

- The same wrapper, and BusyBox's `install`, for Gnumeric and goffice, and
  for GTK's SDK's hunspell and enchant.
- GTK's base half, then the longest job: its slowest commands are gtk's
  `meson install` (8m 42s on the runner), libtiff's CMake configure (4m)
  and HarfBuzz's install (3m 37s).
- The Temurin 25.0.5 re-pin, once it's released; jlink runtimes; a
  many-file C project as the incremental-build proof.
