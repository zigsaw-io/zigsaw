# Recipes

A recipe is a JSON file saying how the app runs, and listing the modules
that make up its files, each with pinned sources:

```json
{
  "id": "net.frippery.busybox",
  "version": "FRP-6075-g169694ebd",
  "command": "busybox.exe",
  "path": ["."],
  "env": {},
  "permissions": { "network": false, "filesystem": [] },
  "modules": [
    {
      "name": "busybox",
      "sources": [
        {
          "url": "https://frippery.org/files/busybox/busybox-w64-FRP-6075-g169694ebd.exe",
          "sha256": "07bb1e5b095b00d68a695481f9240879f33c5724b40aa2308f999d54ed78f075",
          "dest": "busybox.exe"
        }
      ]
    }
  ]
}
```

Modules go into the app's files in order, so a later one can overlay an
earlier one. Sources are either a `url` (a `sha256` is required; leave it out
once and the build error prints the hash to pin), a local `path`, or another
`image` (see [images as sources](#images-as-sources)). A source
is a single `file`, or an archive (`zip`, `tar`, `tar.gz`/`tgz` or `tar.xz`)
extracted into `dest` with optional `strip`. The type is inferred from the
file name, or given as `type` for a URL that doesn't end in one. A link in a
tar to a file in the same archive becomes a copy of that file; a link to a
directory, or out of the archive, fails the build. Other archives, such as
`.7z` files and installers, come in as files, and a build command unpacks
them, with 7-Zip's image in the recipe's `sdk`
(`"sevenzip": "org.7_zip.7zip@sha256:..."`, then `7z x -o"$PREFIX" file.7z`).
`cleanup` leaves files out of the app: `"/include"` is a path from
the top, and `"*.pdb"` a file name pattern that matches anywhere. Building the
same recipe always produces the same image digest.

`name`, `summary`, `homepage` and `license` describe the app for
[`search` and `info`](#finding-apps): what people call it, what it is in a
line, an https URL, and an SPDX expression. All are optional, and left out
of the image when the recipe has none, so they don't change other images'
digests. `registry` names the keys it keeps in `HKEY_CURRENT_USER`
([registry settings](#registry-settings-kept-with-the-app)).

`exports` names the commands an app puts on PATH. Without it, the app exports
its command under its file name (`busybox` above); `"exports": {}` exports
nothing. An export can pass arguments before the caller's. That's how Node's
recipe runs npm without its `.cmd` wrapper:

```json
"exports": {
  "node": { "command": "node.exe" },
  "npm": { "command": "node.exe", "args": ["${app}\\node_modules\\npm\\bin\\npm-cli.js"] }
}
```

If another installed app already exports a name, the build skips it with a
warning.

`env` values, `path` entries and export arguments can use placeholders:
`${app}` for the app's directory, `${data}` for its data directory (the
fresh one, in an `--ephemeral` run), and `${cache}` for a directory of caches
that are safe to keep, `cache` in the data directory (see
[tool caches](#building-from-source) for what it means in builds). They're
expanded each time the app runs, so the image is the same on every machine.
Node's recipe uses them to keep global npm packages in its data directory,
and their commands on its PATH:

```json
"path": [".", "${data}\\npm"],
"env": { "NPM_CONFIG_PREFIX": "${data}\\npm" }
```

PATH entries in `${data}` are also where the app's runs install commands,
which then get shims (see
[commands installed while an app runs](#commands-installed-while-an-app-runs)).

## Runtimes

An app can run on another app's image, as Flatpak apps run on a runtime.
Prettier's recipe has Node as a runtime it calls `node`, pinned by the
digest of Node's image:

```json
"command": "${node}\\node.exe",
"args": ["${app}\\bin\\prettier.cjs"],
"runtimes": { "node": "org.nodejs.node:24.21.0@sha256:cb9c0bf069bdeb47..." },
"exports": {
  "prettier": { "command": "${node}\\node.exe", "args": ["${app}\\bin\\prettier.cjs"] }
}
```

`${node}` is then a placeholder for Node's directory, which the command,
exports, `path` and `env` can use. `args` go before the caller's, for the
app's own command as for an export. Leave the digest out once and the build
error prints the one to pin: the installed app's if its version matches,
otherwise the registry's. The build takes the runtime from the store if it's
there, built or pulled, and from its registry otherwise.

A runtime's files go into the app's image as a layer of their own, so
pulling Prettier brings Node's files without installing Node as an app, and
removing Node as an app doesn't affect Prettier. Each layer is unpacked once
and shared, so Node as an app and Node as Prettier's runtime use the same
files on disk. Every run gets the runtime's `path` entries after the app's,
its `env` before the app's, so Prettier's runs have npm's settings as
Node's do, and its [aliases](#building-from-source) after the app's. A
runtime can't have runtimes of its own; an [SDK](#building-from-source) and
an [image source](#images-as-sources) can.

A pinned runtime doesn't change by itself: moving Prettier to a newer Node
is an edit to its recipe, like a new source hash.

## Images as sources

A module can take another image's own files, as Flatpak makes a runtime
from its SDK. [GTK's](#gtk) runtime is its SDK's files, without what only
builds need:

```json
"cleanup": ["/include", "/lib/pkgconfig", "*.a"],
"modules": [
  { "name": "gtk", "sources": [{ "image": "org.gtk.Gtk4.Sdk:4.24.1@sha256:..." }] }
]
```

The image is pinned like a runtime, found the same way (the store, then
its registry), and kept like an SDK; `dest` puts its files in a directory.
Only the image's own files are taken, not its runtimes', as GTK's SDK has
zig, Meson and BusyBox.
Its layer isn't unpacked again: the files stream from its deployment into
the new layer. The config records the image's digest under `build.images`,
so the runtime depends only on the SDK image, and builds again with the same
digest without building the SDK.

## Building from source

A module with `build` commands compiles its sources instead of placing them.
[`recipes/sqlite.json`](recipes/sqlite.json) builds zlib and then SQLite with
zig's C compiler:

```json
"sdk": {
  "zig": "org.ziglang.zig:0.16.0@sha256:4f6673f39561e71c...",
  "busybox": "net.frippery.busybox:FRP-6075-g169694ebd@sha256:fa4eac7f8b4b8733..."
},
"cleanup": ["/include", "/lib"],
"modules": [
  {
    "name": "zlib",
    "sources": [{ "url": "https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.xz", "sha256": "...", "strip": 1 }],
    "build": [
      "for f in *.c; do zig cc -target x86_64-windows-gnu -O2 -c \"$f\" -o \"${f%.c}.o\" || exit 1; done",
      "zig ar rcs libz.a *.o",
      "mkdir -p \"$PREFIX/include\" \"$PREFIX/lib\"",
      "cp zlib.h zconf.h \"$PREFIX/include\" && cp libz.a \"$PREFIX/lib\""
    ]
  },
  {
    "name": "sqlite",
    "sources": [{ "url": "https://sqlite.org/2026/sqlite-amalgamation-3530400.zip", "sha256": "...", "strip": 1 }],
    "build": [
      "mkdir -p \"$PREFIX/bin\"",
      "zig cc -target x86_64-windows-gnu -O2 -s -DSQLITE_HAVE_ZLIB -I\"$PREFIX/include\" -o \"$PREFIX/bin/sqlite3.exe\" shell.c sqlite3.c \"$PREFIX/lib/libz.a\""
    ]
  }
]
```

- **`sdk`** names the images the build uses, pinned like runtimes. They're on
  PATH while building, before the runtimes, and aren't part of the app's
  image; its config records their digests. zig gives C and C++ compilers
  (`zig cc`, `zig c++`, `zig ar`, also as `cc`, `c++`, `ar`, `ranlib` and
  `rc`), and BusyBox gives sh, make, sed, awk, patch, tar and the rest of a
  Unix toolbox. An SDK image may have runtimes of its own, as
  [GTK's](#gtk) has zig, Meson and BusyBox: they come with it, right after
  it on PATH, without the recipe naming them, and its digest pins them. An
  image the recipe names too is used once; two versions of one app in a
  build fail it.
- **Modules** build in order. A module's sources are unpacked into its own
  directory, and its commands run there one after another, until one fails.
  Whatever the modules install into `$PREFIX` is the app's files, after
  `cleanup`. A later module sees what earlier ones installed, as SQLite finds
  zlib above. A module without `build` puts its sources into `$PREFIX`.
- **Programs earlier modules installed run by name:** `B:\prefix\bin` is on
  PATH, after the [aliases](#building-from-source) and before the SDK, as
  `/app/bin` is in Flatpak's builds. That's how GTK's modules run the
  `glib-compile-resources` that GLib's module built.
- **Libraries are found** where pkg-config and CMake look:
  `PKG_CONFIG_PATH` is `B:\prefix\lib\pkgconfig;B:\prefix\share\pkgconfig`,
  then the `lib\pkgconfig` and `share\pkgconfig` of each SDK or runtime image
  that has them, such as [GTK's SDK](#gtk), and `CMAKE_PREFIX_PATH` is
  `B:\prefix` and those images' directories.
- **Commands** run in BusyBox's `sh`, or with `"shell": "cmd"` in cmd.exe
  (then `%PREFIX%`). `env` adds variables for a module's commands.
- **The build sandbox** is like a run's: an environment built from scratch,
  with fresh profile folders, and a job object that ends whatever the commands
  leave running. `SOURCE_DATE_EPOCH` is fixed at 1980-01-01.
- **Builds happen on `B:`.** The build's directory is mapped to `B:` while it
  runs, as `subst` does, so the paths compilers write into what they build
  (`__FILE__` in asserts, debug info) are `B:\src\<module>\...` on every
  machine. Builds take turns with `B:`, and a build fails if something other
  than zigsaw has mapped it.
- **No network**, unless a module sets `"network": true`. Sources are the
  pinned inputs; a module that downloads makes an image that can't be
  expected to reproduce, so its config records it and installing it warns.
  This is a convention, not a wall: build steps get proxy variables pointing
  nowhere, which tools such as curl, wget, npm and pip honour. What a
  package manager would fetch comes from a [vendor step](#vendor-steps)
  instead.

`zigsaw build --keep-build-dir` keeps the build's directory afterwards, to
look at what a failed build left; `zigsaw prune` deletes it later.

Three things about zig's C compiler, for executables that reproduce:

- **Name the target.** Without `-target`, `zig cc` builds for the machine
  it runs on, its CPU and Windows version included, so a build elsewhere
  differs, and the result may not run on older CPUs. The recipes pass
  `-target x86_64-windows-gnu`, and the `cc` and `c++` aliases do.
- **Pass `-s`.** Otherwise it writes a PDB with each executable, and those
  differ from build to build. zig also refuses `__DATE__` and `__TIME__`,
  which would differ too.
- **Link with an optimization level**, such as `-O2`, or with
  `-Wl,-Brepro`. zig stamps executables it links without one with the
  time.

**Builds are reused.** zigsaw remembers which image each build made, by a
hash of its inputs: the recipe, its local sources, and zigsaw itself (URL
sources and images are pinned in the recipe). Building an unchanged recipe
again, or `zigsaw update` of an app built from one, takes the image of the
earlier build instead of building it again, since the result would be the
same. `-v` says so; `zigsaw build --rebuild` builds anyway.

**Tool caches are kept.** An SDK or runtime image can point a tool's cache
at `${cache}`, as zig's does:

```json
"env": { "ZIG_GLOBAL_CACHE_DIR": "${cache}" }
```

In a build, `${cache}` is `B:\cache\<tool id>`, a directory zigsaw keeps
between builds in the store and moves onto `B:` for each one. zig keeps the C
runtime it builds on first use there, about 30 s of work, and the objects it
compiles, so building SQLite takes 2 s instead of 42 the second time.
`${cache}` is only for caches that are safe to keep, being keyed by the
contents of their inputs, as zig's is: a build with a warm cache makes the
same image as one without. Whatever else a tool keeps in its profile folders
is still fresh in each build.

**Images can give builds commands.** An SDK or runtime image can provide a
command under a name that other tools look for. zig's provides a C compiler
under the names build scripts and makefiles expect, and an assembler, which
Rust needs:

```json
"aliases": {
  "cc": { "command": "zig.exe", "args": ["cc", "-target", "x86_64-windows-gnu"] },
  "c++": { "command": "zig.exe", "args": ["c++", "-target", "x86_64-windows-gnu"] },
  "ar": { "command": "zig.exe", "args": ["ar"] },
  "ranlib": { "command": "zig.exe", "args": ["ranlib"] },
  "rc": { "command": "zig.exe", "args": ["rc"] },
  "as": { "command": "zig.exe", "args": ["cc", "-target", "x86_64-windows-gnu", "-c", "-x", "assembler"], "drop": ["--64"] }
}
```

Aliases are like exports, but for what runs with the image rather than for
you. In a build that uses the image, each one is `B:\bin\<name>.exe`, first
on its PATH. In runs of the image itself, and of apps that have it as a
runtime, they're in the store's `aliases\<app id>\`, first on the run's
PATH, so a Meson run finds the C compiler of a zig runtime. An alias runs
its command with its arguments, then its caller's, in the caller's
environment. `drop` leaves out the caller's arguments that equal one of its
values: GNU `dlltool` passes its assembler `--64`, which zig's cc doesn't
take. Arguments can't use `${data}` or `${cache}`. If two images alias the
same name, the one listed first in the recipe wins; in runs, the app's own,
then its runtimes' in order. Aliases also win over BusyBox's applets of the
same name, which its sh would otherwise run instead of anything on PATH
(zig's `ar` over BusyBox's): builds and runs list them in
`BB_OVERRIDE_APPLETS`.

zig's image also sets the variables most build tools read to find a C
toolchain, and to link with it reproducibly:

```json
"CC": "cc",
"CXX": "c++",
"RC": "rc",
"LDFLAGS": "-s -Wl,-Brepro",
"CGO_LDFLAGS": "-s -Wl,-Brepro"
```

`CC`, `CXX` and `RC` name the aliases above, for [CMake](#cmake), make and
Go's cgo. `LDFLAGS`, which CMake, make and configure scripts read, and
`CGO_LDFLAGS`, which Go reads, take care of the last two of the three
things above for every link: no PDB, and a timestamp that comes from the
contents.

## Vendor steps

Package managers, such as cargo, fetch a project's dependencies from the
network, which build commands don't have. A module's `vendor` step fetches
them first, and the recipe pins what it fetched by hash, as it pins
downloads:

```json
"vendor": {
  "commands": ["cargo vendor --locked vendor"],
  "dir": "vendor",
  "sha256": "c58cbe1a06b9fa52..."
}
```

- **The commands run with network access**, in the module's directory,
  after all downloads and before any module builds. They see the module's
  sources and the SDK, not what earlier modules installed.
- **The hash is of what they leave in `dir`**, made into a tar as layers
  are (sorted, without times or owners), so it depends only on file names and
  contents. Leave it out once and the build fails, printing the hash to pin;
  a different result fails the build, naming both.
- **It's kept with the downloads**, under its hash, so later builds take it
  from there without running the commands, and without the network.
- **The build sees the same files either way.** After the commands run,
  the module's directory and the build's profile folders start again from
  scratch, with only the module's sources and `dir`.
- **The image stays hermetic.** Its config records the hash under
  `build.vendor`, and the build commands still have no network.

This suits any tool that puts a project's locked dependencies in a
directory, such as `cargo vendor` or `go mod vendor`. It relies on the tool
fetching the same files every time, which a lockfile gives; the pinned hash
catches it if not.

## CMake

The CMake image, [`org.cmake.cmake`](recipes/cmake.json), is Kitware's
Windows release with Ninja's, without CMake's GUI and its HTML
documentation. It sets `CMAKE_GENERATOR=Ninja`, so `cmake -S . -B out`
writes Ninja's files. With zig in the SDK too, CMake takes zig's compilers
from `CC`, `CXX` and `RC`, and its link flags from `LDFLAGS`, as
[zig's image](#building-from-source) sets them:

```json
"sdk": {
  "cmake": "org.cmake.cmake:4.4.4@sha256:...",
  "zig": "org.ziglang.zig:0.16.0@sha256:...",
  "busybox": "net.frippery.busybox:FRP-6075-g169694ebd@sha256:..."
},
"cleanup": ["/include", "/lib"],
"modules": [
  {
    "name": "zstd",
    "sources": [{ "url": "https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz", "sha256": "...", "strip": 1 }],
    "build": [
      "cmake -S build/cmake -B out -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=\"$PREFIX\" -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_TESTS=OFF",
      "cmake --build out",
      "cmake --install out"
    ]
  }
]
```

That's [`recipes/zstd.json`](recipes/zstd.json). CMake sees zig as Clang
for MinGW, and compiles zstd's C and its assembly with it.
`cmake --install` puts the program, its library and headers into `$PREFIX`,
and `cleanup` leaves only the program. Without `RC`, CMake would look for
GNU's `windres` to compile resources; with it, CMake uses zig's `rc`, with
the options of Microsoft's `rc.exe`. Builds reproduce without anything
more: CMake writes the paths of the sources on `B:` into what it builds,
which are the same everywhere.

## Meson

The Meson image, [`com.mesonbuild.meson`](recipes/meson.json), is Python's
embeddable distribution with Meson's source release, Ninja, and pkgconf,
which the recipe builds from source with that Meson and zig. Builds get
`meson`, `ninja` and `pkg-config` as [aliases](#building-from-source); run
as an app, it's `meson`, with the same aliases. With zig in the SDK too, Meson takes zig's
compilers from `CC` and `CXX`, sees zig as Clang with its own linker
(`ld.zigcc`), and compiles resources with zig's `rc`, whose help says it's a
drop-in for Microsoft's:

```json
"sdk": {
  "meson": "com.mesonbuild.meson:1.12.1@sha256:...",
  "zig": "org.ziglang.zig:0.16.0@sha256:...",
  "busybox": "net.frippery.busybox:FRP-6075-g169694ebd@sha256:..."
},
"modules": [
  {
    "name": "greet",
    "sources": [...],
    "build": ["meson setup out --prefix=\"$PREFIX\"", "meson install -C out"]
  }
]
```

Shared libraries are DLLs in `bin`, with import libraries in `lib`, and a
later module finds them through their pkg-config files in `B:\prefix`.
pkgconf treats no directory as the system's, so it keeps `-IB:/prefix/include`
in the flags it prints, and it relocates a `.pc` file's `prefix` to where
the file is, so an SDK image's work from wherever it's deployed.

Meson's own release resolves the directories it's given to their real
paths, which takes them off `B:`, to the build's directory in the store.
Paths it writes into what it builds, such as the absolute ones in its unity
builds' sources (GTK's SVG code, whose asserts name their files), would
then differ from store to store. The image's Meson keeps the paths as given
instead (the recipe changes its `realpath` calls with `sed`), so they stay on `B:`.

## GTK

GTK 4 comes as two images, as Flatpak's GNOME runtime does:

- **[`org.gtk.Gtk4.Sdk`](recipes/gtk4-sdk.json)** builds GTK 4.24.1 and
  everything it needs from source with Meson, CMake and zig: zlib, libpng,
  libjpeg-turbo, libtiff, PCRE2, libffi, GLib 2.90, pixman, FriBidi,
  HarfBuzz (with DirectWrite), cairo, Pango, graphene, libepoxy, gdk-pixbuf, Microsoft's
  DirectX headers, and GTK, with its demos, then the hicolor and Adwaita
  icon themes and libadwaita 1.10, with its demo; then libsoup 3.8 with
  OpenSSL 3.5 (static), SQLite, nghttp2, libpsl and glib-networking,
  librsvg 2.63 with FreeType, libxml2 and its GdkPixbuf loader, and enchant
  2.8 with hunspell 1.7 and an en_US dictionary. Its first modules take GNU
  gettext 1.0 and libiconv from their own image,
  **[`org.gnu.gettext`](recipes/gettext.json)**, as an
  [image source](#images-as-sources): gettext takes three quarters of an
  hour to build, which the SDK's builds don't repeat. It keeps their
  headers, import libraries and pkg-config files, so apps build against it
  by listing it in their `sdk`. Its runtimes are zig, Meson and BusyBox,
  which it builds with and which builds that use it get too, and it exports
  their commands, so it builds programs
  [without a recipe](#building-without-a-recipe). It takes about 35 minutes
  to build from scratch, once gettext's image is there.
- **[`org.gtk.Gtk4`](recipes/gtk4.json)** is the runtime: the SDK's files
  as an [image source](#images-as-sources), without the headers, libraries
  and build tools, so it builds in seconds once the SDK is there. Apps list
  it in their `runtimes`. It keeps GIO's modules, GdkPixbuf's loaders and
  enchant's providers from the SDK's `lib`, and the translations and
  gettext's libintl, without gettext's tools. As an app, it runs `gtk4-demo`, exports
  `gtk4-demo`, `gtk4-widget-factory`, `gtk4-node-editor`,
  `gtk4-print-editor`, `gtk4-query-settings`, `adwaita-1-demo`, `gio`,
  `pango-view` and `pango-list`, and adds
  "GTK Demo", "GTK Widget Factory" and "Adwaita Demo" to the Start menu.

An app built against GTK, as [`tests/gtk`](tests/gtk) is:

```json
"command": "bin/hello-gtk.exe",
"path": ["bin"],
"runtimes": { "gtk": "org.gtk.Gtk4:4.24.1@sha256:..." },
"sdk": { "gtksdk": "org.gtk.Gtk4.Sdk:4.24.1@sha256:..." },
"modules": [
  {
    "name": "hello",
    "sources": [{ "path": "meson.build" }, { "path": "hello.c" }],
    "build": ["meson setup out --prefix=\"$PREFIX\"", "meson install -C out"]
  }
]
```

The SDK brings Meson, zig and BusyBox. Meson finds `gtk4` through the SDK's pkg-config files. When the app runs,
Windows finds GTK's DLLs on PATH, in the runtime's `bin`. The runtime's
variables keep GLib's files in the app's data directory (`XDG_CONFIG_HOME`
and the rest; otherwise GLib asks Windows for the user's AppData folder,
bypassing zigsaw's), and its settings in a key file there
(`GSETTINGS_BACKEND=keyfile`; otherwise the registry). GTK draws with cairo
by default on Windows; `--env=GDK_DEBUG=dcomp` turns on DirectComposition,
and with it OpenGL. GTK apps run in all three sandboxes.

Apps get HTTP from libsoup, whose TLS comes from GIO: glib-networking's
OpenSSL module, which GLib finds in the runtime's `lib\gio\modules` and
which trusts the certificates in Windows' certificate stores (as browsers
do), not a bundled list. libsoup speaks HTTP/2 (nghttp2) and knows the
Public Suffix List (libpsl, built in). GdkPixbuf loads SVGs with librsvg's
loader, which the runtime's `loaders.cache` names by a path relative to the
runtime, so GtkBuilder files with SVG images work (GTK's widget factory has
one).

Text is shaped by HarfBuzz with DirectWrite, so a font file an app adds to
Pango, as GtkSourceView does, shapes like the system's fonts. Spelling comes
from enchant, which libspelling uses: Windows' own spell checker (enchant's
WinSpell provider) for the languages Windows has, and hunspell with the
runtime's en_US dictionary (LibreOffice's) where it has none, in that order
(the runtime's `share\enchant-2\enchant.ordering`). A user's own word list
is in the app's data directory.

GLib, GTK, libadwaita, GdkPixbuf, libsoup and glib-networking are
translated, through GNU gettext's libintl: the runtime has their
translations into 124 languages (28 MB). Apps speak Windows' display
language, or the one `LANGUAGE` names, which a run passes on only when it's
given, as zigsaw's runs don't take your variables:

```powershell
zigsaw run --env=LANGUAGE=de org.gnome.TextEditor   # or once: zigsaw override --env=LANGUAGE=de ...
```

Emoji are drawn in color with Segoe UI Emoji: Pango asks for a color font
for an emoji that wants one (followed by U+FE0F, as GTK's emoji chooser
shows them), and its Windows font map, which can't tell color fonts from
others, matched no font at all for that; the SDK's Pango lets any font
match.

### Building without a recipe

GTK's SDK exports the commands a build needs, from its runtimes and its
own: `cc` and `c++` (zig's, for the same target as builds), `ar`, `rc`,
`windres` (GNU windres's command line, for zig's `rc`, as Rust's
winresource and embed-resource crates run it), `pkg-config` (which finds
the SDK's libraries), `meson`, `ninja`, `sh`, `make`, gettext's `msgfmt`,
`msgmerge` and `xgettext`, and GLib's and GTK's tools. Like other exports, they run in the
SDK's environment, with the working directory (the SDK has the `cwd`
permission), and inside it Meson finds the compiler and the rest through
the runtimes' aliases. With the store's `bin` on PATH:

```
zigsaw pull org.gtk.Gtk4.Sdk
cd C:\work\hello
cc hello.c -o hello.exe $(pkg-config --cflags --libs gtk4)
meson setup out && meson compile -C out
zigsaw run --command=C:\work\hello\hello.exe org.gtk.Gtk4
```

The program runs on the runtime, which has GTK's DLLs on PATH:
`--command` takes the absolute path of a program of yours (a relative one
is in the app). `sh` is a shell with all of it, as builds have. Meson's
builds are stripped, as zig's `LDFLAGS` asks; `cc` itself takes `-s` for
that. The SDK has each import library
twice, as `libgtk-4.dll.a` and as `gtk-4.lib`: zig's linker looks for
`-lgtk-4` under the second name, and Meson and libtool give the first.

Building the stack with zig took a few workarounds, which the SDK's recipe
spells out:

- Its first module assembles an object that every module links, asking
  lld not to export the C runtime's `atexit`, `_CRT_INIT` and
  `__mingw_module_is_dll`. A DLL with no `dllexport`, such as HarfBuzz's or
  FriBidi's, exports all its symbols, and zig names its C runtime's objects
  so that lld doesn't recognise them to leave them out; an executable linking
  such a DLL then has `atexit` twice.
- zig's MinGW headers leave out the WinRT ones (`windows.storage.h` and
  more) that GLib uses, so a module copies them from the mingw-w64 release
  zig's headers come from.
- The static libraries the SDK keeps (libffi's, the DirectX headers') are
  compiled with `-s`. zig writes debug records into objects even with
  `-g0`, naming the temporary file it compiled to, whose name is random.
  Executables and DLLs lose them when linked with `-s`; static libraries
  aren't linked.
- GLib's Python tools leave `__pycache__` when the build runs them; the
  SDK leaves it out, as the bytecode records when sources were unpacked.
- `rc` gets `/:auto-includes gnu`, as `RC` for Meson and
  `CMAKE_RC_FLAGS` for CMake (see [known gaps](#known-gaps)), and GTK's
  `rc` writes COFF objects, since GTK puts its resources in a static
  library first.
- OpenSSL's `Configure` needs a Perl that makes Unix paths for its
  `mingw64` target; Strawberry Perl makes Windows ones, so its build loads
  [a small module](recipes/gtk4-sdk/openssl-unixspec.pm) into each Perl it
  runs that gives `File::Spec` Unix paths with drive letters. BusyBox's
  `make` runs one job at a time, so the recipe compiles OpenSSL's objects
  with `xargs -P` from `make -n`'s list, and `make` only archives them:
  75 seconds instead of 16 minutes. OpenSSL is static, linked into
  glib-networking's module.
- glib-networking opens Windows' certificate stores for writing, which a
  low-integrity process may not; the recipe opens them read-only, so HTTPS
  works under `--sandbox=low`.
- librsvg's Rust code is built by cargo-c as a static library, which Meson
  links into `librsvg-2-2.dll` with zig. The recipe tells Meson the Rust
  target (`-Dtriplet=x86_64-pc-windows-gnu`; it would guess `gnullvm` for a
  clang), links the static library rather than all of it (each crate's
  import libraries define the same import descriptors), drops the `nm`
  step that only feeds a version script Windows doesn't use. `rsvg-convert`
  is in the SDK, not the runtime. Its crates come from a
  pinned [vendor step](#vendor-steps), and it fixes Python's hash seed
  (`PYTHONHASHSEED=0`), as its script for the libraries Rust needs dedupes
  them with a `set` and would write them in another order each build.
- cairo's script tool prints `__DATE__`, which zig refuses when optimizing
  (`-Wno-error=date-time`; builds fix the date with `SOURCE_DATE_EPOCH`),
  and CRoaring in GTK leaves out its AVX-512 code, which zig's generic
  x86-64 target can't compile.
- hunspell and enchant build with their release's `configure` and
  BusyBox's make, which took most of the rest. Autoconf looks for `sed`,
  `grep` and `pkg-config` as files on PATH, where BusyBox's applets and the
  `.exe` aliases aren't, so the modules name them (`SED=sed` and so on).
  libtool decides how to make DLLs from `$LD --help`, which zig has no `ld`
  for: [a small script](recipes/gtk4-sdk/autotools-ld.sh) runs lld's MinGW
  driver (`zig ld.lld -m i386pep`) and says it auto-imports, as lld does.
  libtool would link C++ with `-nostdlib` and the runtime libraries it reads
  from `c++ -v`, which zig doesn't print, so the recipe drops `-nostdlib` and
  zig's `c++` links its own; and it checks libraries with `objdump`, which
  isn't there (`lt_cv_deplibs_check_method=pass_all`). Release tarballs
  give `configure`, `aclocal.m4` and `Makefile.in` the same time to the
  second as their sources, and BusyBox's make remakes a target whose
  prerequisite is as new as it, where GNU make doesn't, so
  [a script](recipes/gtk4-sdk/autotools-mtimes.sh) orders their times first.
  enchant's library exports what its headers declare, from a `.def` file
  made from them, as libtool's own way needs `nm`; its providers export only
  `init_enchant_provider`.
- gettext and libiconv ([`recipes/gettext.json`](recipes/gettext.json))
  build the same way, with a few more. gnulib looks for grep as
  `EGREP_TRADITIONAL` too. libtool runs `$RC` and `$WINDRES` as GNU windres,
  so they're [a script](recipes/gtk4-sdk/autotools-windres.sh) that turns
  its command line into zig `rc`'s. Their headers export with a `visibility`
  attribute when the compiler takes one, which clang does and GCC for
  MinGW doesn't, and which Windows DLLs don't heed: configure is told the
  compiler doesn't (`gl_cv_cc_visibility=no`), so they use `dllexport`.
  Some functions are `dllexport` only for MSVC, relying otherwise on GNU
  ld's `--export-all-symbols` or on a `.def` that libtool makes with `nm`;
  zig's linker ignores the first and there's no `nm`, so
  [the recipe](recipes/gettext/exports.sh) exports them for any Windows
  compiler and leaves the `nm` lists out. gettext's libtool keeps
  `-nostdlib` in a variable of its own. Its manuals, man pages and
  translations come built in the release, and the build leaves them be.
- Pango's Windows font map gets a one-line patch so that it finds a font
  for text that asks for color glyphs (see above).
- GTK's input method for Windows (`gtkimcontextime.c`) listens to the
  window's messages for the text widget that has the focus, and in 4.24.1
  went on listening for one that was removed while it had it, reading freed
  memory at the next message: Text Editor crashed opening a file in place of
  an empty draft it had restored. [A patch](recipes/gtk4-sdk/gtk-ime-filter.patch)
  has it remember where it listens, and stop when it loses the focus,
  whatever has become of the widget, and when it's disposed of.
- Shortcuts and file associations can't show an SVG, which is what GTK
  apps' icons are. [A script](recipes/gtk4-sdk/svg2ico.sh) makes an `.ico`
  of one: the SVG drawn by the SDK's `rsvg-convert` at six sizes, as PNGs,
  which an `.ico` may hold. The runtime's recipe makes its demos' with it,
  and Text Editor's its own.

### Rnote

[Rnote](recipes/rnote.json) 0.14.2 is a GTK and libadwaita app in Rust,
built from its release tarball, which vendors its crates, with GTK's SDK and
Rust's image. Its Meson build runs cargo; the recipe adjusts what assumes
MSYS2 or Linux:

- Its build script runs `env` and `cp`, which cmd.exe doesn't have, and
  Meson runs `cat` and `cp`: [a Python script](recipes/rnote/cargo_build.py)
  and Meson's own functions do their jobs. Meson doesn't compile any Rust
  itself, so `project()` names no languages; with zig as `CC`, Meson would
  have rustc link its sanity check with zig.
- It sets `XDG_DATA_DIRS` and GdkPixbuf's loader directory to the
  directories next to its executable, which would hide GTK's icons, schemas
  and SVG loader in the runtime; [a patch](recipes/rnote/data-dirs.patch)
  leaves GLib's defaults, which have both.
- Its fonts (Virgil, Grape Nuts, OpenDyslexic, TT2020) are found by
  fontconfig on Linux. [A patch](recipes/rnote/fonts.patch) adds them to
  Pango [itself](recipes/rnote/fonts.rs), on each thread that draws text, as
  pangocairo has a font map per thread. Virgil's family is
  "Virgil 3 YOFF".
- gettext-rs links `-lintl` from `MINGW_PREFIX`, and from `C:\msys64\mingw64`
  when that's unset, which would be the machine's MSYS2; the recipe sets it
  to the SDK. The executable's icon is compiled by the SDK's `windres`.
- It saves a document by writing a temporary file next to it and renaming
  that, and fails if it can't make one. [A patch](recipes/rnote/save-in-place.patch)
  has it write the document in place then, so that it saves a file it was
  given with [`--file`](#opening-a-file) in a sandbox.

It's offered for `.rnote` and `.xopp` files (see
[File associations](#file-associations)), and Text Editor for `.txt`, `.md`
and `.log`.

`rnote-cli` converts between formats without a window:

```powershell
rnote-cli create notes.rnote; rnote-cli import notes.rnote -i notes.xopp
rnote-cli export doc --output-file notes.pdf notes.rnote
```

## Rust

The Rust SDK image, [`org.rust-lang.rust`](recipes/rust.json), is the
official toolchain for `x86_64-pc-windows-gnu`: rustc, cargo, the standard
library, and the MinGW linker Rust ships with it. It needs no Visual Studio.
It leaves out `rust-lld` and the WebAssembly linker, which windows-gnu builds
don't use, so the image is 650 MB rather than 880. A Rust module vendors its
crates, then builds offline from them:

```json
"sdk": {
  "rust": "org.rust-lang.rust:1.99.0@sha256:...",
  "zig": "org.ziglang.zig:0.16.0@sha256:...",
  "busybox": "net.frippery.busybox:FRP-6075-g169694ebd@sha256:..."
},
"modules": [
  {
    "name": "hello",
    "sources": [{ "path": "Cargo.toml" }, { "path": "Cargo.lock" }, { "path": "main.rs", "dest": "src/main.rs" }],
    "vendor": { "commands": ["cargo vendor --locked vendor"], "dir": "vendor", "sha256": "..." },
    "build": [
      "cargo build --offline --locked --release --config 'source.crates-io.replace-with=\"vendored\"' --config 'source.vendored.directory=\"vendor\"'",
      "cp target/release/hello.exe \"$PREFIX/hello.exe\""
    ]
  }
]
```

[`recipes/ripgrep.json`](recipes/ripgrep.json) builds ripgrep this way from
its crate on crates.io, with ripgrep's own `release-lto` profile, the one its
release binaries are built with, and generates its man page and shell
completions as its releases do.

**Rust builds need zig in the SDK as well.** The `windows-sys` crate, which
nearly every Rust program for Windows uses, links Windows' functions in a
way that makes rustc run `dlltool`. Rust's image gives builds the GNU
`dlltool` Rust ships as an alias, but it needs an assembler that Rust
doesn't ship
([rust-lang/rust#103939](https://github.com/rust-lang/rust/issues/103939)):
zig's `as` alias. (LLVM's `dlltool`, which needs none, makes import
libraries that GNU ld, Rust's linker here, lays out wrongly: some imports
are never bound, and the program crashes when it calls one.
`zig build imports` builds a checker for that, which `tests/build.sh` and
`tests/published.sh` run.)

**Crates that compile C**, with the [cc crate](https://docs.rs/cc), use
zig's `cc`, `c++` and `ar` aliases too. For the `x86_64-pc-windows-gnu`
target, the cc crate would look for `gcc` instead, and pass a `--target`
that zig doesn't accept, so zig's image also sets the variables it reads:

```json
"CC_x86_64_pc_windows_gnu": "cc",
"CXX_x86_64_pc_windows_gnu": "c++",
"AR_x86_64_pc_windows_gnu": "ar",
"CRATE_CC_NO_DEFAULTS": "1",
"CFLAGS_x86_64_pc_windows_gnu": "-O3 -ffunction-sections -fdata-sections",
"CXXFLAGS_x86_64_pc_windows_gnu": "-O3 -ffunction-sections -fdata-sections"
```

`CRATE_CC_NO_DEFAULTS` turns off the cc crate's own flags, that `--target`
among them, so the flags it would pass in a release build come from
`CFLAGS` instead, whatever the profile. The C code is compiled with zig's
MinGW headers, which are for Windows' newer C runtime (UCRT), and linked
with Rust's MinGW libraries, for the older `msvcrt.dll`. So far that has
worked: [`recipes/bat.json`](recipes/bat.json) builds bat with oniguruma,
libgit2 and zlib this way, from its crate on crates.io, as its release
binaries have them.

Rust builds reproduce without further flags: crates' paths are relative to
the project, and the linker takes its timestamp from `SOURCE_DATE_EPOCH`.
The image sets `CARGO_PROFILE_RELEASE_STRIP=symbols`, as GNU `dlltool`
names the symbols of the import libraries it makes after rustc's temporary
directories, whose names are random; release builds leave the symbol table
out.

The image sets `CARGO_HOME` to `${data}\cargo`. Run as an app, cargo keeps
its home in its data directory, and what `cargo install` installs is a
[command on PATH](#commands-installed-while-an-app-runs). In builds, it's
`B:\data\cargo`, fresh for each build.

## Go

The Go SDK image, [`org.golang.go`](recipes/go.json), is Go's official
Windows release, without Go's own test suite. Its variables make Go builds
hermetic and reproducible by default:

```json
"GOPATH": "${data}\\go",
"GOCACHE": "${cache}",
"GOTOOLCHAIN": "local",
"GOFLAGS": "-trimpath -modcacherw"
```

- `GOTOOLCHAIN=local`: Go never downloads another toolchain, whatever a
  `go.mod` asks for.
- `-trimpath`: executables name their sources by module path, not by where
  the SDK and the sources were, so the same module builds the same image in
  any store. It applies to `go build` run as an app too.
- `-modcacherw`: Go's module cache can be deleted like any other directory,
  as builds delete theirs.
- `GOCACHE=${cache}`: compiled packages are kept between builds, as zig's
  cache is.

A Go module vendors its dependencies, then builds offline from them:

```json
"sdk": {
  "go": "org.golang.go:1.27.1@sha256:...",
  "busybox": "net.frippery.busybox:FRP-6075-g169694ebd@sha256:..."
},
"modules": [
  {
    "name": "hello",
    "sources": [{ "path": "go.mod" }, { "path": "go.sum" }, { "path": "main.go" }],
    "env": { "CGO_ENABLED": "0" },
    "vendor": { "commands": ["go mod vendor"], "dir": "vendor", "sha256": "..." },
    "build": ["go build -mod=vendor -o \"$PREFIX/hello.exe\" ."]
  }
]
```

[`recipes/fzf.json`](recipes/fzf.json) builds fzf this way, from its module
zip on proxy.golang.org, which never changes once published, with the flags
of fzf's own release builds.

[`recipes/zot.json`](recipes/zot.json) builds the zot registry's minimal
binary, as its Makefile's `binary-minimal` does. `go mod vendor` vendors
what every build of the module could need, for zot 561 modules, 415 MB. So
its vendor step then keeps only the packages, and their embedded files,
that `go list -deps ./cmd/zot` names: 68 MB from 166 modules. The tests run
their registries with it.

The image puts `GOPATH` in its data directory, with `${data}\go\bin` on
PATH, so what `go install` installs is a
[command on PATH](#commands-installed-while-an-app-runs).

**Go programs with C** (cgo) build with zig in the SDK as well. zig's image
sets `CC`, so cgo is on, with zig's `cc` as its C compiler, and
`CGO_LDFLAGS=-s -Wl,-Brepro`: Go links such programs with the C compiler,
whose linker would otherwise stamp them with the time and with the name of a
debug file that names Go's temporary directories. The recipe leaves out Go's
build ID:

```json
"sdk": {
  "go": "org.golang.go:1.27.1@sha256:...",
  "zig": "org.ziglang.zig:0.16.0@sha256:...",
  "busybox": "net.frippery.busybox:FRP-6075-g169694ebd@sha256:..."
},
"modules": [
  {
    "name": "hello",
    "sources": [{ "path": "go.mod" }, { "path": "main.go" }, { "path": "greet.c" }, { "path": "greet.h" }],
    "build": ["go build -ldflags=-buildid= -o \"$PREFIX/hello.exe\" ."]
  }
]
```

Go asks the C compiler for its version with `cc -### -x c -c -`, and hashes
the answer into the build ID. zig 0.16 prints the version but then fails,
looking for an object file that `-###` never makes, so Go hashes the error
instead, which names a temporary file and the store. Without a build ID, the
executable is the same from any store.

## MSVC

Projects that need Microsoft's compiler can use the Visual Studio installed
on the machine, since Visual Studio's license doesn't allow it to be an
image:

```json
"host": ["msvc"],
"modules": [
  {
    "name": "hello",
    "shell": "cmd",
    "sources": [{ "path": "hello.c" }],
    "build": [
      "cl /nologo /O2 /Brepro hello.c /link /Brepro",
      "mkdir %PREFIX%\\bin && copy hello.exe %PREFIX%\\bin\\"
    ]
  }
]
```

zigsaw finds the newest Visual Studio with the C++ tools (prereleases
included) with `vswhere`, and runs its `vcvars64.bat` to learn the build
environment: the compilers on PATH, `INCLUDE`, `LIB` and the rest. The
image's config records the MSVC and Windows SDK versions, and installing it
warns that it won't rebuild the same elsewhere. A machine with another
Visual Studio builds something else, so these builds are never reused
either. `/Brepro` keeps the compiler and linker from writing timestamps.

### GTK with MSVC

[`recipes/gtk4-msvc.json`](recipes/gtk4-msvc.json) builds GLib through GTK
4.24.1 and libadwaita with MSVC, as an experiment next to [GTK's SDK](#gtk),
which zig builds: the same sources at the same versions, with Meson's and
CMake's images and BusyBox for the commands. It isn't published, as it
can't be rebuilt elsewhere, and has no SDK and runtime split: one image,
`org.gtk.Gtk4.Msvc`, with `gtk4-demo-msvc` and `adwaita-1-demo-msvc`.

```powershell
zigsaw build recipes\gtk4-msvc.json   # nine minutes, with Visual Studio's C++ tools
gtk4-demo-msvc
```

- Meson and CMake find `cl`, `link` and the Windows SDK's `rc` by
  themselves, as nothing in the build sets `CC` (zig's image, which does,
  isn't in it). The recipe passes `/Brepro` and the prefix's headers and
  libraries in `CL` and `LINK`, which the compiler and linker read
  themselves, whatever the build system.
- What the zig recipe works around isn't needed: the object that keeps
  DLLs from exporting the C runtime's symbols, MinGW's missing WinRT
  headers, `rc`'s choice of headers, the import libraries under a second
  name, and a few warning and CPU flags.
- What it needs instead: GLib's `gi18n.h` includes `libintl.h`, and there's
  no gettext for MSVC here, so proxy-libintl is built first, as a DLL (as a
  static library Meson names it `libintl.a`, which the linker doesn't look
  for); so the image has no translations. libpng's CMake build installs no
  pkg-config file under MSVC, so the recipe writes one. libadwaita's demo
  is a GUI program with a `main`, which MSVC's linker wants told
  (`/entry:mainCRTStartup`). The Visual C++ runtime's DLLs are copied in
  from Visual Studio's redistributable directory, so the image doesn't
  count on one being installed.
- It has no librsvg, so the widget factory, which loads an SVG with
  GdkPixbuf, aborts, and isn't exported; nor libsoup, spell checking, or
  Text Editor. Those need Rust for MSVC's target, and autotools, which MSVC
  builds poorly.
- BusyBox's sh passes variables on with their names in capitals
  (`$VCTOOLSREDISTDIR`), and has a `link` of its own, which only a command
  typed in a recipe would get: Meson and Ninja start the linker themselves.

Against the same modules built with zig, on the same machine:

| | zig | MSVC 19.51 |
|---|---|---|
| Build | 14.4 min | 8.9 min |
| The stack's DLLs | 30, 26.9 MB | 31, 23.1 MB |
| `gtk-4-1.dll` | 10.5 MB | 9.8 MB |
| Image | 52.7 MB gzip, with gettext's tools and 27 MB of translations | 35.1 MB gzip, with 10 DLLs of the Visual C++ runtime |
| `gtk4-demo` to its window | 0.7 s | 0.7 s |
| Its memory then | 130 MB | 129 MB |
| Sandboxes | soft, low, appcontainer | soft, low, appcontainer |
| The same image from a second build | yes, on any machine | yes, in another store on this machine |

The MSVC image came out the same from two stores once two static
libraries were left out of it (DirectX-Headers'): the librarian stamps them
with the time, and `LINK` doesn't reach it. Another Visual Studio would
build another image, which zigsaw doesn't check; the config records which
built it.
