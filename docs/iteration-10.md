# Iteration 10: GTK

Concluded 2026-10-05.

## Outcome

Iterations 1–9 were about command-line apps; GUI apps were "later". This
iteration asked what it takes to build GTK 4 with zigsaw's hermetic
toolchain (zig's C compiler, BusyBox, builds on `B:` without network), and
then built it. Zigsaw now:

- **builds GTK 4.24.1 from source**, with GLib 2.90, cairo, Pango,
  HarfBuzz and the rest of its stack, 18 modules, in 13–16 minutes,
  reproducibly: two stores build the same digests;
- **ships it as a Flatpak-style SDK and runtime**: `org.gtk.Gtk4.Sdk` with
  headers, import libraries and pkg-config files, and `org.gtk.Gtk4`, the
  runtime, made from the SDK's image in 4 seconds without building again;
- **runs GTK apps** built against the SDK on the runtime, in all three
  sandboxes, with GLib's files and settings kept in the app's data
  directory;
- **has a Meson SDK image**, `com.mesonbuild.meson` (Python's embeddable
  distribution, Meson 1.12.1, Ninja, pkgconf), which works with zig's
  compilers;
- **lets a module take another image's files** (`"image"` sources), which
  is how the runtime is made from the SDK;
- **finds what earlier modules installed** in builds: `B:\prefix\bin` is on
  PATH, and `PKG_CONFIG_PATH`/`CMAKE_PREFIX_PATH` name the prefix and
  library SDKs.

Getting there took a series of zig and Meson quirks, each worked around in
the recipes and written down below; three are drafted for reporting to zig.

## Starting decisions

From the planning session ("evaluate what we need to build GTK4"; plan file
`evaluate-what-we-need-splendid-sutherland.md`):

- Target GTK 4.24.1, the latest stable release, with its own pins for
  GLib (2.90.0) and most libraries.
- Scope: build GTK and run its demos. GUI polish (windowless shims, Start
  menu shortcuts) waits.
- Images: the user chose **a runtime and a separate SDK**, as Flatpak's
  GNOME runtime does, over one image that's app, runtime and SDK at once.
  To avoid building the stack twice, the runtime takes its files from the
  pinned SDK image (a new source type).
- Toolchain: a Meson SDK image, as CMake's bundles Ninja.
- Slices: probes → Meson image and build search paths → image sources →
  the GTK SDK and runtime → running them, tests, write-up.

## What was built

**Probes.** Meson from its source release runs under the embeddable Python
(its `meson.py` puts its own directory on `sys.path`). It takes zig as
Clang with zig's linker (`ld.zigcc`), makes import libraries with
`-Wl,--out-implib`, resolves data imports across DLLs (MinGW auto-import),
and compiles resources with zig's `rc`, whose help says it's "drop-in
compatible with the Microsoft Resource Compiler", which is what Meson looks
for. No Meson patch was needed for that, contrary to the plan. GTK carries
its own C-compatible `dcomp.h`, so the C++-only one in zig's MinGW headers
doesn't matter, and zig's MinGW links every import library GTK's Windows
backend uses.

**Meson image** ([`recipes/meson.json`](../recipes/meson.json)). Python
3.14.7 embeddable, Meson 1.12.1, Ninja 1.13.2, and pkgconf 3.0.7, which the
recipe builds with that Meson and zig. Builds get `meson`, `ninja`,
`pkg-config` and `pkgconf` as aliases; as an app it's `meson`. Three
details:

- pkgconf's "system" directories default to `B:/prefix/include` and
  `B:/prefix/lib`, which it drops from the flags it prints, so a later
  module wouldn't find an earlier one's headers. The recipe sets them to
  `/usr/include` and `/usr/lib`, which don't exist on Windows.
- Meson resolves the directories it's given with `realpath`, which turns
  `B:` back into the build's directory in the store. Most of what Meson
  compiles uses relative paths, but its unity builds include sources by
  absolute path, and GTK's SVG code is one, so its asserts' `__FILE__` named
  the store. The recipe changes the `realpath` calls in Meson's argument
  handling and setup with `sed`, and checks that the change applied.
- Running Meson from the prefix to build pkgconf leaves `__pycache__`,
  whose bytecode records when the sources were unpacked: left out.

**Build search paths** (`src/builder.zig`). Builds now put `B:\prefix\bin`
on PATH after the aliases, before the SDK, as Flatpak's builds have
`/app/bin` (gdk-pixbuf looks for GLib's `glib-compile-resources` on PATH).
`PKG_CONFIG_PATH` is the prefix's `lib\pkgconfig` and `share\pkgconfig`,
then those of each SDK or runtime image that has them, and
`CMAKE_PREFIX_PATH` is `B:\prefix` and those images' directories. zigsaw
sets these, rather than library SDKs' `env`, because image variables don't
join lists and would be in runs too.

**Image sources.** A source can be `{ "image": "<id>@sha256:...", "dest":
"..." }`: resolved like an SDK (the store, then its registry), kept like
one, and its deployed files indexed into the module's tree, streamed into
the layer like other sources without build commands. The config records the
digests under `build.images` (absent otherwise, so existing images keep
their digests).

**GTK's SDK** ([`recipes/gtk4-sdk.json`](../recipes/gtk4-sdk.json)), in
order: zlib 1.3.2, libpng 1.6.49, libjpeg-turbo 3.1.1 (without SIMD, which
needs NASM), libtiff 4.7.0, PCRE2 10.46 (all CMake); libffi 3.5.2 (with
wrapdb's Meson files), GLib 2.90.0 (with proxy-libintl in its
`subprojects`), pixman 0.46.4, FriBidi 1.0.16, HarfBuzz 14.4.0, cairo
1.18.4, Pango 1.58.2, graphene 1.10.8, libepoxy 1.5.10, gdk-pixbuf 2.43.3
(loaders built in), DirectX-Headers 1.611.0 and GTK 4.24.1 (Meson), without
GStreamer, Vulkan, introspection or AccessKit, with the demos. Versions are
GTK's and GLib's own wrap pins where those name releases; Pango (GTK pins
`main`) and graphene/libepoxy (pinned to commits) are their latest
releases, cairo the 1.18 bugfix release that builds with mingw-w64 ≥ 11.

**GTK's runtime** ([`recipes/gtk4.json`](../recipes/gtk4.json)): one module
whose source is the SDK image, and a cleanup of headers, libraries, build
tools and their scripts. Its variables put GLib's user directories
(`XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`)
in `${data}`, since GLib otherwise asks Windows for the user's AppData
folder with `SHGetKnownFolderPath`, past zigsaw's profile redirect, and
`GSETTINGS_BACKEND=keyfile`, since GLib's default on Windows is the
registry. As an app it runs `gtk4-widget-factory`, and exports the demos and
`gtk4-query-settings`.

### Code map

| File | Change |
|---|---|
| `src/recipe.zig` | `image` sources and their checks |
| `src/builder.zig` | image sources in `Sources.add`; `B:\prefix\bin` on PATH; `PKG_CONFIG_PATH` and `CMAKE_PREFIX_PATH` (`setSearchPaths`) |
| `src/Tree.zig` | `addDirFiles`, `fromDir` under a base directory |
| `src/deps.zig` | the `source` kind, and its pin hint (`"image": ...`) |
| `src/oci.zig` | `build.images` |
| `recipes/meson.json`, `recipes/gtk4-sdk.json`, `recipes/gtk4.json` | new |
| `tests/build.sh` | Meson fixture; image sources; search paths |
| `tests/build/meson/`, `tests/gtk/`, `tests/gtk.sh` | new |
| `.github/workflows/reproduce.yml` | `tests/gtk.sh` step; timeout 60 → 90 min |
| `scripts/published-recipes.txt` | meson, GTK SDK, GTK runtime |

## Results

### Tests

- `zig build test`: passes (new recipe checks for image sources). `tests/published.sh` wasn't run locally: CI compares every recipe with ghcr.io.
- `tests/build.sh` (83 checks, all pass): new checks for image sources (a runtime from an SDK
  image, its record, the pin hint, a building module's files and search
  paths, `B:\prefix\bin` first on PATH) and the Meson fixture (a DLL of C
  and C++ with a pkg-config file, found by the next module, linked into a
  program with resources; the same image when rebuilt).
- `tests/gtk.sh` (new, 8 checks): an app built with Meson against the
  SDK finds `gtk4` with pkg-config; on the runtime it opens a window and
  draws a frame under soft, low and AppContainer, and with OpenGL when
  DirectComposition is on; GLib's config directory is in the app's data
  directory and its settings backend is the key file; the runtime's
  `gtk4-query-settings` and `gtk4-demo` run.
- Reproducibility: the Meson image, GTK's SDK and its runtime have the same
  digests built in two fresh stores
  (`04fac7c7…`, `d1cb827d…`, `bc198529…`).

### Measurements

| | |
|---|---|
| GTK SDK, fresh store (zig's cache empty) | 947 s |
| GTK SDK, zig's cache warm | 800 s (Meson's configure checks, each a zig run, dominate) |
| GTK runtime from the SDK image | 4 s |
| Meson image | 26 s (pkgconf) |
| `com.mesonbuild.meson` | 30 MB, 370 files, 13.9 MB gzip |
| `org.gtk.Gtk4.Sdk` | 97 MB, 1,514 files, 34.5 MB gzip |
| `org.gtk.Gtk4` | 64 MB, 235 files, 30.4 MB gzip |
| A GTK app's own layer (`tests/gtk`) | 37 KB |

## Decisions made along the way

- **zig's `rc` and Visual Studio**: zig's `rc` alias uses Visual Studio's
  headers when the machine has it (`/:auto-includes any`), so the same
  resource script built on one machine and failed on another (zlib's).
  The user chose a workaround in GTK's recipe (`/:auto-includes gnu`, as
  `CMAKE_RC_FLAGS` and in `RC`) over changing zig's alias, which would
  mean republishing zig and every image that pins it. Listed as a known gap.
- **`B:\prefix\bin` on PATH** for every build, rather than in each GTK
  module's commands: Flatpak's builds do the same, and it needed no recipe
  field.
- **libffi static**: GObject is its only user; static also sidesteps one
  case of the CRT-export problem below.
- **Patching Meson's `realpath`** in the image, rather than a
  `-ffile-prefix-map` that each recipe would need with the store's real
  path in it.

## Bugs found

- None in zigsaw's existing code. The Meson image's first build wasn't
  reproducible (`__pycache__`), nor were GTK's first SDK builds (bytecode,
  static libraries' debug records, Meson's real paths); a second store found
  each one.

## Findings

- **zig's CRT symbols get exported.** A DLL zig links without any
  `dllexport` exports all its symbols, and lld leaves out the MinGW C
  runtime's by object name (`crt2.o`, `dllcrt2.o`), which zig's
  (`crt2.obj`) don't match. Such DLLs export `atexit`, `_CRT_INIT` and
  `__mingw_module_is_dll`; linking one then gives `duplicate symbol:
  atexit`. HarfBuzz, FriBidi and libffi rely on auto-export. zig rejects
  `-Wl,--exclude-symbols`, but lld reads the same request from an object's
  `.drectve` section: GTK's SDK assembles one and links it everywhere.
- **zig's MinGW headers lack the WinRT headers** (`windows.storage.h`,
  `windows.foundation.h`, …) that mingw-w64 v13 ships; GLib's package
  parser includes them. Copied from the mingw-w64 v13.0.0 release.
- **zig objects keep a debug record naming a random temporary file**, even
  with `-g0`; `-s` when compiling drops it. Static libraries need it.
- **zig refuses `__DATE__` when optimizing** (`-Werror=date-time`), even
  though builds set `SOURCE_DATE_EPOCH` and the date is then fixed (Jan 1
  1980); `-Wno-error=date-time` for cairo's script tool.
- **zig's cache ignores `SOURCE_DATE_EPOCH`**: an object compiled without
  it is reused with it. Builds always set it, and keep zig's cache to
  themselves, so it doesn't affect them.
- **CRoaring's AVX-512 code** in GTK doesn't compile for zig's generic
  x86-64 target (`evex512` off); `CROARING_COMPILER_SUPPORTS_AVX512=0`.
- **`zig rc` writes `.res` files**, which lld can't take from inside a static
  library, where GTK puts its resources; `/:output-format coff` writes an
  object instead.
- **GTK 4.24 draws with cairo on Windows by default**: OpenGL needs
  DirectComposition, which GDK only turns on with `GDK_DEBUG=dcomp`.
- **GTK works in all three sandboxes.** Under AppContainer, DirectWrite
  warns it can't open a font (likely one installed for the user only).

## Known gaps

- zig's `rc` alias depends on whether the machine has Visual Studio (see
  above); only GTK's recipe works around it.
- GTK apps' commands are console shims: started from Explorer, a GTK app
  opens a console window too. No Start menu shortcuts.
- The SDK is 14 minutes of building, which CI now does on every run: the
  Reproduce timeout went from 60 to 90 minutes, unmeasured on a runner.
- `tests/gtk.sh` needs a store with GTK's images, and opens windows; on a
  CI runner it hasn't run yet.
- Upstream reports drafted, not filed: zig `rc` auto-includes, zig CRT
  exports, zig's missing WinRT headers.

## Suggested for iteration 11

- GUI apps on the desktop: a windows-subsystem shim chosen by the
  target's PE subsystem, and Start menu shortcuts (Flatpak's `.desktop`
  exports).
- Fix zig's `rc` alias in zig's image (`/:auto-includes gnu`), with the
  republish it brings.
- Read the first Reproduce run with GTK: its time, and `tests/gtk.sh` on a
  runner's desktop.
- File the three zig reports.
- A GTK app of note on the runtime (a text editor or image viewer), and
  libadwaita on the SDK.
