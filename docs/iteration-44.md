# Iteration 44: parallel downloads, and asking before an install

Built 2026-10-23. zigsaw **0.44.0**. No image changes, nothing to republish.

## Outcome

- **A build's downloads go eight at a time.** TeX Live's 432 files
  (233 MiB) took 72 s from an empty download cache, where one at a time
  took 8 to 10 minutes. This covers recipes without build commands too:
  prebuilt apps' sources used to be fetched one by one while being placed.
- **An image's layers download four at a time** on `pull`, `update`, and when
  a build pulls the SDKs and runtimes it pins. Pulling Meld, whose runtimes are
  five layers, into an empty store took 19 s instead of 29. Most of what's
  left is deploying (10 s).
- **`pull` asks before it downloads an app's layers.** It says what the app
  is, brings and may reach, in `info`'s words, then asks `Install it? [Y/n]`.
- **`update`, and a `pull` over an installed version, ask only when the new
  version may reach more.** That means the network where it couldn't, a
  location it couldn't use (or could only read), or a registry key it didn't
  keep. They then say only what's new.
- **Without a console, the answer is the next line on stdin.** No answer
  is no: the command fails, saying to add `--yes`, and nothing beyond the
  config has been downloaded. Scripts and CI pass `--yes`.
- **`build` never asks**: the recipe is yours, and so are the images it pins.

## Starting decisions

Made with you at planning (plan:
`C:\Users\Test\.claude\plans\let-s-plan-iteration-44-gleaming-ladybug.md`):

- **Parallel downloads and install consent**, over TeX Live collections as
  extension images and Ghostscript in parallel with its DLL.
- **Parallel downloads for build sources and layer pulls.** Pushes stay one
  blob at a time.
- **Refuse without `--yes` when nobody can answer**, over going on as before
  whenever there's no console.

Mine:

- **Asking only about access that grows.** File types, commands, shortcuts
  and extension points don't count. They don't reach anything, so they're
  shown but not asked about.
- **`[Y/n]`**, as Flatpak's default.
- **8 workers for sources and 4 for blobs.** 8 for sources was measured
  (below). Blobs come from one registry, and an app has a handful of them.

## What was built

### Parallel downloads

- **`Fetcher.fetchAll`** ([`src/fetch.zig`](../src/fetch.zig)):
  - It takes every URL source whose sha256 isn't in the download cache,
    once per hash.
  - Workers in an `Io.Group` share one index, as layer extraction does, and
    each has its own HTTP client, so connections to a mirror are reused.
  - zig 0.16's arena allocator is thread-safe, and so is `io.random` (for
    tmp names), so the workers share the context.
  - After the first failure, no new download starts. The ones under way
    finish and stay cached.
  - `-v` prints a summary line ("fetch 432 files (233.1MiB), 8 at a time").
- **The builder calls it before any module is built or placed**
  ([`src/builder.zig`](../src/builder.zig)), with or without build commands.
  The `fromSources` fallback works from inside a worker, as it opens its own
  registry connection.
- **`downloadBlobs`** ([`src/remote.zig`](../src/remote.zig)):
  - It takes the layers the store doesn't have.
  - Each worker gets its own `Registry`, with the main one's token and
    credential, so the token isn't asked for again. A refused token is
    refreshed once per worker, as before.

### Consent

- **`oci.Access` and `oci.addedAccess`** ([`src/oci.zig`](../src/oci.zig)):
  what one version may reach that another couldn't.
  - A location inside one the app had counts as had.
  - `rw` where it had `:ro` counts as new.
  - The same goes for keys under a kept key.
- **[`src/prompt.zig`](../src/prompt.zig)** is new:
  - It has login's console reader, moved out of credentials.zig unchanged.
  - `askYesNo` reads at a console, or else the next line of a process-wide
    stdin reader, so `update` of several apps reads one line per question.
  - An answer it can't take asks again.
- **`remote.fetch`** takes a `consent` option: `not_asked` for builds, `ask`,
  or `given` (`--yes`). It looks up an installed version of the app itself
  once it has the config, so a pull by full reference counts as an update
  too.
- **`info`** ([`src/info.zig`](../src/info.zig)) shares `writeName` and
  `writeContents` with the question. Its own output is byte for byte what
  0.42.0 prints (checked on Meld).
- **`pull [--yes]` and `update [--yes]`**: the flags and the usage text.

### Tests, scripts and docs

- **[`tests/registry.sh`](../tests/registry.sh)** has 8 new checks:
  - Consent:
    - with nothing to answer, nothing is downloaded (no layer blob);
    - answered no;
    - answered yes, after an answer it can't take;
    - an update that may reach more asks, saying only what's new;
    - one that may reach the same doesn't;
    - a pull of an older version over the installed one says what it no
      longer permits, without asking.
  - Parallel downloads:
    - a recipe of 12 files from busybox's httpd fetches them 8 at a time;
    - one that changed on the server fails the build, naming it, and a second
      build fetches only what the first didn't keep.
- **`--yes` added** to the registry calls in registry.sh, published.sh,
  seed-store.sh (so CI's suites jobs), gtk.sh, gtk3.sh and qt.sh. store.sh,
  sandbox.sh, shims.sh and build.sh only update apps built from recipes.
- **Docs**:
  - README: the usage lines, consent under "Sharing apps through
    registries", and `update`'s question.
  - recipes.md: downloads eight at a time.
  - gaps.md: TeX Live's sequential downloads are gone.

## Results

| check | result | time |
|---|---|---|
| unit tests | 113 passed (new: `addedAccess`, `parseAnswer`) | |
| TeX Live's fetch phase, fresh store, 8 workers | 432 files, 233.1 MiB, no fallback to the registry's sources | 72 s (was 8–10 min) |
| the same, 4 workers | | 127 s |
| `pull org.gnome.Meld`, empty store, 0.42.0 / 0.44.0 | same image | 28.7 s / 19.1 s |
| `info org.gnome.Meld`, 0.42.0 / 0.44.0 | identical output | |
| `tests/registry.sh` (zot) | 85 ok, 0 failed | 5 min |
| `tests/store.sh` | 15 ok, 0 failed | 22 s |
| `GROUP=base tests/build.sh` | 91 ok, 0 failed | 43 s |
| `tests/self.sh` | 13 ok, 0 failed (version check included) | 7.6 min |

Not run here: the GTK, Qt and TeX Live suites. Their only change is
`pull --yes` in `install_again`, and CI's suites jobs pull through
seed-store.sh, which the next run exercises.

## Known gaps

- **Pushes stay one blob at a time.**
- **No progress bar.** Eight downloads print their "fetching" lines as they
  start, and nothing more until the summary (`-v`) or an error.

## For you

1. **Commit and push.** `src/prompt.zig` is new.
2. **Tag v0.44.0**: build.zig.zon and zigsaw.json both say 0.44.0.

Then I read the run: the suites jobs' seed step with `--yes`, published.sh's
`pull --yes`/`update --yes`, and the texlive group's time with parallel
downloads, against this run's 16m21s.

## Candidates for iteration 45

- **TeX Live collections as extension images** joining TeX Live's runs
  through kpathsea's `TEXMFAUXTREES` (an extension point would need a
  comma-separated join).
- **Ghostscript's build in parallel**, and its DLL for dvisvgm.
- **Parallel pushes**, for publishing an SDK and its runtime.
- From before: unity builds for qttools and qtbase, parallel make for Gnumeric.
