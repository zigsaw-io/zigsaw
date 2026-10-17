# Iteration 28: an nm, introspection, and Meld

Concluded 2026-10-17.

## Outcome

- **An `nm` in GTK's SDK** ([`recipes/gtk4-sdk/nm.c`](../recipes/gtk4-sdk/nm.c)),
  as zig has none: it lists the symbols of COFF objects, static libraries
  and import libraries as GNU nm does (the same output in 60 of 60
  comparisons). libtool's export lists work with it, so enchant exports
  what upstream's `-export-symbols-regex` says rather than a list the recipe
  made, and gobject-introspection reads with it which DLL an import library
  names. The SDK exports it.
- **Introspection in GTK's images.** GTK's SDK builds gobject-introspection
  1.86 with zig, and every library with its GIR file and typelib: GLib,
  GObject, Gio, HarfBuzz, Pango, cairo, GdkPixbuf, Graphene, GDK, GSK, GTK
  4, libadwaita, libsoup and librsvg; GTK 3's SDK adds ATK, GDK 3 and GTK 3.
  The runtimes keep the typelibs. The SDK exports `g-ir-scanner` and
  `g-ir-compiler`.
- **PyGObject, as an add-on to GTK's images**:
  [`org.gnome.PyGObject.Sdk`](../recipes/pygobject-sdk.json) and the runtime
  [`org.gnome.PyGObject`](../recipes/pygobject.json), with Python 3.14.7,
  pycairo 1.29.2 and PyGObject 3.58.1, built with zig against python.org's
  build of Python. A Python app loads GTK 3 or GTK 4 through the typelibs;
  multiprocessing works in all three sandboxes.
- **Meld 3.24.1** ([`recipes/meld.json`](../recipes/meld.json)), with
  GtkSourceView 4.8.4: it compares files and folders under `soft`, `low` and
  `appcontainer`, speaks German when asked, and is in the Start menu.

## Starting decisions

From the planning session (plan file
`let-s-plan-iteration-28-proud-quail.md`):

- **Another GTK 3 app, and an `nm` in GTK's SDK** (your picks of the
  four offered). The app is **Meld** (you named it), which is Python on
  PyGObject, so introspection became part of the iteration.
- **PyGObject as an add-on over GTK's images** (your pick, over Python and
  PyGObject in GTK's SDK and runtime, as Flatpak's GNOME runtime has them,
  which I'd recommended, and over Meld carrying its own).
- **Republish only what Meld needs** (your pick): GTK's SDK and runtime and
  GTK 3's; Text Editor, Rnote, GTK 3's demos and Gnumeric keep their pins.
- Mine: python.org's Python from its NuGet package (the embeddable zip's
  build, with headers and `python314.lib`), gobject-introspection 1.86.0,
  PyGObject 3.58.1, pycairo 1.29.2, GtkSourceView 4.8.4 in Meld's recipe,
  probes first, no zigsaw change.

## What was built

### GTK's SDK and runtime

[`recipes/gtk4-sdk.json`](../recipes/gtk4-sdk.json), in order of the new
modules:

- `nm`, from [`nm.c`](../recipes/gtk4-sdk/nm.c).
- `python`: NuGet's `python` 3.14.7 in `python\`, with setuptools 84.0.0
  (gobject-introspection's scanner uses its distutils).
- `flex-bison`: winflexbison 2.5.25's release, on PATH for the next
  module only.
- `gobject-introspection` 1.86.0 with
  [a patch](../recipes/gtk4-sdk/gobject-introspection.patch) for zig's `cc`
  and subst drives, and
  [`g-ir-scanner.exe`](../recipes/gtk4-sdk/python-script.c), which runs the
  scanner with the SDK's Python wherever the SDK is deployed.
- `glib-introspection`: GLib 2.90 again, with its GIRs, which need GI's
  scanner, which needs GLib.
- HarfBuzz after them, with its GObject library, and every library's
  `-Dintrospection=enabled`.
- enchant with libtool's `-export-symbols-regex` and `NM=nm`.

The SDK has a name and a summary now. [`recipes/gtk4.json`](../recipes/gtk4.json)
keeps the typelibs and GLib's `libgirepository-2.0`, and leaves out GI's
tools, the GIRs, Python and `nm`; it has a name and a summary too.

### GTK 3's

[`recipes/gtk3-sdk.json`](../recipes/gtk3-sdk.json) builds ATK and GTK 3
with introspection and sets `GI_GIR_PATH` to its GIRs for builds on it;
[`recipes/gtk3.json`](../recipes/gtk3.json) keeps the typelibs.

### PyGObject's

- [`recipes/pygobject-sdk.json`](../recipes/pygobject-sdk.json): Python
  3.14.7 at the image's top with a `python3.exe` and pkg-config files for
  Python, pycairo and PyGObject with Meson, and
  [`sitecustomize.py`](../recipes/pygobject/sitecustomize.py), which moves
  multiprocessing's pipes to `\\.\pipe\LOCAL\` when it's imported.
- [`recipes/pygobject.json`](../recipes/pygobject.json): the SDK's files
  without headers, `libs` and pkg-config files; bytecode in the app's data.

### Meld

[`recipes/meld.json`](../recipes/meld.json): GtkSourceView 4.8.4 with its
typelib, then Meld with Meson in its wheel form, its data inside its Python
package. Five changes to Meld's startup script and build
([recipes](recipes.md#meld)), `PANGOCAIRO_BACKEND=win32`, and the
variables a Python app sets ([recipes](recipes.md#python-apps)).

### Tests and the rest

- [`tests/gtk3.sh`](../tests/gtk3.sh) gets Meld's section: PyGObject loads
  GTK 3 and GtkSourceView in each sandbox, and GTK 4 and libadwaita; Meld
  compares two files in each sandbox and two folders, saving a picture of
  its window (its own CI hook, `MELD_SCREENSHOT_AND_EXIT`), with nothing in
  its log; the windowless shim and its shortcut. And the GTK 3 runtime's
  typelibs.
- The three new recipes are in `scripts/published-recipes.txt` and in
  CI's `SKIP_RECIPES` with GTK's; `.gitattributes` keeps
  `recipes/pygobject/` in LF.

## Results

### Tests

- [`tests/gtk3.sh`](../tests/gtk3.sh): 39 of 39 in 142 s with the images
  in the store, 12 of them new: GTK 3's runtime has its typelibs;
  PyGObject loads GTK 3, GtkSourceView 4 and Pango in each sandbox, and GTK
  4, libadwaita and pycairo; Meld compares two files under `soft`, `low`
  and `appcontainer` and two folders, with no traceback in its log, and
  gets the windowless shim and its shortcut.
- [`tests/gtk.sh`](../tests/gtk.sh): 84 of 84 on the new SDK and runtime
  (41 minutes: it rebuilt Rnote, which came out with its published digest,
  `df74c962`, on the old pins).
- By hand: Meld's window in English and, under `--sandbox=low`, in German;
  a comparison of two Python files; `nm` against MSYS2's GNU nm (60
  comparisons); enchant exports its 37 functions and 34 more of its own
  `enchant_` names, as upstream's regex says.
- Not run again: the other suites. No zigsaw code changed, and no image
  outside GTK's and PyGObject's.

### Reproducibility

Built in `D:\zs\a`, then in a new store (zig, Meson, BusyBox, CMake, Perl,
Rust, cargo-c and gettext pulled from ghcr.io), with the same digests:

| image | manifest | layer (compressed) | build |
|---|---|---|---|
| `org.gtk.Gtk4.Sdk` 4.24.1 | `eed28b79` | 94 MB | 31-40 min |
| `org.gtk.Gtk4` 4.24.1 | `33809ebd` | 54 MB | 22 s |
| `org.gtk.Gtk3.Sdk` 3.24.52 | `923dc692` | 21 MB | 201 s |
| `org.gtk.Gtk3` 3.24.52 | `19f68615` | 19 MB | 4 s |
| `org.gnome.PyGObject.Sdk` 3.58.1 | `576aa452` | 16 MB | 35 s |
| `org.gnome.PyGObject` 3.58.1 | `48e6eb75` | 15 MB | 3 s |
| `org.gnome.Meld` 3.24.1 | `6b0e8842` | 2.2 MB | 48 s |

## Decisions made along the way

- **gobject-introspection patched**, rather than built in an MSYS2-like
  environment (an `sh.exe`, `MSYSTEM`): four changes for a GCC-like
  compiler outside MSYS2, and one for subst drives. The last was found
  after the first SDK of this iteration was built: its GIRs had no enum
  types and lacked GTK's version functions, which only their contents
  showed ([findings](findings.md#introspection-pygobject-and-meld)).
  Upstream drafts are for you to file (below).
- **winflexbison's release** for GI's build, as its sources need MSVC
  (my call; it's a build tool on PATH for one module, as Strawberry Perl is
  for OpenSSL).
- **A program, not a `#!` line, runs `g-ir-scanner`** in builds on the SDK
  and from its export.
- **multiprocessing fixed in PyGObject's runtime**, not in Meld (my call):
  any Python app's Queue or Pool works in an AppContainer.
- **Python's pkg-config files in PyGObject's SDK**, rather than Meld's
  `dependency('python3')` taken out (my call): MSYS2's Python has them too.
- **Meld in Meson's wheel form**: its data is found from its Python
  package, which is what a relocated install needs.
- Not needed after all: `XDG_DATA_DIRS` for GtkSourceView, as GLib looks
  next to the DLL that asks.

## Known gaps

See [gaps.md](gaps.md): the older GTK apps still on the old runtimes; three
runtimes and SDKs for a Python app on GTK 3; no GJS or Vala; nothing from
PyPI but PyGObject and pycairo; Meld's version control views without
`git`; winflexbison's prebuilt programs in GI's build.

## For you

- Publish seven images (`scripts/publish.sh` with their recipes, which
  pushes the catalog too): GTK's SDK and runtime and GTK 3's again (their
  digests changed, their versions didn't), and PyGObject's SDK and runtime
  and Meld, which are new: make those three packages public.
- Commit and push. zigsaw didn't change, so there's no release to tag.
- File the upstream reports, if you'd like, from `D:\zs\i28\upstream\`:
  gobject-introspection's scanner on a subst drive
  (`gi-subst-drive.md`), its scanner with a GCC-like compiler outside MSYS2
  (`gi-non-msys2-compiler.md`), and Meld's Windows startup
  (`meld-windows.md`).

## Suggested for iteration 29

- Rebuild Text Editor, Rnote, GTK 3's demos and Gnumeric on the new GTK
  runtimes, so that a store needs one of each.
- A Python app on GTK 4 and libadwaita, on PyGObject's runtime as it is.
- `git` for Meld's version control views: MinGit as a runtime an app can
  list.
- Extension points in GTK's runtime (dictionaries, icon themes), or the
  Zig project with dependencies from iteration 26's list.
