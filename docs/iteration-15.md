# Iteration 15: Rnote, and translations for GTK

Concluded 2026-10-11.

## Outcome

- **Rnote 0.14.2**, a drawing and note-taking app in Rust on GTK and
  libadwaita, is built from source (`com.github.flxzt.rnote`). It runs in
  all three sandboxes, has a Start menu shortcut with its own icon, and its
  `rnote-cli` converts documents without a window: a Xournal++ file into
  Rnote's format, and that into PDF, SVG or images.
- **GTK speaks your language.** GTK's SDK and runtime have GNU gettext 1.0's
  libintl, so GLib, GTK, libadwaita, GdkPixbuf, libsoup and glib-networking
  are translated (124 languages), and so are Text Editor and Rnote. Apps
  follow Windows' display language, or `LANGUAGE`.
- **GNU gettext and libiconv** are an image of their own,
  `org.gnu.gettext`: their build takes three quarters of an hour, which
  GTK's SDK takes as an image source instead of repeating. The SDK exports
  `msgfmt`, `msgmerge` and `xgettext`.
- **GTK's SDK has a `windres`**, which Rust's winresource and embed-resource
  crates, and libtool, run to compile Windows resources: GNU windres's
  command line for zig's `rc`.
- **cairo 1.18.6**, whose DirectWrite backend is now safe to draw text from
  several threads, as Rnote does. Rnote's own Windows build pins an older
  cairo built without DirectWrite to avoid the crash.
- **Color emoji.** Pango's Windows font map found no font at all for text
  that asks for color glyphs (an emoji followed by U+FE0F, and every emoji
  in GTK's emoji chooser); a one-line patch in the SDK's Pango fixes it.

No zigsaw code changed: everything is in recipes, their helper scripts and
tests.

## Starting decisions

From the planning session (plan file `let-s-plan-v15-cheerful-thompson.md`):

- Scope, the user's words: "whatever Rnote needs, then Rnote itself".
  Rnote 0.14.2, from its release tarball, which vendors its crates (so no
  vendor step). It no longer needs poppler (hayro, a PDF library in Rust,
  replaced it), and ink-stroke-modeler is Rust now too.
- What it needed, found by reading its build: GNU libintl (gettext-rs) and
  msgfmt (Meson's i18n), a `windres`, cairo with DirectWrite safe for
  threads, and patches for what assumes MSYS2 or Linux.
- Translations: the user chose **full gettext** (libintl and its tools, and
  GLib, GTK and libadwaita built with translations) over libintl alone.
- Rnote's fonts, which it finds with fontconfig on Linux: the user chose
  **a patch that adds them to Pango** over leaving them out.

Planning also confirmed that iteration 14's images were republished
(GTK's SDK `1ea0edab`, runtime `5299a617`, Text Editor `94f4b773`) and its
Reproduce run green (44 minutes).

Decided along the way, with the user: **gettext in an image of its own**
(55 minutes to build would have tripled every SDK build).

## What was built

**gettext and libiconv** ([`recipes/gettext.json`](../recipes/gettext.json)),
with BusyBox's autotools, as iteration 14 built hunspell and enchant, and
these on top:

- gnulib looks for grep as `EGREP_TRADITIONAL` as well.
- libtool runs `$RC` and `$WINDRES` with GNU windres's command line, which
  [a script](../recipes/gtk4-sdk/autotools-windres.sh) turns into zig
  `rc`'s, unescaping the `-D` values windres would hand to a shell.
- Their export macros: configure finds that clang takes a `visibility`
  attribute, which GCC for MinGW doesn't, so their headers export with it,
  which Windows doesn't heed; libintl exported one symbol.
  `gl_cv_cc_visibility=no` gives them `dllexport`. Some functions are
  `dllexport` only for MSVC and rely otherwise on GNU ld's
  `--export-all-symbols`, which zig's linker ignores, or on a `.def` libtool
  makes with `nm`, which there isn't: [a script](../recipes/gettext/exports.sh)
  exports libintl's plain names (`gettext`, `textdomain` and the rest, which
  Rust's gettext-sys calls) and lets libgettextlib and libgettextsrc export
  everything; libiconv's headers get the same `_WIN32` for `_MSC_VER`.
- gettext's libtool keeps `-nostdlib` in a variable, `stdlibflag`.
- BusyBox's make remakes the translations, manuals and man pages the
  release ships built (it remakes a target as old as its prerequisite):
  [the mtimes script](../recipes/gtk4-sdk/autotools-mtimes.sh) orders them
  too, and `make` runs with `MAKEINFO=true HELP2MAN=true`.
- A shared configure cache (`-C`) took 11 minutes off the build.

**GTK's SDK** ([`recipes/gtk4-sdk.json`](../recipes/gtk4-sdk.json)):

- gettext's image as an image source, before GLib; GLib with `-Dnls=enabled`
  and without proxy-libintl. GLib's `gi18n.h` includes `libintl.h`, so
  everything built with GLib needs it next to GLib's headers, which is why
  gettext's files are in the SDK rather than in a runtime of it.
- cairo 1.18.4 → 1.18.6.
- [`windres.c`](../recipes/gtk4-sdk/windres.c), built into the SDK's `bin`,
  and exported. Aliases can only run what's in their own image, so it isn't
  an alias of zig's `rc`; it finds zig on PATH, where builds and runs of the
  SDK have it. Meson keeps using `rc`, which the SDK's `RC` names.
- Pango: its Windows font map gives each face the requested color
  preference before comparing, as it already does with gravity.
- Exports `msgfmt`, `msgmerge`, `xgettext`, `windres`.

**GTK's runtime** ([`recipes/gtk4.json`](../recipes/gtk4.json)) keeps
libintl, libiconv and the translations, without gettext's tools, data or own
translations, and without `windres`.

**Rnote** ([`recipes/rnote.json`](../recipes/rnote.json),
[`recipes/rnote/`](../recipes/rnote)):

- [`cargo_build.py`](../recipes/rnote/cargo_build.py) replaces Rnote's,
  which runs `env` and `cp` through cmd.exe; Meson's `cat` and `cp` become
  `fs.read` and Python; the post-install `fc-cache.exe` and the desktop and
  MIME database updates go. `project()` names no languages: Rnote's Meson
  compiles nothing itself, and with zig as `CC` it would have rustc link its
  sanity check with zig. The `cmake` and `appstream` requirements are
  stale.
- [`data-dirs.patch`](../recipes/rnote/data-dirs.patch): Rnote set
  `XDG_DATA_DIRS` and GdkPixbuf's loader directory to the directories next
  to its executable, which hid GTK's icons, schemas and SVG loader in the
  runtime.
- [`fonts.rs`](../recipes/rnote/fonts.rs) and
  [`fonts.patch`](../recipes/rnote/fonts.patch): Rnote's fonts added to
  Pango on the main thread and on rayon's, since pangocairo's default font
  map, which piet-cairo lays out text with, is per thread.
- gettext-sys looks for libintl in `MINGW_PREFIX`, and in
  `C:\msys64\mingw64` when that's unset, which is this machine's MSYS2: the
  recipe sets it to the SDK's directory.

**Tests** ([`tests/gtk.sh`](../tests/gtk.sh), 55 checks, 158 s on a store
with the images): German from the runtime with `LANGUAGE=de`; Pango finds a
color font for emoji; the SDK's `msgfmt` and `windres` work; Rnote binds all
its imports, gets its shim, shortcut and translations; `rnote-cli` turns a
Xournal++ document ([generated](../tests/gtk/notes-xopp.sh)) into a PDF with
Virgil and Segoe UI in it, in each sandbox; 40 pages exported to PNG three
times over, on rayon's threads; Rnote's window stays up in each sandbox.

CI: gettext and Rnote join GTK's images in `SKIP_RECIPES`.

### Code map

| File | Change |
|---|---|
| `recipes/gettext.json`, `recipes/gettext/exports.sh` (new) | GNU gettext 1.0 and libiconv 1.19 |
| `recipes/gtk4-sdk/autotools-windres.sh` (new), `autotools-mtimes.sh` | windres for libtool; generated docs and translations |
| `recipes/gtk4-sdk/windres.c` (new) | the SDK's `windres` |
| `recipes/gtk4-sdk.json` | gettext, GLib with translations, cairo 1.18.6, Pango patch, windres, exports |
| `recipes/gtk4.json`, `recipes/gnome-text-editor.json` | pins; runtime cleanup |
| `recipes/rnote.json`, `recipes/rnote/*` (new) | Rnote and its patches |
| `tests/gtk.sh`, `tests/gtk/notes-xopp.sh` (new) | translations, emoji, msgfmt, windres, Rnote |
| `scripts/published-recipes.txt`, `.github/workflows/reproduce.yml` | gettext and Rnote; skipped in CI |
| `README.md` | published apps, GTK (translations, emoji, gettext, windres), Rnote, known gaps |

## Results

### Tests

- `tests/gtk.sh`: 55 checks pass (20 new).
- Rnote's `rnote.exe` binds all its 1,051 imports, `rnote-cli.exe` its 358.
- Rnote in German (`LANGUAGE=de`): its window is titled "Neues Dokument".
  A screenshot showed the window drawn with its icons.
- No zigsaw code changed, so the unit tests and the zigsaw suites
  (`build.sh`, `sandbox.sh`, `matrix.sh`) weren't run again, and the other
  images' digests can't have changed.
- Reproducibility: gettext `f3f85ba5`, GTK's SDK `f712124c`, runtime
  `e6cfbe23`, Text Editor `c258e30d` and Rnote `b1c217fd`, built in
  `D:\zs\a` and `D:\zs\b`, are the same.

### Measurements

| | |
|---|---|
| `org.gnu.gettext` build | 46 min (57 without the configure cache); 31 MB, 7.8 MB gzip |
| GTK SDK build, warm store | 26 min (iteration 14: 26.5) |
| `org.gtk.Gtk4.Sdk`'s own layer | 217 MB, 73.4 MB gzip (was 163 MB, 57.8 MB) |
| `org.gtk.Gtk4` | 122 MB, 52.4 MB gzip (was 97 MB, 43.7 MB): 28 MB of translations |
| Text Editor | 2.2 MB gzip, with translations in 93 languages |
| Rnote build | 19 min (fat LTO); 37 MB, 18.0 MB gzip |
| Rnote's `export doc-pages` of 40 pages of text | about 1 s |

## Decisions made along the way

- **gettext in an image of its own**, taken by GTK's SDK as an image source
  (the user's choice for an image of its own; image source rather than a
  runtime of the SDK because GLib's headers need `libintl.h` beside them).
- **`windres` as a program in GTK's SDK**, not an alias: aliases run only
  what's in their own image, and zig is a runtime of the SDK; the program
  finds zig on PATH. Allowing aliases to name a runtime would be a zigsaw
  change.
- **Patching Pango** for color fonts, as the bug hides every emoji in GTK's
  emoji chooser, which Rnote shows; it took one more SDK build.
- Rnote's release profile kept (fat LTO, 19 minutes).

## Bugs found

- Pango 1.58.2 on Windows: a font description asking for color glyphs
  matches no font. Patched; report drafted.
- gettext 1.0 and libiconv 1.19 with clang for MinGW: DLLs that export
  almost nothing (visibility attributes, MSVC-only `dllexport`). Worked
  around; report drafted.
- Rnote 0.14.2 outside MSYS2: data directories, fonts, build scripts.
  Patched; report drafted.

## Findings

- zig's linker ignores `--export-all-symbols`; a DLL exports what's
  `dllexport`, or everything when nothing is.
- Meson for clang with a GNU-style linker looks for `windres`, unless `RC`
  or `WINDRES` names a resource compiler; it gives rustc `-C linker=$CC`
  for its sanity check whenever `rust` is a project language.
- zig's `rc` writes COFF when the output's name ends in `.o`.
- winresource 0.1.31 passes `--target pe-x86-64`, which a windres has to
  take.
- `rnote-cli import` wants the `.rnote` file to exist (`create` first).
- Virgil's family is "Virgil 3 YOFF", on Linux too.
- An executable whose version resource zig's `rc` compiled from a script
  without winresource's fields shows its fixed version in Windows'
  properties but not its strings; Rnote's shows both.

## Known gaps

- `LANGUAGE` reaches an app only through `--env` or an override, as runs
  don't take the user's variables; without it, apps follow Windows' display
  language (which libintl reads, not tested on a non-English Windows).
- Rnote under `--sandbox=appcontainer`: DirectWrite warns about fonts
  installed for the user only (as GTK's other apps do).
- GTK's images, gettext and Rnote aren't checked in CI.
- The gaps of earlier iterations otherwise remain (README's known gaps).

## Suggested for iteration 16

- The user publishes `org.gnu.gettext` and Rnote (new), and republishes
  GTK's SDK, runtime and Text Editor.
- File the drafted reports (Pango, gettext/libiconv, Rnote, and iteration
  14's busybox-w32).
- GTK back in CI, perhaps as its own job; file associations (`.rnote`,
  `.xopp`); more hunspell dictionaries.
