# Iteration 29: GTK's extension point, and Gaphor

Concluded 2026-10-18.

## Outcome

- **GTK's runtime has an extension point**, `org.gtk.Gtk4`, on iteration
  24's extension points. The runtime sets `XDG_DATA_DIRS` to its own
  `share`, and the point joins it: an installed image that extends it adds
  its `share` to every run of an app on the runtime, after the runtime's.
  A run's data directories are then the runtime's, the extensions' and the
  app's, and no longer `C:\ProgramData` or the Public Documents folder.
  No SDK rebuild, no zigsaw change: the runtime's layer is the one before;
  only its config changed.
- **Two dictionaries extend it**, from LibreOffice's dictionaries at the
  commit GTK's SDK takes its en_US from:
  [Vietnamese](../recipes/gtk4-hunspell-vi.json)
  (`org.gtk.Gtk4.Hunspell.vi_VN`) and
  [French](../recipes/gtk4-hunspell-fr.json)
  (`org.gtk.Gtk4.Hunspell.fr_FR`, Grammalecte's, for every `fr_*`).
  Installed, enchant's hunspell provider has them in every GTK app on the
  runtime, in every sandbox; `--noextension` leaves one out. An icon theme
  would extend it the same way; a test extension with an icon shows GTK's
  icon theme finding it.
- **[Gaphor](../recipes/gaphor.json) 3.3.2**, a UML and SysML modeller in
  Python on GTK 4 and libadwaita, on GTK's runtime and PyGObject's, with
  no change to its code:
  - GtkSourceView 5.22 with its typelib;
  - Graphviz 16.1.0's `dot`, built from source with CMake and zig, for its
    auto layout;
  - its 15 packages from PyPI at the versions its lock file pins, through a
    **pip vendor step** (pinned by hash, as cargo's and Go's are), Pillow's
    being PyPI's own Windows wheel;
  - Gaphor itself from its source distribution, with its translations, its
    settings schema and its icon; a Start menu shortcut and `.gaphor` files.
  Its own self-test passes under `soft`, `low` and `appcontainer`.
- **PyGObject's runtime: Python's temporary directories in an
  AppContainer.** Since Python 3.13, `os.mkdir(path, 0o700)` gives a
  directory an ACL that leaves the container out, so it couldn't write in
  the directories `tempfile` makes (Gaphor's auto layout hung).
  [`sitecustomize.py`](../recipes/pygobject/sitecustomize.py) has such a
  directory take the ACL of where it's made, in an AppContainer only.
- **Text Editor and Meld move to the new runtimes** (Text Editor to the
  current SDK too), so a store with them and Gaphor has one of each
  runtime, and Text Editor gets the dictionaries.

## Starting decisions

From the planning session (plan:
`C:\Users\Test\.claude\plans\let-s-plan-iteration-29-snuggly-penguin.md`):

- Scope, your picks of four: **extension points in GTK's runtime** and **a
  Python app on GTK 4**. Not this time: rebuilding Rnote, Gnumeric and GTK
  3's demos on the new runtimes, `git` for Meld, a Zig project with
  dependencies.
- Your picks: **Gaphor 3.3.2** (over a tiny app), **Pillow as PyPI's
  prebuilt wheel** (over building it with zig, or leaving it out),
  **Graphviz's `dot` from source with CMake and zig** (over Graphviz's
  prebuilt zip, or no auto layout), and **Vietnamese and French**
  dictionaries, published; icon themes proven by a test fixture only.
- Mine: the point joins `XDG_DATA_DIRS` (the variable GLib, GTK, GSettings
  and enchant all read), at a version of its own, `1`, for the layout
  rather than GTK's version; the dictionaries named like PHP's extensions
  (point id, then theirs); Text Editor and Meld moved onto the new
  runtimes, as Gaphor needs the new one anyway; Gaphor run as `python -m
  gaphor`; probes before any of it.

## What was built

### GTK's runtime and GTK 3's

[`recipes/gtk4.json`](../recipes/gtk4.json) gets
`XDG_DATA_DIRS=${app}\share` and the point:

```json
"extensions": { "org.gtk.Gtk4": { "version": "1", "join": ["XDG_DATA_DIRS"] } }
```

A point's joined variables are joined in every layer, so GTK 3's runtime
([`recipes/gtk3.json`](../recipes/gtk3.json)) adds its `share` to them
with the same variable, and so do apps: Text Editor, Meld and Gaphor each
name their own `share`, which GLib used to find next to their DLLs.

### The dictionaries

Each is a `share\hunspell` with the dictionary and its licence, an
`about.bat` as its command, and:

```json
"env": { "XDG_DATA_DIRS": "${app}\\share" },
"extends": { "point": "org.gtk.Gtk4", "version": "1" }
```

### Gaphor

[`recipes/gaphor.json`](../recipes/gaphor.json), with
[`requirements.txt`](../recipes/gaphor/requirements.txt) (versions and
hashes from Gaphor's `poetry.lock`) and
[`build-requirements.txt`](../recipes/gaphor/build-requirements.txt)
(poetry-core, its build backend). It lists GTK's runtime and PyGObject's,
and builds with GTK's, PyGObject's and CMake's SDKs:

- GtkSourceView 5.22, with `-Dintrospection=enabled`;
- Graphviz from GitLab's zip of the 16.1.0 tag (the release tarball has
  no CMake files, the tag's tarball a dangling link), static, every
  optional library off; flex and bison from winflexbison, as in GTK's SDK;
- the vendor step, `pip download` of the 16 wheels; then `pip install` of
  them into the image, poetry-core beside the build only, and Gaphor from
  its sdist with `--no-build-isolation`;
- its schema compiled into `share\glib-2.0\schemas`, its icon made from its
  SVG with `svg2ico.sh`.

Its env names its own directories and its runtimes' as Meld's does, plus
`GSETTINGS_SCHEMA_DIR`, as Gaphor looks for its schema in the first
source only. Its command is `${pygobject}\pythonw.exe -m gaphor`.

### Tests and the rest

- [`tests/gtk.sh`](../tests/gtk.sh): after enchant's checks, the
  dictionaries, built unless the store has them, join the test app's runs
  in each sandbox, with the runtime's English still there;
  `--noextension` leaves French out; a test extension
  ([`tests/gtk/icons.json.in`](../tests/gtk/icons.json.in)) adds an icon
  GTK's icon theme finds ([`tests/gtk/icon.c`](../tests/gtk/icon.c)) in
  each sandbox, and once it's removed, doesn't. After Text Editor's,
  Gaphor's section: its version without the "schema not found" warning,
  its self-test in each sandbox, the windowless shim, its shortcut's icon,
  `.gaphor` files, and its window staying up.
- The three new recipes are in `scripts/published-recipes.txt` and CI's
  `SKIP_RECIPES`, with GTK's.
- [recipes](recipes.md#gtks-data-directories-and-extensions),
  [Python apps](recipes.md#packages-from-pypi),
  [Gaphor](recipes.md#gaphor), [findings](findings.md#gtks-extension-point-and-gaphor)
  and [gaps](gaps.md).

## Results

### Tests

- [`tests/gtk.sh`](../tests/gtk.sh): 100 of 100 in 488 s on the final
  images, 16 of them new (and before the `RECORD` change below, too).
  The first run failed one check, the SDK's Meson building the test
  project without a recipe, as its copy of the project lacked the new
  `icon.c`.
- [`tests/gtk3.sh`](../tests/gtk3.sh): 39 of 39 in 145 s, Meld on its new
  pins included.
- Probes (in `D:\zs\i29`): GLib's data directories with and without
  `XDG_DATA_DIRS`; Gaphor's self-test before and after the
  `sitecustomize.py` change, under each sandbox; `tempfile` under each.
- Not run again: the other suites. No zigsaw code changed, and no image
  outside GTK's runtimes, PyGObject's and the apps on them.

### Reproducibility

Built in `D:\zs\a`, then in a new store (GTK's and GTK 3's SDKs, CMake and
BusyBox pulled from ghcr.io; downloads seeded, but not Gaphor's wheels,
which pip downloaded again to the same hash), with the same digests:

| image | manifest | layer (compressed) | build (new store) |
|---|---|---|---|
| `org.gtk.Gtk4` 4.24.1 | `9a18362a` | 54 MB, the one before | 84 s |
| `org.gtk.Gtk3` 3.24.52 | `76beb83c` | 19 MB, the one before | 12 s |
| `org.gnome.PyGObject.Sdk` 3.58.1 | `3498644a` | 16 MB | 61 s |
| `org.gnome.PyGObject` 3.58.1 | `b4ecf47b` | 15 MB | 3 s |
| `org.gtk.Gtk4.Hunspell.vi_VN` 1.0.45 | `35e3a6b4` | 18 KB | 2 s |
| `org.gtk.Gtk4.Hunspell.fr_FR` 7.0 | `cb7429b3` | 346 KB | 1 s |
| `org.gnome.TextEditor` 51.0 | `9b944fc2` | 2.2 MB | 188 s |
| `org.gnome.Meld` 3.24.1 | `ce80f15b` | 2.2 MB | 47 s |
| `org.gaphor.Gaphor` 3.3.2 | `10c8f323` | 22 MB | 146 s |

Gaphor didn't reproduce at first: pip makes launchers for a package's
commands, which name the Python they were made with by its path (the SDK's
deployment, different in each store). The recipe removed them, but each
package's `RECORD` still listed their hashes. The build now takes those
lines out of `RECORD` too.

## Decisions made along the way

- **`GSETTINGS_SCHEMA_DIR` for Gaphor**: its settings weren't saved with
  its `share` only joined in `XDG_DATA_DIRS`, as it asks the first schema
  source alone.
- **Python's 0o700 directories fixed in PyGObject's runtime** (my call, as
  multiprocessing's pipes were in iteration 28), rather than a known gap
  for Gaphor's auto layout under AppContainer: every Python app's
  `tempfile` directories work there now. It costs PyGObject's SDK and
  runtime a rebuild (35 s and 3 s) and a republish; Python's own image
  (`org.python.python`) has the same gap and is left for now.
- **Graphviz from GitLab's zip of the tag**, not its tarball: the tarball
  has a link to a file it doesn't have, which zigsaw refuses, and the zip's
  links come through as small files. Both downloads were the same bytes
  twice.
- **dulwich's pure-Python wheel**, not its Rust one, so that only Pillow is
  a binary from PyPI.
- **pip's launchers out of the image and out of `RECORD`**: the app runs as
  `python -m gaphor`, and nothing reads those lines but `pip uninstall`.
- By hand: Gaphor's window with a SysML model open, in English. Opening a
  file, libadwaita logs `Trying to close AdwDialog ... that's not presented`
  (Gaphor's greeter, closed before it's shown); the window is fine.

## Known gaps

See [gaps.md](gaps.md): the extension point adds data only, after the
runtime's; an app on the runtime names its own `share`; Rnote, Gnumeric
and GTK 3's demos still on the old runtimes, where the dictionaries don't
reach them; Python's own image and `tempfile` in an AppContainer; Pillow
from PyPI, built with MSVC; Graphviz as `dot` alone; links in zip sources.

## For you

- Publish nine images (`scripts/publish.sh` with their recipes, which
  pushes the catalog too): GTK's runtime and GTK 3's (new configs, the same
  layers), PyGObject's SDK and runtime, Text Editor and Meld again (their
  digests changed, their versions didn't), and the two dictionaries and
  Gaphor, which are new: make those three packages public.
- Commit and push. zigsaw didn't change, so there's no release to tag.

## Suggested for iteration 30

- Rebuild Rnote, Gnumeric and GTK 3's demos on the new runtimes, so a store
  needs one of each and the dictionaries reach them.
- The same `tempfile` fix in Python's own image.
- More of the point: an icon theme, or more dictionaries, as extensions.
- `git` for Meld's version control views: MinGit as a runtime an app can
  list.
- The Zig project with dependencies from iteration 26's list.
