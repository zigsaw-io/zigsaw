# Iteration 27: GTK 3, and Gnumeric

Concluded 2026-10-16.

## Outcome

- **GTK 3.24.52, as an add-on to GTK 4's images.** GTK 4's SDK has the
  whole stack GTK 3 is built on (GLib, Pango, cairo, gdk-pixbuf, librsvg,
  libepoxy, HarfBuzz, gettext), so GTK 3's images carry only GTK 3 and ATK:
  [`org.gtk.Gtk3.Sdk`](../recipes/gtk3-sdk.json), built with GTK 4's SDK
  as its SDK, and the runtime [`org.gtk.Gtk3`](../recipes/gtk3.json), made
  from it. A GTK 3 app lists both runtimes and both SDKs; nothing of GTK 4's
  was rebuilt, and a GTK 3 app shares GTK 4's runtime, on disk, with every
  other GTK app.
- **GTK 3's demos** as an app on both runtimes,
  [`org.gtk.Gtk3demo`](../recipes/gtk3demo.json) (Flathub's id for it),
  with Start menu shortcuts: a runtime can't run on its own, as runtimes
  have no runtimes.
- **Gnumeric 1.12.62** ([`recipes/gnumeric.json`](../recipes/gnumeric.json)),
  with goffice 0.10.62, libgsf 1.14.60 and libxslt 1.1.45, built with
  autotools under BusyBox: a spreadsheet that reads and writes Excel,
  OpenDocument and a dozen other formats, with its charts, solvers and
  statistics tools; `ssconvert` and the other command-line tools; a shortcut, and
  Explorer offers it for `.gnumeric`, `.xlsx`, `.xls`, `.ods` and `.csv`. It
  works in all three sandboxes.
- **Strawberry Perl's XS modules load**: Perl's image left out the DLLs
  they need, so XML::Parser, which intltool needs, couldn't load.

## Starting decisions

From the planning session (plan file
`let-s-plan-iteration-27-robust-hamming.md`):

- **GTK 3 as an add-on over GTK 4's images** (your pick, over GTK 3 in GTK
  4's SDK and runtime as Flatpak's GNOME runtime has both, and over
  standalone GTK 3 images that would copy GTK 4's stack).
- **Gnumeric as the proof** (yours, over Geany and Xournal++).
- Mine: the demos as an app, goffice's settings in a key file (its Windows
  default is the registry), Gnumeric without its Python, Perl and database
  plugins and without its help, no zigsaw change.

## What was built

### GTK 3's images

- [`recipes/gtk3-sdk.json`](../recipes/gtk3-sdk.json): ATK, from
  at-spi2-core 2.60.7 with `-Datk_only=true`; GTK 3.24.52 for Windows only,
  its input methods built in, with its demos; the legacy Adwaita icons (GTK
  4's Adwaita 51 lists them as the theme it inherits, and GTK 3's widgets use
  their full-colour names); the `foo.lib` copies of its import libraries.
  Changes to GTK's build: its install no longer runs `gio-querymodules` on
  directories Windows builds don't have, `gdk-3.0.pc` links `-luuid` rather
  than `-Wl,-luuid` (which zig's `cc` refuses), its file chooser doesn't
  take a missing Desktop for one at the path NULL, its demos are GUI
  programs, and GTK's SDK's directory is mapped to a fixed name in
  `__FILE__`, so that the SDK's path in the store doesn't end up in GTK.
- [`recipes/gtk3.json`](../recipes/gtk3.json): the SDK's files without
  headers and libraries; `GSETTINGS_SCHEMA_DIR` names its own schemas, as
  GLib, in GTK 4's runtime, only finds those next to itself.
- [`recipes/gtk3demo.json`](../recipes/gtk3demo.json) and
  [`recipes/gtk3/png2ico.sh`](../recipes/gtk3/png2ico.sh), which makes the
  shortcuts' icons of GTK's PNGs, as `svg2ico.sh` does of SVGs.

### Gnumeric

The modules, in order: libxslt (with CMake), libgsf, intltool, goffice and
Gnumeric (with autotools). What it took, besides iteration 14's kit for
autotools under BusyBox ([findings](findings.md#gtk-3-and-gnumeric)):
`PATH_SEPARATOR=;` and `ac_executable_extensions=.exe` for configure,
[`recipes/gnumeric/pdpmake.sh`](../recipes/gnumeric/pdpmake.sh) for
BusyBox's make, [`recipes/gnumeric/export-all.h`](../recipes/gnumeric/export-all.h)
so that plugins export everything, as zig's linker would export only what
they mark, `PERLIO=perlio` for Perl scripts that read images,
`-Wl,--subsystem,windows` for zig's `cc`, which ignores `-mwindows`, and a
few lines of Gnumeric's own build changed for Windows.

### Perl

[`recipes/perl.json`](../recipes/perl.json) keeps the 40 DLLs of
Strawberry Perl's `c\bin` that its XS modules load (`*__.dll`, 29 MB),
beside `perl.exe`, and still leaves out the rest of `c` (its GCC).

### Tests

- [`tests/gtk3.sh`](../tests/gtk3.sh), a suite of its own rather than more
  of `tests/gtk.sh`, which builds Rnote and Pinta, with a GTK 3 app
  ([`tests/gtk/gtk3`](../tests/gtk/gtk3)) and a spreadsheet with two charts.
- The four images are in `scripts/published-recipes.txt`, and in CI's
  `SKIP_RECIPES` with GTK's; `tests/published.sh` checks that the demos keep
  running, as they have no `--version`. `.gitattributes` keeps the files
  GTK's SDK's and Gnumeric's recipes carry in LF, so that their digests
  don't depend on the checkout.

## Results

### Tests

- [`tests/gtk3.sh`](../tests/gtk3.sh): 27 of 27, in about 2 minutes with
  the images in the store. A GTK 3 app built against both SDKs draws its
  window, with GTK 3's schemas and the legacy icons, under `soft`, `low` and
  `appcontainer`; the demos run, the widget factory without a critical
  warning in any sandbox; `ssconvert` takes a spreadsheet with a formula from
  CSV to Excel to OpenDocument and back in each sandbox, and draws a line
  and a pie chart as PNGs; Gnumeric saves into the user's Documents at low
  integrity, opens a file given with `--file` in each sandbox, and is
  registered for its five kinds of file.
- By hand: Gnumeric's window, with an Excel file open, in English and, under
  `--sandbox=low`, in German; `ssconvert --export-graphs` draws the 77
  charts of Gnumeric's own `graph-tests.gnumeric`.
- Not run again: the other suites, as nothing they cover changed. No
  zigsaw code changed.

### Reproducibility

Built in `D:\zs\a`, then in a new store (GTK 4's images pulled from
ghcr.io), with the same digests:

| image | manifest | layer (compressed) | build |
|---|---|---|---|
| `org.perl.perl` 5.42.3.1 | `0a4e1bd6` | 51 MB | 59 s |
| `org.gtk.Gtk3.Sdk` 3.24.52 | `20a0c1d9` | 19 MB | 175 s |
| `org.gtk.Gtk3` 3.24.52 | `9871974c` | 18 MB | 4 s |
| `org.gtk.Gtk3demo` 3.24.52 | `d07fc09d` | 38 KB | 54 s |
| `org.gnome.Gnumeric` 1.12.62 | `863d8229` | 15 MB | 16-27 min |

The first build of GTK 3's SDK in the second store differed in one DLL,
which held the path of a header in GTK's SDK's deployment
([findings](findings.md#gtk-3-and-gnumeric)); the recipe now maps it.

## Decisions made along the way

- **Perl's image fixed and republished** rather than intltool given its own
  copy of Strawberry's expat: every XS module of Strawberry's that needs a
  DLL of its own was broken. GTK's SDK keeps the Perl it pinned; only
  Gnumeric pins the new one.
- **GTK 3 patched for a missing Desktop** rather than its demos given the
  Desktop permission: any GTK 3 app without it would have the warnings.
- **libspreadsheet exports everything** rather than upstream's list mended:
  the list misses functions in three ways, and one of them is the
  script's own pattern.
- **`PERLIO=perlio` for goffice's and Gnumeric's builds** rather than
  patching each script that reads a file without `binmode`.
- **The Applix plugin left out**; it can't link as released.
- **The demos' shortcut icons made of GTK's PNGs**
  ([`png2ico.sh`](../recipes/gtk3/png2ico.sh)): GTK 3's demos have no SVG.
- **GTK 3's suite of its own**, [`tests/gtk3.sh`](../tests/gtk3.sh), rather
  than a section of `tests/gtk.sh` as planned, as that one builds Rnote and
  Pinta when the store doesn't have them, and you'd rather wait less.

## Known gaps

See [gaps.md](gaps.md): two runtimes and two SDKs for a GTK 3 app; GTK 3
without introspection or broadway; Gnumeric without help, Python, Perl,
database plugins and Applix; libxml2's CMake files in GTK's SDK.

## For you

- Publish five images (`scripts/publish.sh` with their recipes, which
  pushes the catalog too): Perl again (its digest changed), and GTK 3's
  SDK, runtime and demos and Gnumeric, which are new: make those four
  packages public.
- Commit and push. zigsaw didn't change, so there's no release to tag.
- If you can open a window here, Gnumeric's File > Open dialog under
  `--sandbox=low` is the one thing I couldn't look at: the screen refused
  my keystrokes.

## Suggested for iteration 28

- More GTK 3 apps, now that it's there: Geany (C and C++, Meson), or
  Xournal++ (C++, CMake, with poppler).
- An `nm` in GTK's SDK (llvm-nm, or a small one like its `windres`), so
  libtool's export lists and `-export-symbols-regex` work as they do on
  Linux.
- A Zig project with dependencies from its own `zigsaw.json` (iteration
  26's suggestion), and extension points in GTK's runtime.
