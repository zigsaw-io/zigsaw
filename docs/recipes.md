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
once and the build error prints the hash to pin), a local `path` (a file,
or a directory, such as a project's own: see [projects](#projects)), or
another `image` (see [images as sources](#images-as-sources)). A source
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

## Extension points

Some images are made to be added to a runtime after the fact, as a
Flatpak runtime's extensions are: PHP's extensions to PHP. A runtime (or
any app) declares an extension point, and an image that `extends` it joins
every run of whatever has the point, once installed, without apps listing
it. PHP's runtime ([`recipes/php.json`](recipes/php.json)):

```json
"extensions": {
  "net.php.php": { "version": "API20250925,NTS,VS17", "join": ["PHP_INI_SCAN_DIR"] }
}
```

and an extension ([`recipes/php-redis.json`](recipes/php-redis.json)):

```json
"env": { "PHP_EXT_REDIS": "${app}", "PHP_INI_SCAN_DIR": "${app}\\conf.d" },
"extends": { "point": "net.php.php", "version": "API20250925,NTS,VS17", "needs": ["net.php.php.Igbinary"] }
```

- **Which join**: the installed images that extend one of the run's
  points (the app's own, then those its runtimes have; an app that has PHP
  as a runtime has PHP's), at the point's `version`. Another version's
  don't, with a note on every run saying why, as an extension built for
  another PHP wouldn't load.
- **In what order**: by id, each after the extensions it `needs`. An
  extension whose needs aren't there doesn't join either, with a note.
- **As what**: like a runtime the app didn't list. Its directory is
  `${app}` in its own `path` and `env`; its PATH entries go after the
  runtimes', its variables after theirs and before the app's. The variables
  a point `join`s add up instead of replacing each other: each value's
  `;`-separated entries go after those already there, without repeats, so
  each extension adds its `conf.d` to `PHP_INI_SCAN_DIR`. The app's own
  entries come last.
- **Not**: an extension the app lists as a runtime itself (its pinned copy
  is the one), one `--noextension=<id>` leaves out (`run` or `override`;
  `--extension=<id>` has it join again), nor anything in builds, which have
  only the images their recipes pin. An extension's aliases aren't used,
  and an extension can't have runtimes of its own.

What runs therefore depends on what's installed, as with Flatpak's
extensions; `zigsaw run -v` lists them, and `list` shows which images have
points and what extends them. A zigsaw from before 0.24 ignores both
fields: extensions then install as apps of their own, and join nothing.

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
take. Arguments can't use `${data}` or `${cache}`. An image's alias may run
a file of one of its own runtimes, as its command may: Composer's image,
which has PHP as a runtime, aliases `composer` to
`"${php}\\php.exe"` with `"${app}\\composer.phar"`, so a recipe with
Composer as an SDK runs `composer install` (zigsaw 0.25.0 and later; 0.24
refuses such an image). A runtime's aliases, which an app copies, run only
the runtime's own files. If two images alias the
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
directory, such as `cargo vendor`, `go mod vendor` or `pip download`
([Python apps](#packages-from-pypi)). It relies on the tool
fetching the same files every time, which a lockfile gives; the pinned hash
catches it if not.

## Projects

A recipe can live in the project it builds, at its root, as `zigsaw.json`.
`zigsaw build` with no argument builds the one in the current directory, as
`make` builds its Makefile, and `zigsaw build <dir>` the one in `<dir>`;
parent directories aren't searched. Its source is the project's own
directory, a `path` that names a directory, `.` here. This repository's
[`zigsaw.json`](../zigsaw.json) builds zigsaw:

```json
"sdk": { "zig": "org.ziglang.zig:0.16.0@sha256:0379659d0e7a87ac..." },
"modules": [
  {
    "name": "zigsaw",
    "sources": [{ "path": ".", "skip": ["/.github", "/docs", "/recipes", "/scripts", "/tests", "/README.md"] }],
    "shell": "cmd",
    "build": ["zig build -Dstrip -p %PREFIX%"]
  }
]
```

A directory source gives the files git would commit in it:

- **What the `.gitignore` files ignore stays out**: those in the
  directory and below it, and those above it up to the top of its
  repository (where `.git` is), with git's rules: `#` comments, `!` to keep
  what an earlier pattern ignores (but not in an ignored directory, which
  git doesn't enter, and neither does zigsaw), a trailing `/` for
  directories only, a leading or middle `/` anchoring the pattern at the
  `.gitignore`'s directory, `*`, `?`, `[...]` and `**`. Matching ignores
  case, as git does on Windows (`core.ignorecase`). The global excludes and
  `.git/info/exclude` don't count, being the machine's rather than the
  project's.
- **`.git` stays out**, a directory or a file (in a worktree or a
  submodule), and so do empty directories, which git doesn't keep. A
  directory below with `.git` of its own, such as a submodule, has its own
  `.gitignore` files, not the outer ones.
- **`skip`** leaves out more, with `cleanup`'s patterns, from the
  directory: `"/docs"`, `"*.log"`. zigsaw's leaves out what isn't an input
  to its programs.
- **A link fails the build**, naming it, as git would commit it as a link,
  which an image can't hold; `skip` it. So does a directory that has no
  files to commit, or one that a `.gitignore` above it ignores.

`dest` puts the files in a directory; `sha256`, `type` and `strip` don't
apply. As line endings are the checkout's, a project whose builds should
match across machines fixes them in `.gitattributes`, as this one does.

A working tree isn't pinned as a download is. Its files are hashed instead,
as the build takes them, as a tar in the layer format, as a
[vendor step's](#vendor-steps) are: the hash depends only on their paths
and contents.

- **It's one of the build's inputs.** Building again with nothing changed
  takes the image built before, as does a change to an ignored or skipped
  file, which isn't one of the files. Each `zigsaw build` reads the files to
  hash them, 52 files in 35 ms for zigsaw's.
- **The image records it** under `build.sources`, as it does a local file's
  hash, so the same files make the same image anywhere. They aren't kept in
  the download cache, as local files aren't, so `push --sources` doesn't
  push them.
- **The build gets those files.** With build commands, they're copied to
  `B:\src\<module>`, and built there; the project's directory is only read.
  Without, they go from the directory into the layer. Either way, zigsaw
  hashes them again afterwards, and fails the build if one changed while it
  copied them, as its record wouldn't be of what it copied.

A project's own [vendor step](#vendor-steps) works as any other: `cargo
vendor` in the module's directory, with the project's files. The installed
app records where its recipe is, so `zigsaw update <app-id>` builds it again
from the directory as it is then.

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
  2.8 with hunspell 1.7 and an en_US dictionary. Each library comes with
  its introspection data (GIR files and typelibs), which
  gobject-introspection 1.86 makes, built early in the SDK with Python 3.14
  ([below](#introspection)). Its first modules take GNU
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
  enchant's providers from the SDK's `lib`, the typelibs and GLib's
  `libgirepository-2.0`, and the translations and
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

### GTK's data directories and extensions

GLib finds data (icons, settings schemas, dictionaries, GtkSourceView's
languages) in its system data directories, which on Windows are, unless
`XDG_DATA_DIRS` names them, the `share` next to the DLL that asks, next to
GLib's and next to the program, and `C:\ProgramData` and the Public
Documents folder. The runtime sets `XDG_DATA_DIRS` to its own `share`
instead, and has an [extension point](#extension-points) that joins it:

```json
"env": { "XDG_DATA_DIRS": "${app}\\share" },
"extensions": { "org.gtk.Gtk4": { "version": "1", "join": ["XDG_DATA_DIRS"] } }
```

So a run's data directories are the runtime's, then each installed
extension's, then the app's, and none of the machine's. An app on the
runtime names its own `share` the same way (joined after the others), as
Text Editor's recipe does, and so does GTK 3's runtime; one that looks its
settings schema up in the first source only, as Gaphor does, also sets
`GSETTINGS_SCHEMA_DIR`. The point's version is the layout's, not GTK's: an
extension at version 1 has a `share` for `XDG_DATA_DIRS`, whichever GTK it's
installed with.

Two hunspell dictionaries extend it, both from LibreOffice's dictionaries at
the commit the SDK's en_US comes from:
[`org.gtk.Gtk4.Hunspell.vi_VN`](recipes/gtk4-hunspell-vi.json) (Vietnamese)
and [`org.gtk.Gtk4.Hunspell.fr_FR`](recipes/gtk4-hunspell-fr.json) (French,
Grammalecte's `fr`, which enchant uses for every `fr_*`). Each is a
`share\hunspell` and:

```json
"env": { "XDG_DATA_DIRS": "${app}\\share" },
"extends": { "point": "org.gtk.Gtk4", "version": "1" }
```

Installed, every GTK app on the runtime checks those languages' spelling
with hunspell, where Windows has no spell checker for them;
`--noextension=org.gtk.Gtk4.Hunspell.fr_FR` leaves one out. An icon theme
would be an extension the same way, its icons in `share\icons`
([tests/gtk.sh](tests/gtk.sh) has one with an icon).

### Building without a recipe

GTK's SDK exports the commands a build needs, from its runtimes and its
own: `cc` and `c++` (zig's, for the same target as builds), `ar`, `rc`,
`windres` (GNU windres's command line, for zig's `rc`, as Rust's
winresource and embed-resource crates run it), `pkg-config` (which finds
the SDK's libraries), `meson`, `ninja`, `sh`, `make`, gettext's `msgfmt`,
`msgmerge` and `xgettext`, `nm`, gobject-introspection's `g-ir-scanner` and
`g-ir-compiler`, and GLib's and GTK's tools. Like other exports, they run in the
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
  enchant's library exports what upstream's `-export-symbols-regex` gives,
  which libtool turns into a `.def` file with
  [the SDK's `nm`](recipes/gtk4-sdk/nm.c) (`NM=nm`); its providers export
  only `init_enchant_provider`, from a `.def` of the recipe's, as they mark
  nothing for export.
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
  zig's linker ignores the first and gettext's image has no `nm` (GTK's
  SDK has one since), so
  [the recipe](recipes/gettext/exports.sh) exports them for any Windows
  compiler and leaves the `nm` lists out. gettext's libtool keeps
  `-nostdlib` in a variable of its own. Its manuals, man pages and
  translations come built in the release, and the build leaves them be.
- Pango's Windows font map gets a one-line patch so that it finds a font
  for text that asks for color glyphs (see above).
- `nm` is [a small program of the SDK's](recipes/gtk4-sdk/nm.c), as zig
  has none: it lists the symbols of COFF objects, static libraries and
  import libraries as GNU nm does, in its BSD and POSIX formats, which is
  what libtool's export lists and gobject-introspection read.
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

### GTK 3

GTK 3 is built on what GTK 4's SDK already has (GLib, Pango, cairo,
gdk-pixbuf, librsvg, libepoxy, HarfBuzz, gettext), so its images add only
what GTK 4's don't:

- **[`org.gtk.Gtk3.Sdk`](recipes/gtk3-sdk.json)** lists GTK 4's SDK as its
  SDK, and builds ATK (at-spi2-core's, without AT-SPI) and GTK 3.24.52 for
  Windows, its input methods built in, with its demos, and the legacy
  Adwaita icons, whose full-colour names GTK 3's widgets use (GTK 4's
  Adwaita 51 inherits them). It keeps headers, import libraries and
  pkg-config files, which name GLib's and the rest by pkg-config name, so a
  build finds them in GTK 4's SDK.
- **[`org.gtk.Gtk3`](recipes/gtk3.json)** is the runtime, made from it as
  GTK 4's is. GLib finds the settings schemas next to its own DLL, in GTK
  4's runtime, so this one names its own with `GSETTINGS_SCHEMA_DIR`.

A GTK 3 app lists both runtimes and both SDKs, as Pinta lists GTK's and
.NET's, and finds GTK 3's DLLs in one runtime's `bin` and GLib's in the
other's. The two runtimes are layers of their own, shared with every other
app that has them:

```json
"runtimes": {
  "gtk": "org.gtk.Gtk4:4.24.1@sha256:...",
  "gtk3": "org.gtk.Gtk3:3.24.52@sha256:..."
},
"sdk": {
  "gtksdk": "org.gtk.Gtk4.Sdk:4.24.1@sha256:...",
  "gtk3sdk": "org.gtk.Gtk3.Sdk:3.24.52@sha256:..."
}
```

A runtime can't run by itself, as runtimes have no runtimes of their own,
so GTK 3's demos are an app of their own on both,
**[`org.gtk.Gtk3demo`](recipes/gtk3demo.json)**, as on Flathub: it exports
`gtk3-demo`, `gtk3-widget-factory` and `gtk3-icon-browser`, and adds "GTK 3
Demo" and "GTK 3 Widget Factory" to the Start menu, with icons
[made of GTK's PNGs](recipes/gtk3/png2ico.sh).

GTK 3 is GTK 4's build, with three changes: its install doesn't run
`gio-querymodules` for module directories a Windows build doesn't have;
`gdk-3.0.pc` asks for `-luuid` rather than `-Wl,-luuid`, which zig's `cc`
refuses; and its file chooser, places sidebar and file button handle a
Desktop that isn't there. Windows has no Desktop folder for a run that
isn't given it ([your folders](../README.md#your-folders)), and
GTK 3 took that for a folder at the path NULL. Its demos are built as GUI
programs, so they get the windowless shim. And it maps GTK's SDK's
directory to a fixed name (`-fmacro-prefix-map`): a GLib header GTK
includes names its own file, which is in the SDK's deployment, whose path
differs between stores.

### Gnumeric

[Gnumeric](recipes/gnumeric.json) 1.12.62, a spreadsheet on GTK 3, is
built from its release with goffice 0.10.62 (its charts and file formats'
support), libgsf 1.14.60 (OLE2 and zip containers), libxslt 1.1.45 and
intltool, with GTK's SDKs, CMake for libxslt, and Perl for intltool's
scripts and the build's own. It reads and writes Excel (`.xls`, `.xlsx`),
OpenDocument, its own `.gnumeric` and a dozen other formats, prints to PDF,
and has its solvers and its statistics tools; its settings are in a key
file in its data directory (goffice's `keyfile` backend; on Windows it
would use the registry). It isn't built with its Python, Perl and database
plugins, nor its help, which needs yelp; the Applix plugin is left out, as
its exporter's code isn't in the release.

`ssconvert` converts between formats without a window, and `ssindex`,
`ssgrep` and `ssdiff` search and compare spreadsheets:

```powershell
ssconvert sales.csv sales.xlsx
ssconvert --export-type=Gnumeric_pdf:pdf_assistant sales.xlsx sales.pdf
```

It's offered for `.gnumeric`, `.xlsx`, `.xls`, `.ods` and `.csv` files,
and may use the user's Desktop, Documents and Downloads.

libgsf, goffice and Gnumeric build with their releases' `configure` and
BusyBox's make, like hunspell and enchant above, with more:

- Autoconf's `configure` takes PATH apart at `:` unless told otherwise, as
  BusyBox's sh gives it one where it can't tell `;` is the separator, and
  looks for programs only by their bare names, without `.exe`: so it found
  no `pkg-config` or `windres` by itself. `PATH_SEPARATOR=;` and
  `ac_executable_extensions=.exe` fix both, the latter on `configure`'s
  command line (BusyBox's sh upper-cases the names of variables it's given).
- BusyBox's make has neither GNU make's pattern rules nor `$(shell ...)`:
  [a script](recipes/gnumeric/pdpmake.sh) turns intltool's rules for
  translated files into a POSIX suffix rule and its lists of languages into
  POSIX `!=` assignments (without which no translation was installed), and
  names the source in rules where GNU make's `$<` would have.
- intltool's scripts start `#!/usr/bin/perl`, which BusyBox's sh runs with
  the `perl` on PATH, where a drive letter in the line wouldn't run.
- Strawberry Perl reads files as text on Windows unless told otherwise,
  which drops carriage returns: goffice's script that embeds its images
  into the library broke a PNG. `PERLIO=perlio` reads as Perl does on Unix.
- `-mwindows` is ignored by zig's `cc` (it says so), so Gnumeric links with
  `-Wl,--subsystem,windows` to be a GUI program.
- Gnumeric's plugins are DLLs that GModule looks things up in by name, not
  all of them marked for export: they're linked with
  `-Wl,--export-all-symbols`, which zig's linker takes and ignores, exporting
  only what's marked if anything is. [A header](recipes/gnumeric/export-all.h)
  makes `G_MODULE_EXPORT` mark nothing, so everything is exported, as GNU ld
  does. libspreadsheet, Gnumeric's own library, exports everything that way
  too: the list its build makes from some of its headers misses functions
  `ssconvert` and the Excel plugin use.
- `glib-genmarshal` is a Python script; a `python3` in the build runs it with
  Meson's Python.

### Introspection

GTK's images carry the introspection data that language bindings load
(PyGObject, GJS): each library's GIR file in the SDK's `share\gir-1.0`,
and its typelib in `lib\girepository-1.0` in the SDK and the runtimes. GTK's
have GLib, GObject, Gio, GModule, HarfBuzz, Pango, PangoCairo, cairo,
GdkPixbuf, Graphene, GDK, GSK and GTK 4, libadwaita, libsoup and librsvg;
GTK 3's add ATK, GDK 3 and GTK 3. The runtime keeps GLib's
`libgirepository-2.0`, which loads them.

GTK's SDK builds gobject-introspection 1.86 early, after GLib, cairo and
their libraries, and then GLib again, with introspection, which needs GI's
scanner. GI's scanner is Python: the SDK has Python 3.14.7 in `python`, the
NuGet package of python.org's build (the embeddable one with headers and
`python314.lib`, for the scanner's C module), with setuptools, whose copy
of distutils the scanner uses since Python 3.12 has none. GI's build needs
flex and bison, which are winflexbison's release (MSVC builds its sources
only), on PATH for that module alone. Then:

- [A patch](recipes/gtk4-sdk/gobject-introspection.patch) makes GI's
  scanner work with zig's `cc` outside MSYS2: it treats a `CC` that isn't
  MSVC's as GCC-like, looks for libraries where pkg-config says they are,
  links `libfoo.dll.a` by its path (zig's `cc` doesn't take it for
  `-lfoo`), and reads an import library's DLL name with `nm` when there's
  no `dlltool`. It also has its lexer resolve file names as Python's
  `realpath` does, through a subst drive such as builds' `B:`: otherwise
  what a library's generated headers declare (its enums' types) was left
  out.
- GI installs `g-ir-scanner` with the Python it was built with,
  `B:\prefix\python\python.exe`, in its `#!` line, which is only there while
  the SDK builds; Meson runs scripts by that line.
  [`g-ir-scanner.exe`](recipes/gtk4-sdk/python-script.c) runs the script
  next to it with the SDK's Python wherever the SDK is, and GI's pkg-config
  file names it.
- HarfBuzz is built with its GObject library, which Pango's GIR includes.

GTK 3's SDK sets `GI_GIR_PATH` to its own GIRs, so that a library built on
it (GtkSourceView 4, in Meld's recipe) finds `Gtk-3.0.gir`; GTK's SDK's
are where its scanner looks anyway. Every library's GIR and typelib build
as part of its own build, which makes GTK's SDK take 31 minutes (26
before).

## Python apps

PyGObject, Python's binding of GLib and GTK through their typelibs, comes
as an add-on to GTK's images, like GTK 3's:

- **[`org.gnome.PyGObject.Sdk`](recipes/pygobject-sdk.json)** is built with
  GTK's SDK as its SDK: Python 3.14.7 (the same NuGet package as GTK's SDK
  has), pycairo 1.29.2 and PyGObject 3.58.1, which build with Meson and zig
  against python.org's build of Python. It keeps their headers and
  pkg-config files, and has pkg-config files for Python itself
  (`python3.pc`, `python-3.14.pc` and their `-embed` forms) and a
  `python3.exe`, so Meson's `find_installation('python3')` and
  `dependency('python3')` find it on its PATH.
- **[`org.gnome.PyGObject`](recipes/pygobject.json)** is the runtime, made
  from it. Python keeps its bytecode in the app's data directory
  (`PYTHONPYCACHEPREFIX`), as the runtime's files are read-only, and has no
  user site directory. Its
  [`sitecustomize.py`](recipes/pygobject/sitecustomize.py) names
  multiprocessing's pipes under `\\.\pipe\LOCAL\`, the only place a
  process in an AppContainer may make them, so that multiprocessing works
  in every sandbox. In an AppContainer it also has `os.mkdir(path, 0o700)`
  make a directory as other directories are made: since Python 3.13 that
  mode gives a directory an ACL of its own, for you, SYSTEM and
  Administrators only, which leaves out the container, so `tempfile`'s
  directories were made and then couldn't be written in. The directory takes
  the ACL of where it's made instead, which zigsaw's grants limit to you and
  the container.

A Python app on GTK 3 lists three runtimes and three SDKs, and sets where
its own files, the typelibs and their DLLs are, as [Meld](recipes/meld.json)
does:

```json
"command": "${pygobject}\\pythonw.exe",
"args": ["${app}\\bin\\meld"],
"path": ["bin"],
"env": {
  "PYTHONPATH": "${app}\\Lib\\site-packages",
  "GI_TYPELIB_PATH": "${app}\\lib\\girepository-1.0;${gtk3}\\lib\\girepository-1.0;${gtk}\\lib\\girepository-1.0",
  "PYGI_DLL_PATH": "${app}\\bin;${gtk3}\\bin;${gtk}\\bin",
  "XDG_DATA_DIRS": "${app}\\share"
},
"runtimes": {
  "gtk": "org.gtk.Gtk4:4.24.1@sha256:...",
  "gtk3": "org.gtk.Gtk3:3.24.52@sha256:...",
  "pygobject": "org.gnome.PyGObject:3.58.1@sha256:..."
},
"sdk": {
  "gtksdk": "org.gtk.Gtk4.Sdk:4.24.1@sha256:...",
  "gtk3sdk": "org.gtk.Gtk3.Sdk:3.24.52@sha256:...",
  "pygobjectsdk": "org.gnome.PyGObject.Sdk:3.58.1@sha256:..."
}
```

- `pythonw.exe` is a GUI program, so the app's commands get the windowless
  shim; its script runs with the app's own Python packages on
  `PYTHONPATH`.
- Python doesn't load the DLLs an extension needs from PATH (since 3.8):
  PyGObject adds the directories in `PYGI_DLL_PATH` when it's imported.
  GLib loads a typelib's DLL by its name, from PATH, so a library of the
  app's own needs the app's `bin` there too.
- A library's data is found as in a C app: the app's `share` is in
  `XDG_DATA_DIRS`, after the runtimes' and the extensions'
  ([GTK's data directories](#gtks-data-directories-and-extensions)), so
  GtkSourceView finds its language files in the app's.

A GTK 4 app lists GTK's runtime and PyGObject's (and their SDKs) only, as
[Gaphor](#gaphor) does.

### Packages from PyPI

The runtime has nothing from PyPI but PyGObject and pycairo; an app brings
the rest in its image, with a [vendor step](#vendor-steps) that runs pip
(PyGObject's SDK has pip, from the NuGet package) for wheels pinned in a
requirements file, by version and hash, as a lock file has them:

```json
"vendor": {
  "commands": [
    "python3 -m pip download --no-cache-dir --no-deps --only-binary=:all: --platform win_amd64 --python-version 3.14 --implementation cp --require-hashes -r zigsaw/requirements.txt -d wheels"
  ],
  "dir": "wheels",
  "sha256": "ed244c802320cb87..."
}
```

and the build installs them from there, with no network, and without
bytecode (the runtime's Python keeps it in the app's data):

```sh
python3 -m pip install --no-index --find-links wheels --no-deps --no-compile --require-hashes --target "$PREFIX/Lib/site-packages" -r zigsaw/requirements.txt
```

- `python3` is PyGObject's SDK's: the `python` first on a build's PATH is
  Meson's, which has no pip.
- `--no-deps` with every package listed: what's installed is the
  requirements file, not what pip resolves on the day.
- pip makes a launcher for each command a package declares, which names
  the Python it was installed with by its path, the SDK's deployment in that
  store: the recipe removes them (`Lib\site-packages\bin`) and their lines
  in each package's `RECORD`, or the image differs from store to store. The
  app runs as `python -m <package>` instead.
- The app's own package builds from its source distribution with
  `--no-build-isolation` and its build backend installed beside it from the
  same wheels (Gaphor's is poetry-core), as an isolated build would
  download it.
- Wheels are pure Python where a package has one (`py3-none-any`); one with
  C code comes as PyPI's wheel for CPython 3.14 on x64 Windows, built with
  MSVC by its project, as Python itself is python.org's build.

### Gaphor

[Gaphor](recipes/gaphor.json) 3.3.2 models systems and software in UML,
SysML, C4 and RAAML, on GTK 4 and libadwaita. Its recipe builds:

- GtkSourceView 5.22 with its typelib (Text Editor's has none);
- Graphviz 16.1.0's `dot`, which its auto layout runs, with CMake and zig:
  statically, with its layouts and core output formats built in and all
  its optional libraries off. The release tarball has no CMake files, and
  GitLab's tarball of the tag has a link to a file it doesn't have, which
  zigsaw refuses; GitLab's zip of the tag works (zigsaw takes its links for
  small files). flex and bison are winflexbison's, as in GTK's SDK;
- its 15 packages from PyPI, as above, at the versions its `poetry.lock`
  pins, Pillow's being the one with C code;
- Gaphor from its source distribution on PyPI, which has its translations
  compiled, then its settings schema, compiled into `share`, and its icon.

```json
"command": "${pygobject}\\pythonw.exe",
"args": ["-m", "gaphor"],
"env": {
  "PYTHONPATH": "${app}\\Lib\\site-packages",
  "GI_TYPELIB_PATH": "${app}\\lib\\girepository-1.0;${gtk}\\lib\\girepository-1.0",
  "PYGI_DLL_PATH": "${app}\\bin;${gtk}\\bin",
  "XDG_DATA_DIRS": "${app}\\share",
  "GSETTINGS_SCHEMA_DIR": "${app}\\share\\glib-2.0\\schemas"
}
```

It runs as `python -m gaphor`, not the launcher pip makes, which names the
Python it was installed with by its path. Gaphor looks its schema up in the
first schema source only, which `GSETTINGS_SCHEMA_DIR` makes its own;
otherwise it says its settings won't be saved. It needs no changes: its
Windows support finds GTK's DLLs on PATH. It may use the run's working
directory, Desktop, Documents and Downloads, opens `.gaphor` files, and is
in the Start menu. `gaphor self-test`, which its Windows build runs, passes
in every sandbox (it writes `gaphor-self-test.txt` to the working
directory).

### Meld

[Meld](recipes/meld.json) 3.24.1 compares and merges files and folders,
two or three at a time. Its recipe builds GtkSourceView 4.8.4, the GTK 3
version, with its typelib, and Meld with Meson in its "wheel" form, where
its data (its settings schema, compiled; its styles, resources and
translations) is in its Python package and found from there wherever the
app is deployed. Its help opens on meld.app, as there's no yelp. It may
use the run's working directory, Desktop, Documents and Downloads, and
it's in the Start menu with its own icon. Comparing in version control
views needs `git` on PATH, which Meld's image doesn't have.

Meld's Windows code expects MSYS2 or its own PyInstaller bundle, so the
recipe:

- sets `PANGOCAIRO_BACKEND=win32`, as Meld otherwise asks Pango for its
  fontconfig font map, which GTK's Pango doesn't have, and never draws;
- imports `gi` before Meld loads libintl with ctypes (ctypes doesn't look
  on PATH either), asks for it as `libintl-8`, and gives it the locale
  directory as a wide string (`libintl_wbindtextdomain`): ctypes passes a
  Python string as `wchar_t *`, and libintl read Meld's path as `D`, so
  its windows weren't translated;
- creates the directory of `meld.log` (the app's data `share`), which
  Meld opens without making;
- leaves out `gnome.post_install`, which runs `update-desktop-database`.

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

## .NET

Microsoft's .NET binaries for Windows come under the .NET Library License,
which lets anyone use them to build and test programs, and ship them inside
the programs they build, but not publish them for others to copy. So
.NET's recipes are in [`recipes/no-publish/`](recipes/no-publish/), where
recipes go that must never be pushed to a registry
([`scripts/publish.sh`](scripts/publish.sh) refuses them). Each machine
builds their images from Microsoft's own download, the SDK first, then the
runtime, then apps; a recipe that names them finds them in the store, as no
registry has them:

```powershell
zigsaw build recipes\no-publish\dotnet-sdk.json   # 300 MB from Microsoft; about a minute
zigsaw build recipes\no-publish\dotnet.json       # from the SDK image's files; seconds
zigsaw build recipes\no-publish\pinta.json        # an app on it
zigsaw build recipes\no-publish\files.json        # another; about ten minutes
```

- **[`com.microsoft.dotnet.Sdk`](recipes/no-publish/dotnet-sdk.json)** is
  the .NET SDK 10.0.402's zip: the `dotnet` command, the C#, F# and Visual
  Basic compilers, MSBuild, NuGet, the reference packs, and the runtime. It
  exports `dotnet` and `dnx`.
- **[`com.microsoft.dotnet`](recipes/no-publish/dotnet.json)** is the
  runtime 10.0.13: the SDK image's files ([image source](#images-as-sources))
  without the SDK's own, its packs and templates, so `dotnet.exe`, its host,
  and the three shared frameworks, .NET's, ASP.NET Core's and Windows
  Desktop's (WPF and Windows Forms). Apps list it in their `runtimes`. Its
  layer is 86 MB, for 200 MB of files.

The SDK image's variables keep it to itself:

```json
"DOTNET_ROOT": "${app}",
"DOTNET_CLI_HOME": "${data}\\dotnet",
"ProgramFiles(x86)": "${app}",
"DOTNET_GENERATE_ASPNET_CERTIFICATE": "false",
"DOTNET_ADD_GLOBAL_TOOLS_TO_PATH": "false",
"DOTNET_CLI_TELEMETRY_OPTOUT": "1",
"DOTNET_NOLOGO": "1",
"DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE": "1",
"DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK": "true",
"MSBUILDDISABLENODEREUSE": "1",
"UseSharedCompilation": "false"
```

- `DOTNET_CLI_HOME`: the `dotnet` command's files and NuGet's packages are
  in the data directory (in builds, `B:\data\dotnet`, fresh for each).
  Without it, both find your profile with `SHGetKnownFolderPath`, which a
  run's `USERPROFILE` doesn't move: the command would write into your real
  `.dotnet`, and NuGet keep its packages in your real `.nuget`.
- `ProgramFiles(x86)`: NuGet reads its machine-wide settings from under the
  directory this variable names, and fails without it; zigsaw's runs don't
  pass the machine's. The image's own directory has no settings there, so
  NuGet never reads the machine's (to which Visual Studio can add an offline
  package source), and builds use the same package sources everywhere.
- `DOTNET_GENERATE_ASPNET_CERTIFICATE` and `DOTNET_ADD_GLOBAL_TOOLS_TO_PATH`:
  otherwise the command's first run would add a developer certificate to
  your certificate store, and its tools' directory to your PATH, in the
  registry.
- `DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK`: the first run's check of
  workloads, which can't be installed into an image, would otherwise report
  an issue at the start of every build.
- `MSBUILDDISABLENODEREUSE` and `UseSharedCompilation`: MSBuild's worker
  processes and the C# compiler's server end with the build, rather than
  waiting to serve the next one, which may be another app's run, in another
  sandbox.
- `DOTNET_ROOT`: programs that the SDK starts, or that you run with
  `--command`, find .NET in the image rather than one installed on the
  machine.

Run as an app, the SDK builds the project in the working directory
(`dotnet build`, `dotnet run`), and what `dotnet tool install -g` installs
is a [command on PATH](#commands-installed-while-an-app-runs).

### Apps on .NET

An app built with the SDK runs on the runtime: its `.exe` is the apphost the
SDK makes, which finds .NET where `DOTNET_ROOT` says, and the runtime's
variables set it to the runtime's directory. A .NET module vendors its
NuGet packages, then builds offline from them, as
[`tests/build/dotnet`](tests/build/dotnet) does:

```json
"runtimes": { "dotnet": "com.microsoft.dotnet:10.0.13@sha256:..." },
"sdk": {
  "dotnetsdk": "com.microsoft.dotnet.Sdk:10.0.402@sha256:...",
  "busybox": "net.frippery.busybox:FRP-6075-g169694ebd@sha256:..."
},
"modules": [
  {
    "name": "hello",
    "sources": [{ "path": "hello.csproj" }, { "path": "Program.cs" }],
    "vendor": { "commands": ["dotnet restore --packages vendor"], "dir": "vendor", "sha256": "..." },
    "build": ["dotnet publish -c Release --packages vendor --source \"$PWD/vendor\" -o \"$PREFIX\""]
  }
]
```

- `dotnet restore --packages vendor` downloads the packages the project
  needs into `vendor`, in NuGet's own layout, which is also a package
  source: the build restores from it, without the network, and finds them
  in place. A package's version on nuget.org never changes, and NuGet takes
  the lowest version a reference allows, so the step makes the same files
  each time.
- Packs that `dotnet publish` would download, for a self-contained,
  ReadyToRun or trimmed app, come through the vendor step too. A
  framework-dependent app, as above, needs none: the SDK has the reference
  packs and the Windows apphost.
- Builds reproduce without further settings: the compiler is deterministic
  in SDK projects, and the paths it writes into DLLs and PDBs are on `B:`.
  Two code generators that WinUI projects use aren't: CsWinRT's AOT
  optimizer and its `.winmd` writer ([Files](#files) has what to do).
- MSBuild reads variables as properties, so the module's `env` sets them:
  `"TargetFramework": "net10.0"` rebuilds a project for an older .NET for
  this one, if the project lets the environment set it, as Pinta's does. A
  property the project or its publish profile sets itself wins over the
  environment; such ones go on each command, as `-p:` options.
- A project whose `nuget.config` maps packages to named sources
  (`packageSourceMapping`) can't restore with `--source`, which replaces the
  sources and so their names: the build writes a `nuget.config` whose one
  source is `vendor`.
- NativeAOT isn't available: it links with Visual Studio's linker and C
  runtime libraries.

### Pinta

[Pinta](recipes/no-publish/pinta.json) 3.1.2 is an image editor written in
C#, with GTK 4 and libadwaita through GirCore's bindings. It runs on two
runtimes, .NET's and [GTK's](#gtk): GirCore loads GTK's DLLs by the names
MSYS2 gives them (`libgtk-4-1.dll`, `libadwaita-1-0.dll`), which GTK's
runtime has too, on PATH. It's built from its release tarball, for .NET 10:

- Its project imports, on Windows, a file of its repository's that copies
  GTK's DLLs from MSYS2 into its output, and that its tarball lacks; the
  recipe leaves the import out.
- Its translations are compiled with `msgfmt`, from
  [gettext's image](recipes/gettext.json) in the SDK.
- It looks for its icons and translations in `share`, next to the `bin` its
  executable is in, as its own Windows build lays them out; the recipe moves
  them there.

Explorer offers it for `.ora`, `.png`, `.jpg`, `.jpeg`, `.bmp`, `.tif` and
`.tiff` files. It speaks Windows' display language (.NET's
`CurrentUICulture`), which it also passes on to GTK and libadwaita; a
`LANGUAGE` given with `--env` changes only theirs.

### Files

[Files](recipes/no-publish/files.json) 4.3 is a file manager written in C#
with WinUI 3 and the Windows App SDK 2.5. Its project makes an MSIX package
and nothing else: its code asks the package for its name, version and data
folders (`Windows.ApplicationModel.Package`,
`Windows.Storage.ApplicationData`), which fails in a program that isn't one.
zigsaw doesn't install packages, so the recipe patches Files to run without
one, and builds it from its release tarball:

- [`files/unpackaged.patch`](recipes/no-publish/files/unpackaged.patch)
  adds `Unpackaged.cs`, with classes named `Package`, `ApplicationData` and
  `ApplicationLanguages` in Files' own namespace. C# finds those before the
  ones of the same names that Files' `using` directives import, so most of
  Files' code uses them unchanged. They read the name and version from the
  `Package.appxmanifest` the build copies next to `Files.exe`, put the data
  folders under `%LOCALAPPDATA%\Files Community\FilesDev`, keep the settings
  in `HKCU\Software\Files Community\FilesDev\v1\LocalSettings`, beside the
  keys Files keeps there already, and keep the language override there too.
  The patch also builds Files unpackaged, with the Windows App SDK in its
  own directory; takes Files' own path as the first argument of a launch
  from the command line; loads strings with the Windows App SDK's resource
  loader rather than the package's; and lets a profile have no Libraries
  folder (a zigsaw run's has none).
- [`files/name.patch`](recipes/no-publish/files/name.patch) names it
  "Files - Zigsaw build". It's Files' Dev flavour, as its repository builds
  it: no updater, no crash reports, and the features Files is still working
  on, such as the shelf pane.
- The build is `dotnet publish` of `Files.App.csproj` for x64, ReadyToRun,
  framework-dependent (on .NET's runtime image), without NativeAOT, which
  Files' release builds use and the SDK image can't link. Its
  `Files.App.Server` project is built by an MSBuild task rather than as a
  reference, so it's restored separately; it's an out-of-process server
  Files activates through its package, and doesn't use as it stands.
- `dotnet publish` leaves out most of `Assets`: in a package, Files' images
  come from the package's layout. The recipe copies them in, except
  `Libraries` (the build's own packages) and the other flavours' logos, as
  upstream's release script deletes those.
- Two generators made different files in each build: CsWinRT's AOT
  optimizer, which writes its helper types in a different order each time,
  and the `.winmd` of `Files.App.Server`, with a new module ID. The recipe
  turns the optimizer off (`CsWinRTAotOptimizerEnabled=false`; for a JIT
  app, CsWinRT makes those helpers at run time) and leaves the `.winmd` out
  (Files reads it only to activate the server). The image is then the same
  in two stores.

The vendor step restores both projects for x64: 3.3 GB of packages (the
Windows App SDK and its AI and ML parts, which Files excludes from its build
but NuGet downloads anyway, Win2D, CsWinRT, Sentry), 4.5 minutes; the build
takes 4. The image is 168 MB of files, 61 MB compressed.

It declares `HKCU\Software\Files Community` as a key it keeps, and has the
network, the working directory and the user's six folders. It runs in the
`soft` sandbox only: at low integrity and in an AppContainer, Windows'
storage APIs refuse a program without a package, and Files shows no drives
([findings](findings.md#files)).

## PHP

PHP's images are made from php.net's own Windows build of PHP 8.5 (NTS,
x64), which MSVC builds, and extensions for it are built from source with
zig's clang, which that PHP loads as it loads MSVC's builds:

- **[`net.php.php.Sdk`](recipes/php-sdk.json)** is PHP's zip with its devel
  pack in `dev` (the headers, the import libraries of `php8.dll` and of the
  extensions that are DLLs, `run-tests.php`), the headers and import
  libraries of the libraries PHP ships in `dev\deps`
  ([below](#libraries-php-ships)), and `php-ext`, which builds an extension
  from its sources. Its runtimes are zig, BusyBox and Node, which builds that
  use it get too. It exports `php-ext`.
- **[`net.php.php`](recipes/php.json)** is the runtime: the SDK image's files
  without `dev` ([image source](#images-as-sources)). As an app it exports
  `php`, `php-cgi` and `phpdbg`, with the network and the working directory.
  It has an [extension point](#extension-points), `net.php.php`, which
  PHP's extensions plug into.
- **Extensions**, each an image of its own that, installed, joins every run
  of PHP ([below](#apps-with-extensions)):
  [`net.php.php.APCu`](recipes/php-apcu.json) (APCu 5.1.28),
  [`net.php.php.Xdebug`](recipes/php-xdebug.json) (Xdebug 3.5.3, with
  compression), [`net.php.php.Igbinary`](recipes/php-igbinary.json)
  (igbinary 3.2.17RC1), [`net.php.php.Redis`](recipes/php-redis.json)
  (PhpRedis 6.3.0, with igbinary's serializer),
  [`net.php.php.SSH2`](recipes/php-ssh2.json) (ssh2 1.5.0),
  [`net.php.php.Yaml`](recipes/php-yaml.json) (yaml 2.3.0, with libyaml
  0.2.5) and [`net.php.php.Zstd`](recipes/php-zstd.json) (zstd 0.18.0, with
  libzstd 1.5.7).
- **[`org.getcomposer.composer`](recipes/composer.json)**, Composer on
  PHP's runtime, and **[`org.kanboard.Kanboard`](recipes/kanboard.json)**, a
  web app on it ([below](#composer-and-php-apps)).

PHP needs Microsoft's Visual C++ Redistributable (x64), as php.net's zip
does: its DLLs import `vcruntime140.dll`, and ICU's and intl's
`msvcp140.dll` and `vcruntime140_1.dll`, which runs find in System32, where
the Redistributable puts them. The images don't carry them: the
Redistributable's licence lets you install it, not publish it. Without it,
PHP doesn't start.

The images set `PHPRC` to their own directory, so PHP reads their
`php.ini` and no other (not a `php.ini` in Windows' directory, nor one
`HKLM\SOFTWARE\PHP` names). It is PHP's built-in defaults, as in Docker's
PHP images, plus where the extensions are (`extension_dir="${PHPRC}\ext"`,
in PHP's own syntax for a variable) and which are on: curl, fileinfo, gd,
intl, mbstring, openssl, pdo_sqlite, sqlite3, sodium and zip. OPcache is
built in. PHP's `php.ini-development` and `php.ini-production` are next to
it. HTTPS through streams (`file_get_contents("https://...")`,
`stream_socket_client`) checks with Windows' certificate stores; curl's
OpenSSL has no certificates of its own, nor a setting for Windows' stores
other than one per request (`CURLSSLOPT_NATIVE_CA`), so `curl.cainfo` names
Mozilla's, as curl's project publishes them (`extras\ssl\cacert.pem`,
pinned like any download).

### Extensions

`php-ext build`, in an extension's directory, does what phpize, configure
and nmake do with MSVC:

```
php-ext build [--enable-foo[=...]|--with-foo[=...]|--disable-foo|--without-foo]... [--out DIR] [-j N]
```

- **Node runs the extension's `config.w32`**
  ([`config-w32.js`](recipes/php-sdk/config-w32.js)), with stand-ins for
  the functions PHP's configure gives it (`ARG_ENABLE`, `ARG_WITH`,
  `EXTENSION`, `ZEND_EXTENSION`, `ADD_SOURCES`, `ADD_FLAG`, `AC_DEFINE`,
  `CHECK_LIB`, `CHECK_HEADER_ADD_INCLUDE`, `ADD_EXTENSION_DEP`...), which
  record what to build rather than write a Makefile. The options are
  configure's; without any, the first option `config.w32` declares is on.
  MSVC's flags become zig's where they mean the same (`/D`, `/I`, `/U`,
  `/FI`); the others (warnings, optimization) are left out, with a note. A
  function it doesn't know fails the build, naming it.
- **zig's `cc` compiles the sources**, in parallel, with
  [`zig-php.h`](recipes/php-sdk/zig-php.h) included first (below), and
  links them with `php8.lib`, the libraries PHP's own build links every
  extension with, and those `config.w32` asks for. `AC_DEFINE`s go into a
  `main\config.pickle.h` of the build's own, as phpize writes them into the
  devel pack's.
- **It writes** `php_<ext>.dll`, `conf.d\<ext>.ini` and `about.bat` into
  `--out`: `$PREFIX` in a build, the extension's directory otherwise. The
  `.ini` loads the DLL from `${PHP_EXT_<EXT>}`, a variable the extension's
  image sets to its own directory, and `about.bat`, the image's command,
  says what it is. For extensions that build with this one, it also writes
  the DLL's import library into `lib\` and the headers `config.w32`
  installs (`PHP_INSTALL_HEADERS`) into `include\`.
- `CHECK_LIB` finds Windows' own libraries, those zig has import libraries
  for, and [those PHP ships](#libraries-php-ships).

An extension's image ([`recipes/php-xdebug.json`](recipes/php-xdebug.json)):

```json
"command": "about.bat",
"env": { "PHP_EXT_XDEBUG": "${app}", "PHP_INI_SCAN_DIR": "${app}\\conf.d" },
"extends": { "point": "net.php.php", "version": "API20250925,NTS,VS17" },
"exports": {},
"sdk": { "phpsdk": "net.php.php.Sdk:8.5.11@sha256:..." },
"modules": [
  {
    "name": "xdebug",
    "sources": [{ "url": "https://pecl.php.net/get/xdebug-3.5.3.tgz", "sha256": "...", "strip": 1 }],
    "build": ["php-ext build --with-xdebug --with-xdebug-compression"]
  }
]
```

It's built for the SDK's PHP: another PHP 8.5 loads it, as their extension
API is the same; another minor version refuses it, with PHP's own message.
`extends` names PHP's [extension point](#extension-points) and the build
PHP checks extensions against ("PHP Extension Build" in `php -i`), so a PHP
of another one doesn't get it.

#### Libraries PHP ships

php.net builds PHP with libraries from its own packages
([windows.php.net's deps](https://downloads.php.net/~windows/php-sdk/deps/),
the series `packages-8.5-vs17-x64-stable.txt` names): some are in
`php8.dll`, which exports their functions (zlib, libxml2, libiconv), and
some are DLLs beside `php.exe` (OpenSSL, libssh2, SQLite, libsodium,
nghttp2, libpq, ICU, brotli, GLib, enchant, Cyrus SASL). The SDK has those
packages' headers and the import libraries of the DLLs, pinned, in
`dev\deps`, which `config.w32` knows as `PHP_PHP_BUILD`: an extension built
with them uses the very DLLs PHP loads. (Each package's DLLs are the same,
byte for byte, as those in PHP's zip.)

- `CHECK_LIB` and `CHECK_HEADER_ADD_INCLUDE` look in `dev\deps\lib` and
  `dev\deps\include` after the directories `config.w32` gives, as
  configure looks in `PHP_PHP_BUILD`. `SETUP_OPENSSL`, `SETUP_ZLIB_LIB` and
  `SETUP_SQLITE3` are configure's.
- A library in `php8.dll` (`zlib_a.lib`, `libxml2_a_dll.lib`,
  `libiconv_a.lib`...) is found as `php8.lib`, which every extension links
  with, as PHP has the extension built in; the official build links its
  static library into the extension instead.
- Libraries PHP doesn't ship aren't there: an extension's recipe builds
  them, with zig ([below](#libraries-php-doesnt-ship)).

#### Libraries PHP doesn't ship

An extension's recipe builds the library first, as a module of its own,
into the build's prefix, and `php-ext` looks there before PHP's
`dev\deps`, as php.net's builds find every library in `PHP_PHP_BUILD`:
`$PREFIX\include` is on every compile's include path, and `CHECK_LIB` and
`CHECK_HEADER_ADD_INCLUDE` search `$PREFIX\lib` and `$PREFIX\include`. The
library is static, linked into the extension's DLL, and cleanup leaves its
headers and static library out of the image; its licence stays
([`recipes/php-yaml.json`](recipes/php-yaml.json)):

```json
"sdk": {
  "phpsdk": "net.php.php.Sdk:8.5.11@sha256:...",
  "cmake": "org.cmake.cmake:4.4.4@sha256:..."
},
"cleanup": ["/cmake", "/include", "/lib/libyaml.a", "/lib/libyaml_a.lib"],
"modules": [
  {
    "name": "libyaml",
    "sources": [{ "url": "https://github.com/yaml/libyaml/archive/refs/tags/0.2.5.tar.gz", "sha256": "...", "strip": 1 }],
    "build": [
      "cmake -S . -B out -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=\"$PREFIX\" -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5",
      "cmake --build out",
      "cmake --install out",
      "cp \"$PREFIX/lib/libyaml.a\" \"$PREFIX/lib/libyaml_a.lib\"",
      "cp License \"$PREFIX/LICENSE.libyaml\""
    ]
  },
  {
    "name": "yaml",
    "sources": [{ "url": "https://pecl.php.net/get/yaml-2.3.0.tgz", "sha256": "...", "strip": 1 }],
    "build": ["php-ext build --with-yaml", "cp LICENSE \"$PREFIX/LICENSE\""]
  }
]
```

A library's name is what `config.w32` looks for, as MSVC's builds name
them: yaml's wants `libyaml_a.lib`, MSVC's name for a static library, to
build against a static libyaml (`YAML_DECLARE_STATIC`), so its recipe
copies zig's `libyaml.a` to that name. `CHECK_LIB` also takes zig's
`lib<name>.a` for `<name>.lib`, which is how zstd's finds `libzstd.a`
(`php --ri zstd` then says "Zstd library => external": not the copy it
bundles). Both pass the same tests as php.net's own builds of them.

Extensions that need another extension (`ADD_EXTENSION_DEP`, as redis with
igbinary's serializer) find it by its `PHP_EXT_<EXT>` variable: a recipe
lists the other extension's image as an SDK, whose env sets it, and
`php-ext` takes its headers and import library from there
([`recipes/php-redis.json`](recipes/php-redis.json)).

`php-ext test` runs an extension's tests in the SDK's PHP, with
`run-tests.php` or the extension's own (`--runner`, as Xdebug has one); it
passes the DLL in `TEST_PHP_ARGS` too, for tests that start PHP themselves,
and runs the tests that fail again one at a time, since tests with sockets
fail when many run at once:

```
php-ext test tests --ext php_apcu.dll
php-ext test --runner run-xdebug-tests.php tests --ext php_xdebug.dll
```

Without a recipe, `php-ext build` in an extension's directory makes the
DLL there, and `php -d extension=C:\path\to\php_foo.dll` loads it.

### Apps with extensions

Installed, an extension joins every run of PHP, and of apps that have PHP
as a runtime, through PHP's [extension point](#extension-points): each
adds its `conf.d` to `PHP_INI_SCAN_DIR`, which the point joins, and PHP
loads them in that order, an extension after those it `needs` (redis after
igbinary, whose DLL it links with):

```
zigsaw pull net.php.php.Xdebug
php -r "var_dump(extension_loaded('xdebug'));"
zigsaw run --noextension=net.php.php.Xdebug net.php.php ...
zigsaw override --noextension=net.php.php.Xdebug <app>
```

An app that needs an extension can also list it as a runtime, pinned, and
its `conf.d` in `PHP_INI_SCAN_DIR` (`;` between directories), as
[`tests/php/consumer.json.in`](tests/php/consumer.json.in) does; its own
`conf.d` last, for its settings. Then it has its own copy, and the
installed one of the same id doesn't join:

```json
"command": "${php}\\php.exe",
"args": ["${app}\\check.php"],
"runtimes": {
  "php": "net.php.php:8.5.11@sha256:...",
  "apcu": "net.php.php.APCu:5.1.28@sha256:...",
  "xdebug": "net.php.php.Xdebug:3.5.3@sha256:..."
},
"env": { "PHP_INI_SCAN_DIR": "${apcu}\\conf.d;${xdebug}\\conf.d;${app}\\conf.d" },
"exports": {}
```

They're variables, so the PHP processes the app starts load the same
extensions. The extensions work under the three sandboxes. Xdebug's step
debugger connects to an IDE under `soft` and `low`; in an AppContainer it
can't reach `127.0.0.1` ([known gaps](gaps.md)).

### Composer and PHP apps

[Composer](recipes/composer.json)'s image is `composer.phar` with PHP's
runtime. As an app it exports `composer`, with the network and the working
directory; its home and cache are in its data, as `APPDATA` and
`LOCALAPPDATA` are. As an SDK it gives builds a `composer` alias, which runs
the runtime's `php.exe` with the phar ([aliases](#building-from-source)), so
a recipe installs an app's dependencies from its lock file in a
[vendor step](#vendor-steps), pinned like a download
([`recipes/kanboard.json`](recipes/kanboard.json)):

```json
"runtimes": { "php": "net.php.php:8.5.11@sha256:..." },
"sdk": {
  "composer": "org.getcomposer.composer:2.10.3@sha256:...",
  "busybox": "net.frippery.busybox:...@sha256:..."
},
"modules": [
  {
    "name": "kanboard",
    "sources": [
      { "url": "https://github.com/kanboard/kanboard/archive/refs/tags/v1.2.54.tar.gz", "sha256": "...", "strip": 1 },
      { "url": "https://raw.githubusercontent.com/kanboard/kanboard/<commit>/composer.json", "sha256": "...", "dest": "composer.json" },
      { "url": "https://raw.githubusercontent.com/kanboard/kanboard/<commit>/composer.lock", "sha256": "...", "dest": "composer.lock" }
    ],
    "vendor": {
      "commands": ["rm -rf vendor", "composer install --no-dev --no-scripts --no-interaction --no-ansi --prefer-dist"],
      "dir": "vendor",
      "sha256": "..."
    },
    "build": ["mkdir -p \"$PREFIX/kanboard\"", "cp -r app assets libs vendor cli index.php jsonrpc.php ... \"$PREFIX/kanboard/\""]
  }
]
```

Kanboard's release tarball leaves its `composer.json` and `composer.lock`
out, so the recipe takes them from the tag's commit; it has the
dependencies installed already, which the vendor step replaces with
Composer's own install of the lock file (the same package files; see
[findings](findings.md#composer-and-kanboard)). Two installs, one from
Composer's cache, make the same files.

Kanboard is a web app. Its `kanboard` command
([`serve.php`](recipes/kanboard/serve.php)) runs PHP's built-in web server
on `127.0.0.1:8471` (`--listen=<host>:<port>` for another), with a
[router](recipes/kanboard/router.php) that refuses the directories
Kanboard's `.htaccess` keeps from the web, and opens the page in the default
browser (`--no-browser` doesn't): Explorer opens it, so the browser runs
outside the app's sandbox, and doesn't end with the server. Its Start menu
shortcut runs it, with a console window for the server's log; closing it
stops the server. `DATA_DIR` is the app's data, where Kanboard keeps its
SQLite database and files; `PLUGINS_DIR` is `plugins` in it. `kanboard-cli`
is Kanboard's command line (`kanboard-cli db:version`). It works under
`soft` only: at low integrity PHP's `is_writable()` says no to what the run
may write, and Kanboard refuses its data directory; in an AppContainer the
browser can't reach it ([known gaps](gaps.md)).

### What zig needs to build for MSVC's PHP

PHP's headers expect the compiler that built `php8.dll`, or GCC and clang
building PHP itself. [`zig-php.h`](recipes/php-sdk/zig-php.h) and
[`zig-php.c`](recipes/php-sdk/zig-php.c) bridge the two:

- `php8.dll`'s `ZEND_FASTCALL` functions, and the handlers it calls
  (`PHP_FUNCTION`), are `__vectorcall`, as MSVC builds them, which also
  names them (`_emalloc@@8`). The headers pick it only for `_MSC_VER`;
  `zig-php.h` picks it for clang.
- With `__builtin_constant_p`, which MSVC hasn't, `emalloc` of a constant
  size calls an allocator for that size (`_emalloc_40`), which `php8.dll`
  doesn't have; `zig-php.h` turns that off.
- `zend_string.h` declares `zend_string_equal_val` as one of `php8.dll`'s
  functions for GCC and clang, which have it in assembly; MSVC builds inline
  it. `zig-php.c` gives each extension the pointer its calls go through.
- PHP's Windows headers define what MSVC hasn't and MinGW has: `pid_t` (an
  `int`; MinGW's is 64-bit), `struct timezone`, `gettimeofday`,
  `S_IRUSR`... `zig-php.h` leaves MinGW's out.
- MinGW defines POSIX names MSVC doesn't, and code that tests for them
  takes another branch: Xdebug's default output directory is `P_tmpdir`
  when there's one, MinGW's `"\\"`, the root of the current drive.
  `zig-php.h` removes `P_tmpdir`, `PATH_MAX` and `NAME_MAX`. Others may
  remain.
- `-fms-extensions` gives clang MSVC's intrinsics, which `zend_atomic.h`
  uses (`_InterlockedExchange8`), and makes `__declspec(thread)` thread-local
  storage, which thread-safe builds need (`TSRM_TLS`).
- PHP refuses an extension linked by a newer linker than its own
  ("linked with 14.51, but the core is linked with 14.44"), which rules out
  a newer Visual Studio as much as GNU ld (version 2.x); lld writes 14.0.

The sizes and offsets of PHP's structs, as zig and MSVC 14.44 lay them out,
are the same, except `long double` (16 bytes and 8), which PHP's API doesn't
pass. Thread-safe PHP isn't packaged.

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
