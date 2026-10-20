# Iteration 37: a green GTK run, and GTK's SDK in two halves

Built 2026-10-20. Temurin's OpenJDK 25.0.5 still isn't released (Adoptium's
latest is 25.0.4.1), so the Java images stay on 25.0.5 early access.

## Outcome

- **Iteration 36's run** (0e26912, 60 minutes) was red in one job,
  `gtk-suites`, on two checks. Every published group reproduced, so cargo-c's
  re-tag worked.

  | check | cause | now |
  |---|---|---|
  | gtk.sh: libsoup, `--sandbox=low` | badssl.com dropped the connection (`Error receiving data`) before TLS answered | a network error there runs the check once more |
  | gtk3.sh: Meld's git, AppContainer | `could not open '/dev/null'` | a known gap where the probe finds NUL denied |
  | gtk3.sh: Meld's window, AppContainer (a gap already) | Meld's log, from the run's artifact: `open(os.devnull)` → `PermissionError: 'nul'`, not CPython's realpath | gated on NUL instead |

  On Windows Server 2025, an AppContainer can't open NUL, and a non-admin
  can't change that. On this machine's Windows 11 26300 it can, and both
  checks pass.
- **GTK's SDK is built in two halves**, which CI builds at once:
  **[`org.gtk.Gtk4.Sdk.Base`](../recipes/gtk4-sdk-base.json)** (the modules
  up to and including GTK), and the SDK on top of it.
  - The SDK's files are **byte for byte what one build made**: its layer is
    the published one's, `17cd3324…`. Only its config changes, since it now
    records the base as an image source. So GTK's runtime, its apps and the
    SDKs built on GTK's keep their pins.
  - Here, the halves took 19 and 16 minutes, against 38 for one build. On
    the runner one build took 57 minutes, the run's longest job.
- **gettext has a job of its own**, and builds a little faster.
  - Out of `gtk-tools`, whose 55 minutes were mostly gettext's 39.
  - Without dependency tracking: 46 minutes here instead of 50, the same
    image.
- **CI keeps every published job's build logs** (14 days), and
  `tests/published.sh` lists each recipe's five slowest commands, in the log
  and the job's summary.

Expected next run: the longest GTK job is gettext's (about 37 minutes on a
runner) instead of the SDK's 57, so the GTK family's part of a run should
take about 40 minutes instead of 60. Not seen yet: the first run is after
your push.

## Starting decisions

Made with you at planning (plan:
`C:\Users\Test\.claude\plans\plan-iteration-37-synchronous-tower.md`):

- The NUL failures are **known gaps, gated on the probe** (over patching
  Meld's launcher).
- **A shorter GTK CI**: measure first, then cut, keeping every image's
  files.

Changed along the way, with you:

- The measurements showed that GTK's SDK spends its time compiling, spread
  across its modules, so changing its commands would save a few minutes at
  most. You chose to **split the SDK in two images** (over small cuts only,
  or stopping at the data).

## What was built

### The red run's fixes

- [`tests/gtk3.sh`](../tests/gtk3.sh): Meld's window and Meld's git support
  under AppContainer are `check_want "$(ac_if nul)"`. CPython's getpath
  warning stays gated on `self-path-dos`.
- [`tests/gtk.sh`](../tests/gtk.sh) `soup()`: when the untrusted host's line
  is a network error (`Error receiving data`, `Error sending data`, `Could
  not connect`, `Connection terminated unexpectedly`, `Socket I/O timed
  out`, `Error resolving`), it runs once more. Any other answer is checked
  at once. `SOUP_UNTRUSTED` sets the host.
- [docs/gaps.md](gaps.md) says why Meld and git fail there.

### The data

- [`.github/workflows/reproduce.yml`](../.github/workflows/reproduce.yml):
  the `published` jobs upload their logs unless cancelled, kept 14 days.
- [`tests/published.sh`](../tests/published.sh) `slowest`: from a build log's
  `[<module> <n>/<count>] <command>` and `[...] took <time>` lines, the five
  slowest commands, slowest first, as `slow` lines after the recipe's
  `time`, and as rows under it in the job's summary.

Measured in a fresh store, with zigsaw 0.36.0 and every CPU (16 here); all
images equal to the published ones:

| recipe | here | on the runner (iteration 36) |
|---|---|---|
| Perl | 1m 24s | 29 s |
| cargo-c | 9m 55s | 12m 57s |
| gettext | 50m 15s | 38m 45s |
| GTK's SDK, one build | 37m 48s | 56m 48s |

GTK's SDK, by module (here, seconds):

| module | time |
|---|---|
| librsvg (its vendor step and `meson install`, which runs cargo) | 379 |
| gtk | 258 |
| openssl | 179 |
| glib-introspection | 147 |
| glib | 128 |
| harfbuzz | 116 |
| enchant | 111 |
| hunspell | 98 |
| the other 34 | 549 |

The SDK's modules up to and including gtk took 999 s here, librsvg aside,
and the rest 968 s with it: two halves of about the same size.

gettext, by command (here):

| command | time |
|---|---|
| gettext's `make -j` | 26m 29s |
| gettext's `configure` | 9m 59s |
| gettext's `make install` | 8m 26s |
| libiconv's `configure` | 2m 48s |
| libiconv's `make -j` | 1m 37s |

gettext took longer here, with 16 CPUs, than on the 4-CPU runner, so its
time isn't spent compiling: it's libtool's shell scripts and the processes
they start under BusyBox.

### GTK's SDK in two halves

- [`recipes/gtk4-sdk-base.json`](../recipes/gtk4-sdk-base.json): the SDK's
  first 26 modules, crt-noexport to gtk, as they were.
  - The SDK's SDKs and runtimes, so each module builds with the same tools
    on its `PATH`.
  - The same cleanup (`__pycache__`).
  - No exports: it's the SDK's source, not for builds of its own.
  - Its command is `gtk4-demo`, which `published.sh`'s smoke run asks for
    `--version`.
- [`recipes/gtk4-sdk.json`](../recipes/gtk4-sdk.json): crt-noexport again
  (nine of its modules link that module's `noexport.o`, from its directory,
  which isn't in an image), then the base as an image source, then the
  other 16 modules as they were.
- Why the files don't change: the base is a prefix of the module list, so
  each module after it sees the same `$PREFIX` it saw in one build. A
  config records SDK digests, sources' hashes and image sources, but not
  build commands.
- [`scripts/published-recipes.txt`](../scripts/published-recipes.txt) lists
  the base before the SDK. Groups:

  | group | recipes |
  |---|---|
  | gtk-tools | Perl, cargo-c |
  | gettext | gettext |
  | gtk-base | the base |
  | gtk | the SDK, the runtime, the dictionaries |

  [`scripts/ci-groups.sh`](../scripts/ci-groups.sh)'s `changed_only` and the
  workflow's timeout know the new groups. A job pulls what it pins, so the
  SDK's job pulls the published base and doesn't wait for the base's job.
- [`scripts/publish.sh`](../scripts/publish.sh) `--skip-unchanged` also
  picks a recipe when a file one of its sources names by `path` changed.
  The base's patches are in `recipes/gtk4-sdk/`, the SDK's directory, so
  the old rule (the recipe, or the directory named like it) missed them.
- [docs/recipes.md](recipes.md) and the [README](../README.md) describe the
  base.

### gettext

- [`recipes/gettext.json`](../recipes/gettext.json): both `configure` runs
  get `--disable-dependency-tracking`, which leaves out a `depcomp` script
  per object. Same image, `f3f85ba5`.
- In `gettext`, a group of its own.

## Results

| check | result | time |
|---|---|---|
| `GROUP=gtk-tools tests/published.sh` (fresh store) | 0 failed | 62 min |
| `GROUP=gtk tests/published.sh` (the same store) | 0 failed | 41 min |
| base, in that store, then the SDK on it | base `542571a6`; the SDK's layer = the published SDK's | 19m 12s, 16m 26s |
| base, in another fresh store | `542571a6` | 24m 46s |
| gettext without dependency tracking (fresh store) | `f3f85ba5`, the published image | 46m 04s |
| `tests/gtk3.sh` on a store of pulled images | 45, 0 failed, 0 gaps | 4 min |
| `tests/gtk.sh` on the same store | 94, 0 failed (GTK with MSVC skipped: not in the store) | 12 min |
| `soup()` with a stub for zigsaw | network error twice: fails after two runs; once: passes; an accepted untrusted root: fails at once | |
| `slowest` and the summary rows | on the logs above, and iteration 36's | |
| `scripts/ci-groups.sh` (in a scratch clone) | every group with no commit or a GTK recipe changed; GTK left out for zigsaw's sources | |
| `scripts/check-pins.sh` | missing only the base, which isn't published yet | 50 s |
| the workflow | parses (PyYAML) | |

## Decisions made along the way

- **The cut is after gtk** (my call): it halves the time, and it's a prefix
  of the module list, so no module's inputs change.
- **The base has all the SDK's SDKs** (my call), Rust and Perl included,
  though its modules use neither: a tool on `PATH` that a build might
  notice would otherwise differ. It costs the base's job a Rust pull.
- **The runtime keeps its pin on the old SDK** (`eed28b79`). The new SDK's
  files are the same, and re-pinning would mean republishing the runtime
  and every app on it.
- **gettext's `make` (26 minutes) is left as it is.** It isn't compile time,
  and finding where it goes takes a build with its directory kept. A
  candidate.

## Known gaps

- On Server 2025, in an AppContainer: Meld draws no window, and git (from
  MinGit's image) fails on `/dev/null`. NUL is denied there.
- gettext is now the GTK family's longest job, at about 37 minutes on a
  runner.
- The first run with two halves isn't seen yet.
- Still on OpenJDK 25.0.5 early access.

## For you

1. Publish the base, then the SDK, in that order:
   `scripts/publish.sh recipes/gtk4-sdk-base.json recipes/gtk4-sdk.json`.
   - The base's digest must be `sha256:542571a6…`. That's what the SDK
     pins, and two fresh stores built it.
   - The SDK's new digest is `sha256:cd2e5667…`, with the same layer as
     now.
   - Then make `org.gtk.Gtk4.Sdk.Base`'s package public, and
     `scripts/check-pins.sh` should report nothing missing.
2. Commit and push. The run checks GTK's family, since its recipes
   changed. Then I read:
   - the job times, against 60 minutes;
   - the slowest commands in the summaries.
3. Tag v0.36.0 (zigsaw itself didn't change).

## Suggested for iteration 38

- gettext's `make`, from a kept build directory.
- The Temurin 25.0.5 re-pin, once it's released.
- jlink runtimes; a many-file C project as the incremental proof.
