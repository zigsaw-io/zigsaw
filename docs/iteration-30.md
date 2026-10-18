# Iteration 30: one build of each runtime, and git for Meld

Concluded 2026-10-19.

## Outcome

- **Every published app is on the same build of each runtime.** Rnote,
  Gnumeric and GTK 3's demos (and Pinta, which isn't published) are rebuilt
  on GTK's current SDK and runtimes, which Text Editor, Meld and Gaphor
  moved to in iteration 29. A store with all of them deploys one GTK
  runtime and one GTK 3 runtime, not two of each, and GTK's extension point
  reaches them all.
- **A check that the registry has what the recipes pin**:
  [`scripts/check-pins.sh`](../scripts/check-pins.sh) looks up every image a
  published recipe pins (runtimes, SDKs, image sources) and each recipe's
  own version on the registry. It fails if one is missing, and warns about a
  runtime pinned at an older build than its tag. It runs in a job of its own
  in the Reproduce workflow, and at the end of `scripts/publish.sh`. Its
  first run found what it was written for: iteration 29's PyGObject SDK had
  never been published, so Gaphor, Meld and PyGObject's runtime couldn't be
  built in a fresh store.
- **Python's own image works in an AppContainer**: `org.python.python`
  turns on `site` in its `._pth` and has PyGObject's
  [`sitecustomize.py`](../recipes/pygobject/sitecustomize.py), so `tempfile`
  and multiprocessing work in every sandbox. That found a bug in the file:
  in a zipped standard library, its pipe fix broke multiprocessing
  everywhere. It's fixed for both images.
- **Meld's version control views work**: MinGit's published image is one of
  Meld's runtimes, unchanged, so `git` is on Meld's PATH, and a folder in a
  git repository shows its changes, in every sandbox.

## Starting decisions

From the planning session (plan:
`C:\Users\Test\.claude\plans\let-s-plan-iteration-30-tidy-otter.md`):

- Scope, your picks of four: **finish the runtime move** (with the
  `tempfile` fix in Python's image) and **git for Meld**. Not this time: ZLS
  with a vendor step for zig's packages, incremental project builds.
- Mine, in regardless: the pin check, as iteration 29's PyGObject SDK was
  missing on ghcr.io (still iteration 28's `576aa452`).
- Mine: MinGit's image as it is (a runtime's `path` and `env` join a run's
  already); apps on the runtimes name their own `share` in
  `XDG_DATA_DIRS`, as Text Editor did; `site` turned on in Python's `._pth`
  if the probe showed nothing else changing; probes first.

## What was built

### The pin check

`scripts/check-pins.sh [recipe.json...]` (default: the published recipes)
reads the registry anonymously (the default one, or `ZIGSAW_REGISTRY`'s,
over HTTP for localhost as zigsaw does). For each recipe, it looks up:

- the recipe's own `<id>:<version>` tag;
- every `<id>:<version>@sha256:<digest>` it names: by its tag first, and by
  digest when the tag points elsewhere.

A missing tag or digest fails it. A pin in the recipe's `runtimes` that
isn't what its tag points to now is a warning; an older SDK isn't, as
it costs nothing at run time (GTK's SDK builds with older Perl and cargo-c
images, PHP's extensions with an older PHP SDK). It looks the tags up
eight at a time: about 50 s here for 48 recipes and 85 pins.

In the [Reproduce workflow](../.github/workflows/reproduce.yml) it's a
third job, `pins`, on Linux, so a missing image fails the run without
skipping the builds. `scripts/publish.sh` runs it last, after pushing.

### The runtime move

[Rnote](../recipes/rnote.json), [Gnumeric](../recipes/gnumeric.json),
[GTK 3's demos](../recipes/gtk3demo.json) and
[Pinta](../recipes/no-publish/pinta.json) pin GTK's SDK `eed28b79` and
runtime `9a18362a`, and GTK 3's SDK `923dc692` and runtime `76beb83c`, the
ones Text Editor and Meld have. Rnote, Gnumeric and Pinta add
`XDG_DATA_DIRS=${app}\share`, which the runtime's extension point joins: the
runtime sets the variable, and GLib otherwise found their `share` next to
their DLLs.

### Python's image

[`recipes/python.json`](../recipes/python.json) gets a second module, with
no build commands, that places PyGObject's `sitecustomize.py` and
[`python/python314._pth`](../recipes/python/python314._pth) (the zip's,
with `import site`) over the zip's files. The image is still made without
a build root.

`sitecustomize.py` wrapped `multiprocessing.connection`'s loader's
`exec_module` in place. In python.org's embeddable distribution the
standard library is `python314.zip`, whose one `zipimporter` loads every
module, so every module loaded after it ran the wrapper and
`multiprocessing.util` failed: multiprocessing broke under soft too. The
file now gives that module a loader of its own, which wraps the real one.
That changes PyGObject's SDK and runtime, and with them Meld's and Gaphor's
images.

### Meld's git

[`recipes/meld.json`](../recipes/meld.json) lists
`"git": "org.git_scm.MinGit:2.56.0.windows.1@sha256:636d59bc..."` with its
runtimes. MinGit's `cmd` is then on Meld's PATH, with its
`GIT_DISCOVERY_ACROSS_FILESYSTEM`, which git needs in an AppContainer. Meld
already starts git with a hidden window, so nothing of Meld's changes.

### Tests

- [`tests/gtk3.sh`](../tests/gtk3.sh): git in a run of Meld makes a
  repository; Meld's git support finds it and its changed and new files
  under soft, low and appcontainer; Meld draws the repository's changes;
  and last, every published app in the store is on the installed build of
  each GTK runtime.
- [`tests/matrix.sh`](../tests/matrix.sh): Python writes in a `tempfile`
  directory and passes a value through a multiprocessing Queue, in each
  sandbox.

## Results

### Tests

- [`tests/gtk3.sh`](../tests/gtk3.sh): 45 of 45 in 158 s, 7 of them new.
  The one-build row was checked both ways: the store's apps all have GTK's
  runtime layer; iteration 16's Rnote image, still in the store's blobs,
  doesn't.
- [`tests/gtk.sh`](../tests/gtk.sh): 100 of 100 in 554 s, Rnote's rows
  and Pinta's (built with .NET's images, then removed) included.
- [`tests/matrix.sh`](../tests/matrix.sh): all as intended. The two new
  Python rows pass in every sandbox, and failed under appcontainer on the
  old image: the matrix store had it until Python was built there again,
  as the matrix builds only what a store lacks.
- `scripts/check-pins.sh`: against ghcr.io before this iteration's
  changes, 3 missing (iteration 29's PyGObject SDK, in three recipes) and
  the five old runtime pins this iteration removes; with the recipes as
  they are now, 5 missing (the new PyGObject SDK and runtime, until they're
  published) and none older. Against the empty registries of
  [`tests/zot.sh`](../tests/zot.sh), over HTTP, with no login and with
  one, everything missing, as it should be.
- Probes (in `D:\zs\i30`): Python's image in each sandbox before and after
  (`tempfile`, a multiprocessing Queue, `sys.path`); Meld's git support on
  a repository made with MinGit's image.
- Not run again: the other suites. No zigsaw code changed, and no image
  outside these.

### Reproducibility

Built in `D:\zs\a`, then in a new store (GTK's and GTK 3's SDKs and
runtimes, Rust, CMake, Perl, MinGit and BusyBox pulled from ghcr.io;
downloads seeded, but not Gaphor's wheels, which pip downloaded again to
the same hash), with the same digests. Python's image was also the same in
the matrix store, on C:.

| image | manifest | own layer (compressed) | build (new store) |
|---|---|---|---|
| `org.python.python` 3.14.7 | `fa12bbaf` | 12 MB | 1 s |
| `org.gnome.PyGObject.Sdk` 3.58.1 | `13dac3b2` | 16 MB | 121 s |
| `org.gnome.PyGObject` 3.58.1 | `68e29e6a` | 15 MB | 4 s |
| `org.gnome.Meld` 3.24.1 | `1324d175` | 2.2 MB | 84 s |
| `org.gaphor.Gaphor` 3.3.2 | `aeb0b57d` | 22 MB | 294 s |
| `org.gtk.Gtk3demo` 3.24.52 | `69b9367a` | 38 KB, the one before | 7 s |
| `org.gnome.Gnumeric` 1.12.62 | `21c7fbb2` | 15 MB, the one before | 1575 s |
| `com.github.flxzt.rnote` 0.14.2 | `15f484cc` | 18 MB | 1207 s |

Gnumeric's and the demos' own layers came out byte for byte as before, so
only their configs and runtime layers are new: republishing them pushes
almost nothing. Rnote's changed, as it's compiled against the newer SDK.
Pinta, built on the new runtime by `tests/gtk.sh`, isn't published.

## Decisions made along the way

- **The `sitecustomize.py` fix in the shared file** (my call), not a copy
  for Python's image: the two can't drift, and PyGObject's SDK had to be
  published anyway, so publishing the fixed one instead costs only
  Gaphor's republish.
- **The pin check as a job of its own**, on Linux: as the first step of the
  build job, a missing image would have skipped everything after it.
- **Only runtime pins warn**: the first run warned about deliberate older
  SDK pins too (GTK's SDK's Perl and cargo-c, PHP's extensions' SDK).
- **Tags looked up in parallel**: one at a time, the check took about
  110 s, as a request to ghcr.io takes about a second here, most of it TLS.
- **A registry that wants a password counts as not having the image**: an
  anonymous check can't see it, and only a token challenge (Bearer) can be
  answered without one.

## Known gaps

See [gaps.md](gaps.md): a new build of a runtime reaches an app only once
the app is republished on it; the check reads the registry anonymously, so
a package not yet public looks missing; Python's AppContainer fixes need
`site` (`-S` goes without); Meld's git has Meld's permissions, no network.

## For you

- Publish the images (`scripts/publish.sh` with their recipes, in this
  order; it pushes the catalog and runs the pin check last):
  `pygobject-sdk.json`, `pygobject.json`, `python.json`, `meld.json`,
  `gaphor.json`, `gtk3demo.json`, `gnumeric.json`, `rnote.json`.
- Commit and push. zigsaw didn't change, so there's no release to tag. The
  Reproduce run's `pins` job should then be green, with no warnings.

## Suggested for iteration 31

- ZLS from source, with a vendor step for zig's package manager.
- Incremental builds of a project's `zigsaw.json`.
- An icon theme as an extension of GTK's runtime.
