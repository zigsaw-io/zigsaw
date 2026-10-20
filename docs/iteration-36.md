# Iteration 36: GTK's first run in CI, and zig's cache

Built 2026-10-20. Temurin's OpenJDK 25.0.5 still isn't released (25.0.4.1
is the latest; 25.0.5+7 is early access), so the Java images stay on it.

## Outcome

- **Iteration 35's run** was the first with GTK's family since iteration 10.
  It was red in four jobs, and took 58 minutes. GTK's SDK, its runtime, GTK
  3's, PyGObject's, Meld, Gaphor, Gnumeric, the demos and the dictionaries
  all reproduced. The four failures:

  | job | failure | cause |
  |---|---|---|
  | published (rnote) | Rnote's config differs | `recipes/rnote/*` checked out with CRLF on the runner |
  | published (gtk-apps) | Text Editor's config differs | the same, `recipes/gnome-text-editor/icu-uloc.h` |
  | published (gtk-tools) | cargo-c's files differ | **the published image is the odd one**: zig's cache made it (below) |
  | gtk-suites | PyGObject twice and Meld, in an AppContainer | Windows Server 2025: CPython warns it can't find its own real path |

- **zig's cache could change what a build makes.** On a cache hit, zig
  doesn't repeat clang's warnings, and BLAKE3's build script takes a warning
  to mean the compiler lacks AVX-512. So the same store built cargo-c two
  ways, and the image published for 0.10.25 (`c17e0473`) was the warm one.
  From zigsaw 0.36.0, each module has a zig cache of its own, fresh for each
  build; the C runtime stays cached.
- **A push checks GTK's family only when it changed.** That saves most of a
  run when it hasn't; a weekly run checks everything.
- **Build logs say where the time goes** (0.36.0): how long each command
  took, and the build in all. `tests/published.sh` gives each recipe's time,
  and CI's job summary a table of them.
- **When a published image's files differ**, `tests/published.sh` lists the
  files and keeps both versions of each in the logs.

## Starting decisions

Made with you at planning (plan:
`C:\Users\Test\.claude\plans\plan-iteration-36-purrfect-avalanche.md`):

- Fix the red run. **Defer cargo-c**, but add what shows its files.
- **Shorter GTK CI**: measure, then **keep zig's cache between CI runs**,
  with a weekly cold run. Not picked: jlink runtimes, a many-file C project
  for incremental builds.

Changed along the way, with you:

- The measurements found that the cache was the problem (below). You chose to
  **find the cause first**, then a **per-module zig cache**, **re-tagging
  cargo-c 0.10.25 to `5c3ab826`**, and **GTK's family only when it
  changes**, instead of the warm cache.

## What was built

### The red run's fixes

- [`.gitattributes`](../.gitattributes): one rule for every file under
  `recipes/`, `text=auto eol=lf`, instead of one per recipe directory.
  - On a clone with `core.autocrlf=true`, Rnote's five files and Text
    Editor's header now have the hashes their published configs record.
  - No image changes.
- [`tests/gtk3.sh`](../tests/gtk3.sh) runs the AppContainer probe
  ([`tests/acprobe.sh`](../tests/acprobe.sh)), as zls.sh does:
  - where `self-path-dos` fails, the PyGObject checks leave out CPython's
    `Failed to find real location of` line, and still check the rest
    exactly;
  - Meld's AppContainer window is a known gap there;
  - with `LOG_DIR` set, a failed draw leaves the run's output and Meld's log
    there, since why Meld fails isn't known yet;
  - it ends with the probe's report and a count of known gaps.
- [`tests/published.sh`](../tests/published.sh), when the files differ:
  - `files_diff` unpacks each layer the two images don't share;
  - it writes `<id>.files-diff.txt` ("differs", "only built", "only
    published");
  - it copies both versions of each such file into `<id>.differ\`, up to
    200 MB.

### zig's cache

Found by measuring cold and warm builds of cargo-c:

| store | build | digest |
|---|---|---|
| fresh | 1st, cold | `5c3ab826` (the runner's, and GTK's SDK's pin) |
| fresh | 2nd, warm | `5c3ab826` |
| fresh | 3rd | `c17e0473` (the published tag's) |
| `D:\zs\a` (2.5 GB zig cache) | as is | `c17e0473` |
| `D:\zs\a` | its zig cache set aside | `5c3ab826` |

- The two images have the same config. The programs of `c17e0473` have
  17 KB more code: BLAKE3's AVX-512 code, from an extra
  `libblake3_avx512_assembly.a`.
- BLAKE3's build script asks cc-rs whether the compiler takes `-mavx512f
  -mavx512vl`. cc-rs says yes only if the test compile succeeds and prints
  nothing.
- The recipe's `-D__MSVCRT_VERSION__=0x700` redefines zig's own, so clang
  warns. Once the test compile is in zig's cache (keyed by its `B:` path),
  zig hands back the object and prints nothing.
- A fresh `ZIG_LOCAL_CACHE_DIR` brings the warning back, while the global
  cache still serves the C runtime: a link took 1.2 s, against 124 s with
  nothing cached.

So [`src/builder.zig`](../src/builder.zig) sets each module's
`ZIG_LOCAL_CACHE_DIR` to `B:\src\<module>\.zig-cache`. That's where `zig
build` keeps it by default, so a project's kept work directory keeps it, and
`--clean` drops it. With it, the store that had built `c17e0473` builds
`5c3ab826`, and `D:\zs\a` does too.

- [recipes.md](recipes.md) no longer says a warm cache is safe for objects.
- The draft upstream report is `D:\zs\i36\up\zig-cc-cache-warnings.md`, for
  you to file: a two-command reproduction with `-Wunused-variable`.

### Timings

- `[<module> <n>/<count>] took 4m 07s` after each command that took a second
  or more, and `built <id> <version> in …` at the end of a build. Logs only.
- `Duration` in [`src/Context.zig`](../src/Context.zig) formats them, with a
  unit test.
- Version 0.36.0.

### GTK's family only when it changed

- [`scripts/ci-groups.sh`](../scripts/ci-groups.sh) `[<commit>]` prints the
  groups to run, as JSON, and `gtk=true|false`.
- GTK's groups (`changed_only`: gtk-tools, gtk, gtk-apps, rnote, gnumeric)
  run only if one of these changed since the commit:
  - the groups' recipes and their directories;
  - GTK's suites, their fixtures, and what the suites build (Pinta, .NET,
    the MSVC GTK) or seed;
  - what checks any group: published.sh, seed-store.sh, the groups and
    published lists, the workflow, `.gitattributes`, the script itself.
- With no commit, or one git can't compare with, it runs everything.
- [`.github/workflows/reproduce.yml`](../.github/workflows/reproduce.yml):
  - the `groups` job compares a push with the last commit a run on its branch
    passed on (`gh run list --status success`, so a red or cancelled run
    doesn't count), and a pull request with its base;
  - `gtk-suites` runs only when `gtk` is true;
  - a weekly run (Mondays 03:17 UTC), and one started by hand, check
    everything.
- Why the last passed run, not the previous push: a push that cancels an
  earlier one (the workflow's concurrency) would otherwise skip a GTK change
  the cancelled run never checked.

## Results

| check | result | time |
|---|---|---|
| unit tests | 106 | 9 s |
| `GROUP=base tests/build.sh` | 0 failed | 69 s |
| `tests/self.sh` | 13 (the incremental build 53 s, against 61 s fresh) | 6.5 min |
| `GROUP=c tests/published.sh` (fresh store, zigsaw 0.36.0) | all 7 images = published | 21 min |
| `tests/gtk3.sh` on a store of pulled images | 45, 0 gaps here | 4 min |
| cargo-c in `D:\zs\a`, 0.36.0 | `5c3ab826` | 7 min |
| `scripts/ci-groups.sh` | everything with no commit, a bad one, or a changed GTK recipe, fixture or the workflow; GTK left out for zigsaw's sources, docs and Java recipes | |

- **`files_diff`** was run on cargo-c's layer against a copy with one file
  changed and one added. It listed both, and copied them.
- **The workflow** parses (PyYAML); the `gh run list` query works here. The
  next run is its first.
- **self.sh's** step that edits the copy's `main.zig` with `sed -i` failed
  with TMP on another volume than the checkout. It now gives sed a POSIX path.
- **Build times, here**, from 0.36.0's lines:
  - cargo-c: vendor 1m 29s, `cargo build` 5m 57s;
  - group c: zig 9m 17s, zstd 3m 08s, ZLS 1m 39s, Meson 1m 34s.

## Decisions made along the way

- **The zig local cache is the module's `.zig-cache`** (my call). That's
  `zig build`'s own default, so projects keep theirs in their work directory.
  No recipe copies its module directory into `$PREFIX`, and no vendor step
  hashes `.`, so the directory doesn't reach an image.
- **No cache in CI** (your call, given the cause): a warm global cache would
  save only the C runtime, a few minutes a job.
- **`scripts/ci-groups.sh` is a script**, not inline YAML, so it can be run
  and tested here.

## Known gaps

- On Server 2025, in an AppContainer, Meld draws no window. Its log, from
  the next run's artifact, will say whether the cause is CPython's realpath.
- A zigsaw change that a GTK image no longer reproduces with shows within a
  week, not on the push.
- Still on OpenJDK 25.0.5 early access.

## For you

1. Re-tag cargo-c 0.10.25 to `sha256:5c3ab826…` (already on ghcr.io):
   `scripts/publish.sh recipes/cargo-c.json` with zigsaw 0.36.0 builds it and
   pushes that digest. GTK's SDK already pins it; nothing else changes.
2. File the zig report, `D:\zs\i36\up\zig-cc-cache-warnings.md`, if you
   agree.
3. Commit and push. The run checks everything: its last green run is
   iteration 32's. Expected green once cargo-c is re-tagged. Then I read:
   - the per-recipe times in the job summaries;
   - Meld's AppContainer log;
   - the `groups` job's decision.
4. Tag v0.36.0 (v0.35.0 was never tagged).
5. Delete the empty folder `D:\zs${s\}`, which a typo of mine made. Its
   store is emptied.
6. My long-used stores `D:\zs\a` and `D:\zs\b` built with the old cache:
   check a digest in a fresh store before publishing from them.

## Suggested for iteration 37

- Meld under AppContainer on Server 2025, from its log.
- Whatever the per-recipe times show for GTK's SDK and gettext.
- The Temurin 25.0.5 re-pin, once it's released.
- jlink runtimes; a many-file C project as the incremental proof.
