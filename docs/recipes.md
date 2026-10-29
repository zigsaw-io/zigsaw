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
another `image` (see [images as sources](#images-as-sources)). Every URL the
store's download cache doesn't have is downloaded before anything else, eight
at a time; after a download fails, no further one starts. A source
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

`env` values and arguments can also name `${roots}`: a PEM file of the roots
Windows trusts, which zigsaw writes for runs and builds that name it, for
programs that take only a file of roots, as OpenSSL's does through
`SSL_CERT_FILE` ([certificate trust](networking.md#certificate-trust)).
Perl's recipe has it:

```json
"env": { "SSL_CERT_FILE": "${roots}" }
```

PATH entries in `${data}` are also where the app's runs install commands,
which then get shims (see
[commands installed while an app runs](#commands-installed-while-an-app-runs)).

## Sandbox

An app's runs are low integrity unless something chooses another sandbox
([sandboxes](../README.md#sandboxes)). An app that can't work at low
integrity asks for `soft` in its permissions, as Kanboard's recipe does (PHP
tells it it can't write its data there). So does a toolchain's, one that
builds or installs programs where it's run (zig's, Rust's, Node's, the
SDKs'): Windows starts a program whose file is labelled low at low
integrity, and what a low-integrity program writes is labelled low.

```json
"permissions": { "sandbox": "soft", "network": true }
```

- `pull`, `update` and `info` show it as access ("whatever you can write"),
  so an update that newly asks for it asks first.
- Overrides and a run's `--sandbox` choose over it, as for any permission.
- A recipe may ask for `appcontainer` too, or `low`, which is what no
  `sandbox` means. Without it, the image's config has no `sandbox`, so
  images that don't ask keep their digests.
- A zigsaw before 0.54 ignores it, and runs every app under `soft`.

## Services

An app that other programs on this machine connect to declares what it
serves, with the export that serves it, as PostgreSQL's recipe does:

```json
"env": { "PGPORT": "${listen:postgresql}" },
"permissions": {
  "network": true,
  "services": [{ "name": "postgresql", "port": 5432, "command": "postgresql" }]
}
```

Each service gives the app's `env`, `args` and export arguments two
placeholders:

- `${listen:<name>}`: where the app listens, and where its own runs connect.
- `${port:<name>}`: where other programs reach it, for an address the app
  prints or opens. Kanboard's opens `http://127.0.0.1:${port:http}/`.

Under `soft` and `low`, both are the service's port, or the one
`--port=<name>=<port>` or an override gives. Under `--sandbox=appcontainer`,
nothing outside the container can connect into it, but the app's runs reach
each other on the loopback ([networking](networking.md)):

- `${listen:<name>}` is an internal port of the app's, picked on its first
  run there and kept in the store's `ports\<id>.txt`, so that all its runs
  agree.
- A run of the export that serves it publishes the service. So does a run
  of the app's own command, when it runs the same program with the same
  arguments.
- zigsaw listens on the service's port, on 127.0.0.1 and ::1, outside the
  container. It hands those sockets to `zigsaw-relay.exe`, which it starts
  in the app's container and job, with no network capability. The relay
  passes each connection on to the internal port, and ends with the run.
- If the port is taken, the run says so and goes on unpublished.

`command` names an export; without it, the app's own command serves. Names
are lowercase letters, digits and `-`, and each service has a port of its
own. A service doesn't need the `network` permission, which is about what
the app may reach. `info`, and what `pull` shows before it asks, list the
services.

## Ports an app uses

An app that connects to a server on this machine declares the port, as
osm2pgsql's recipe does for PostgreSQL's:

```json
"env": { "PGPORT": "${uses:postgresql}" },
"permissions": {
  "network": true,
  "uses": [{ "name": "postgresql", "port": 5432 }]
}
```

`${uses:<name>}` is where the app connects for it, in its `env`, `args` and
export arguments:

- Under `soft` and `low`, it's the port, or the one
  `--port=<name>=<port>` or an override gives.
- Under `--sandbox=appcontainer`, a run with the network has its container
  exempt from loopback isolation while the app's runs go, where Windows lets
  zigsaw do that, and so it's the port there too.
- In a container that isn't exempt (no network, Windows refused, or
  `ZIGSAW_LOOPBACK_EXEMPTION=0`), it's a port of the run's relay, inside the
  container. For each connection there, zigsaw connects to the port outside
  the container and hands that connection in (`zigsaw-relay.exe`,
  [networking](networking.md)).

So a declared port is reached in every sandbox, with the network or
without. Nothing else on this machine is reached from a container that
isn't exempt: an app given another port of its own (`-P`, say) bypasses
the forward.

Runtimes and extensions declare the ports they use in the same way, and
those join the runs of apps that have them: Xdebug's image uses `dbgp` on
9003, and its `.ini` reads `xdebug.client_port` from a variable its image
sets from `${uses:dbgp}`. A runtime's or extension's `${uses:x}` names one
of its own; an app's may also name one of its runtimes'. When two use the
same name, the app's wins, then its runtimes' and its extensions' in order.
Names are those of services too, for `--port`. `info`, and what `pull`
shows before it asks, list the ports an app and its runtimes use, and an
update that uses another one asks first.

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
is an edit to its recipe, like a new source hash. Apps that pin different
builds of a runtime each bring their own, deployed side by side;
[`scripts/check-pins.sh`](scripts/check-pins.sh) warns about a published
recipe whose runtime pin isn't what that runtime's tag points to now, and
fails if the registry lacks an image a published recipe pins.

Any image can be a runtime, a tool's as well: [Meld](recipes/meld.json)
lists MinGit's image as `git`, so `git` is on the PATH of Meld's runs, with
MinGit's `env`, and nothing is copied into Meld's image:

```json
"runtimes": {
  "pygobject": "org.gnome.PyGObject:3.58.1@sha256:...",
  "git": "org.git_scm.MinGit:2.56.0.windows.1@sha256:636d59bc02546599..."
}
```

A runtime's permissions don't carry over: the app's own apply.

## Extension points

Some images are made to be added to a runtime after the fact, as a
Flatpak runtime's extensions are: PHP's extensions to PHP, GTK's
dictionaries, and [PostgreSQL's extensions](#postgresql-extensions) to its
server. A runtime (or
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
  leave running. `SOURCE_DATE_EPOCH` is fixed at 1980-01-01, and
  `ZIG_PROGRESS` is `off`: zig 0.16 can hang drawing its progress line on a
  console (docs/findings.md).
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
runtime it builds on first use there, about 30 s of work (minutes on a
runner). `${cache}` is only for caches that are safe to keep, being keyed by
the contents of their inputs: a build with a warm cache must make the same
image as one without. Whatever else a tool keeps in its profile folders is
still fresh in each build.

The objects zig compiles are **not** kept between builds: each module's
`ZIG_LOCAL_CACHE_DIR` is its own `B:\src\<module>\.zig-cache`, as `zig build`
has by default, so it's fresh for each build unless the module keeps its work
directory (see [incremental builds](#incremental-builds)). Until iteration
36 they were kept, in `${cache}`, and that wasn't safe: a cached object
comes back without the warnings clang gave when it compiled it, so a
build script that checks a flag compiles without any warning (cc-rs's
`is_flag_supported`, as BLAKE3's does for AVX-512) answers otherwise once the
check is cached. cargo-c built two different images in the same store that
way (docs/findings.md).

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
([Python apps](#packages-from-pypi)), or `zig build --fetch`
([Zig](#zig)). It relies on the tool
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
"sdk": { "zig": "org.ziglang.zig:0.17.0@sha256:93ec2b6b36708ae8..." },
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

### Incremental builds

A module whose sources include a project's own files keeps its work
directory, `B:\src\<module>`, between builds, as makepkg keeps `src/`. So
whatever its build leaves there is still there the next time: zig's
`.zig-cache`, CMake's or Meson's build directory, cargo's `target`.

- **Its sources are brought up to date in it.** A file whose contents
  differ from the source's is written again, whether the project changed it
  or the last build edited it in place (a `sed -i`, which then edits a fresh
  copy, as in a first build). A file the project no longer has is deleted.
  The other files are left as they are, timestamps and all, so make, ninja
  and cargo see only what changed as new.
- **It starts afresh** when zigsaw, the recipe, or the recipe's other local
  files change, as their builds' state may no longer hold, and with
  `zigsaw build --clean`, which also builds when nothing changed.
- **The rest of the build is as fresh as ever**: `B:\prefix`, `B:\home` and
  `B:\data` are new in each build, and a [vendor step's](#vendor-steps)
  module, one without build commands, and a recipe's modules with only
  pinned sources, as every published recipe's, never keep one.
- **It's kept in the store**, under `cache\work\<key>\<module>`, keyed by
  the recipe's path and the app's id, so two checkouts don't share one. It
  moves into the build root for the build, and back afterwards, a failed
  build's too, as make leaves what it made. `--keep-build-dir` leaves it in
  the kept build root, and the next build starts afresh. `zigsaw prune
  --downloads` deletes them.

An incremental build should make the image a `--clean` build of the same
files makes, as `${cache}` should; how far it does is up to the project's
tools, whose incremental state it is. zig's is keyed by contents. For
zigsaw's own, [`tests/self.sh`](../tests/self.sh) checks that a build after a
change makes the bytes a `--clean` build and a plain `zig build -Dstrip`
make.

A project's own [vendor step](#vendor-steps) works as any other: `cargo
vendor` in the module's directory, with the project's files. The installed
app records where its recipe is, so `zigsaw update <app-id>` builds it again
from the directory as it is then.

## Zig

A Zig project builds with `zig build` from [zig's image](#building-from-source),
which the recipe lists as an SDK, or as a runtime if the app runs zig too
(both are on the build's PATH). Three options keep its image the same
wherever it's built:

- **`-Dtarget=x86_64-windows-gnu`**: `zig build` targets the build
  machine's own Windows by default, and zig 0.17 writes its version into
  the program (ZLS 0.17.0 built on Windows 11 and on CI's Server 2025
  differed in those bytes only). A target named gives zig's own range
  instead. zigsaw's build.zig names the OS itself.
- **`-Dcpu=baseline`**: `zig build` targets the build machine's own CPU by
  default, so the program, and the image, would depend on where it was
  built (and might not run on an older CPU). zigsaw's own releases are
  built this way too.
- **`--system zig-pkg`**, after a vendor step, for a project with
  dependencies. zig 0.16 unpacks a project's packages into `zig-pkg`, beside
  its `build.zig.zon`, each in a directory named after its hash; that's the
  step's `dir`. `--system` turns fetching off and reads them from there:

```json
"vendor": {
  "commands": ["zig build --fetch"],
  "dir": "zig-pkg",
  "sha256": "4f200d86b78e8b6b..."
},
"build": ["zig build --system zig-pkg -Doptimize=ReleaseSafe -Dtarget=x86_64-windows-gnu -Dcpu=baseline -p \"$PREFIX\""]
```

`--fetch` leaves out lazy dependencies the build doesn't need;
`--fetch=all` takes them too. zig also keeps a compressed copy of each
package in its global cache, which is zig's [tool cache](#building-from-source)
in builds: don't vendor that (`--global-cache-dir vendor`, say), as the
build looks in `zig-pkg`, and only the step's `dir` is pinned.

### ZLS

[ZLS](recipes/zls.json) 0.17.0, the Zig language server, is built from its
GitHub tag this way, with zig 0.17.0: its three packages (known-folders,
diffz, lsp-kit) are fetched by the vendor step, and
`-Dversion-string=0.17.0` saves its build a
`git describe`, which a tarball can't answer.

- **zig's image is its runtime**, with `${zig}` on its PATH. ZLS finds
  `zig.exe` there, and zig's library beside it, for the standard library's
  completions and documentation, and runs zig to learn the modules and
  packages a project's `build.zig` declares. zig's version must be one ZLS
  supports: 0.17.x for ZLS 0.17.
- **It has the working directory**, which editors start it in, as the
  project's folder. For files elsewhere, `zigsaw override
  --filesystem=<dir> org.zigtools.zls`, as the editor starts it through its
  shim.
- **Its configuration, cache and log are in its data**: `zls.json` goes in
  `<data>\home\AppData\Local` (`zls env` says where, per sandbox).
- **In an editor**, the language server's path is the `zls` shim in the
  store's `bin`, e.g. VS Code's Zig extension's `zig.zls.path` setting
  (with `zig.zls.enabled` on). It talks over stdin and stdout, which the
  shim passes straight through.

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

CMake finds nothing the machine has installed. Kitware's
`Modules/Platform/WindowsPaths.cmake` adds `%SystemDrive%\Program Files`
and `Program Files (x86)` to the prefixes every `find_*` searches (from
`SystemDrive`, which builds have, when `ProgramFiles` is missing): a
runner's PostgreSQL there went into Qt's SQL plugins, and this machine's Git
into Flameshot's configure. The image replaces that file with
[`cmake/WindowsPaths.cmake`](recipes/cmake/WindowsPaths.cmake), which
leaves them out, turns CMake's package registries (`HKCU` and `HKLM`
`Software\Kitware\CMake\Packages`) off, and keeps FindPython from taking a
Python from the registry, unless a project sets those variables itself.
Prefixes given with `CMAKE_PREFIX_PATH` or `<Package>_ROOT`, and programs on
PATH, are found as before. Recipes pinned to the image from before iteration
40 (`fdc6a6bb`) still have Kitware's file.

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

## GNU make

BusyBox's `make` is pdpmake, POSIX make with a few extensions, which runs
most autotools builds but not Makefiles written for GNU make
(`$(patsubst)`, `$(foreach)`, `define`, `$(call)`), such as PostgreSQL's
pgxs. [`org.gnu.make`](recipes/make.json) is GNU make 4.4.1, built with
zig from the files `build_w32.bat` compiles, with no configure. Builds that
list it get `make` (and `gmake`) as an [alias](#building-from-source), ahead
of BusyBox's applet.

On Windows, GNU make runs recipes in the first `sh.exe` on PATH, or in
cmd.exe without one. The image's `bin` has an `sh.exe`
([`sh.c`](recipes/make/sh.c)) that runs `busybox.exe sh` with its command
line, so recipes run in BusyBox's sh. GNU make also starts a line without
shell syntax itself, as on Unix, where `echo` and `mkdir` are programs; on
Windows they're BusyBox's applets, so
[`posix-shell.patch`](recipes/make/posix-shell.patch) has every line go
through the shell when it's a POSIX one. The builder looks for an `sh.exe`
on the build's PATH before `busybox.exe`, so with this image it runs the
build commands through it too, one process more per command.

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
  [without a recipe](#building-without-a-recipe).
  - It's built in two halves, so CI builds them at once. The first,
    **[`org.gtk.Gtk4.Sdk.Base`](recipes/gtk4-sdk-base.json)**, holds the
    SDK's modules up to and including GTK. The SDK takes its files as an
    image source, then builds the rest: the icon themes, libadwaita,
    libsoup's stack, librsvg and enchant. Each module sees the same
    `$PREFIX` it would in one build, so the SDK's files are what one build
    makes, byte for byte.
  - The base has the SDK's SDKs and runtimes too, so its modules build with
    the same tools. It exports nothing; build against the SDK.
  - The SDK repeats the base's first module (crt-noexport, below), whose
    object its other modules link, since a module's own directory isn't
    in an image.
  - Each half takes about 20 minutes here from scratch, once gettext's
    image is there; on a 4-CPU runner, one build took 57.
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
  BusyBox's `make` runs one command at a time, as for OpenSSL above, so the
  recipe's first module writes a `$(MAKE)` for the other two, `pmake.sh`.
  In each directory, when make gets to automake's `all-am`, the wrapper
  runs the compile commands `make -n` lists, `$(nproc)` at a time, and make
  then links what they made. By then the directory's `BUILT_SOURCES` exist,
  gnulib's replacement headers among them: an object compiled earlier could
  include another header of the same name. The wrapper first makes the
  `.dirstamp` files that objects in subdirectories depend on, or make
  would find them newer and compile those objects again. gettext installs
  with BusyBox's `install` (`INSTALL="install -c"`), as configure finds
  none and falls back to automake's `install-sh`, a script run for each of
  its 2,200 files. A build command writes the wrapper, and isn't a file of
  the recipe's, because an image records the files its recipe adds to a
  build: gettext's image is the same as before (`f3f85ba5`).
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

## Qt

Qt 6 comes as two images too, built from source with CMake, Ninja and zig:

- **[`io.qt.Qt6.Sdk`](recipes/qt6-sdk.json)** builds Qt 6.12.0's Widgets
  set and QML: qtbase (Core, Gui, Widgets, Network, Sql, PrintSupport,
  OpenGL, Concurrent, Xml, Test), qtsvg, qtimageformats (TIFF, WebP, TGA,
  ICNS, WBMP), qtshadertools, qtdeclarative (QML and Qt Quick), qttools
  (Qt Widgets Designer, Qt Linguist, Pixeltool, qtdiag, `lupdate` and
  `lrelease`) and qttranslations. qtbase uses its own copies
  of zlib, libpng, libjpeg, HarfBuzz, FreeType, PCRE2, md4c and SQLite, so
  the Qt family needs nothing from GTK's; TLS is Schannel's, Windows' own.
  Its runtimes are zig, CMake and BusyBox, so builds that use it get CMake
  and Ninja without naming them, and it exports their commands, Qt's
  `qmake`, `qtpaths`, `lupdate` and `lrelease` (Designer and Linguist come
  from the runtime: the first app installed keeps a command's name, and the
  runtime's Start menu shortcuts run its own), and sets
  `CMAKE_PREFIX_PATH` to itself, so it builds Qt programs
  [without a recipe](#building-qt-programs-without-a-recipe). Since
  iteration 40 it's built in two halves, as GTK's is, so that CI builds them
  at once: [`io.qt.Qt6.Sdk.Base`](recipes/qt6-sdk-base.json) builds
  qtbase, qtsvg, qtimageformats and qtshadertools, and the SDK takes the
  base's files as an [image source](#images-as-sources) and builds
  qtdeclarative, qttools and qttranslations on them. From scratch here the
  base takes 25 minutes (most of it qtbase's 1,900 build steps), and the SDK
  on it 26 (qtdeclarative takes 14, and its second pass 2.5; they took 48,
  32 and 7.5 before its unity build, in iteration 42).
- **[`io.qt.Qt6`](recipes/qt6.json)** is the runtime: the SDK's files as an
  [image source](#images-as-sources), without the headers, libraries, CMake
  files and build tools (QML's too), in seconds: 153 MB (56 MB compressed;
  75 and 29 before QML and Qt Quick, 163 and 59 with the Quick Controls
  styles left out since iteration 42). Apps list it in
  their `runtimes`. As an app, it runs Designer, exports `designer`,
  `linguist`, `pixeltool`, `qml` and `qtdiag`, adds "Qt Widgets Designer"
  and "Qt Linguist" to the Start menu, and keeps their settings
  (`HKCU\Software\QtProject`) with its data.

An app built against Qt, as [`tests/qt`](tests/qt) is:

```json
"command": "bin/hello-qt.exe",
"path": ["bin"],
"runtimes": { "qt": "io.qt.Qt6:6.12.0@sha256:..." },
"sdk": { "qtsdk": "io.qt.Qt6.Sdk:6.12.0@sha256:..." },
"modules": [
  {
    "name": "hello",
    "env": { "LDFLAGS": "-s -Wl,-Brepro" },
    "sources": [{ "path": "CMakeLists.txt" }, { "path": "hello.cpp" }],
    "build": [
      "cmake -S . -B out -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=\"$PREFIX\" \"-DCMAKE_RC_FLAGS=/:auto-includes gnu\"",
      "cmake --build out",
      "cmake --install out"
    ]
  }
]
```

`find_package(Qt6 ...)` finds the SDK through `CMAKE_PREFIX_PATH`. When the
app runs, Windows finds Qt's DLLs on PATH, in the runtime's `bin`, and Qt
finds its plugins and translations from where `Qt6Core.dll` is: a Qt built
for `B:\prefix` is relocatable. Qt's own programs in the runtime's `bin`
would take `bin` for the prefix (Qt thinks a program beside `Qt6Core.dll`
was deployed with windeployqt, unless `lib\libQt6Core.a` is there, which
the runtime leaves out), so the runtime has a `bin\qt.conf` with
`Prefix = ..`. QStandardPaths finds AppData through the profile, so an app's
files are in its data directory; QSettings' default, though, is the
registry, which apps keep apart only for the keys their image declares
([registry](#registry-settings-kept-with-the-app)). Qt apps run in all
three sandboxes.

Building Qt with zig needed these, in
[`qt6-sdk/qtbase.sh`](recipes/qt6-sdk/qtbase.sh) and the recipe:

- **Two import libraries zig's MinGW lacks**, `synchronization`
  (`WaitOnAddress`, for QtCore's futex) and `runtimeobject` (WinRT's
  activation and HSTRING functions), made by
  [`qt6-sdk/winlibs.sh`](recipes/qt6-sdk/winlibs.sh) as the import
  libraries of stub DLLs named after the system DLLs that have the
  functions (`api-ms-win-core-synch-l1-2-0.dll`, `combase.dll`), and found
  with `-L`. QtCore no longer passes `runtimeobject` on to apps, which only
  QtCore calls.
- **A GUI program's subsystem.** CMake makes a `WIN32_EXECUTABLE` a GUI
  program with `-mwindows`, which zig's `cc` ignores: Designer, and every
  app's window, came with a console. QtCore now asks executables with
  `WIN32_EXECUTABLE` that link it for `-Wl,--subsystem,windows`, so apps get
  it too, through Qt's CMake files.
- **The manifest's `.rc`.** Qt embeds an executable's manifest with a
  one-line resource script that names the file unquoted; zig's `rc` read
  `lrelease-pro_internal_qt.manifest` as `lrelease` and an expression.
  Quoted, names with a `-` work (Flameshot's `flameshot-cli` has one).
- **An include** `qthread_win.cpp` relied on MSVC's headers for (`qspan.h`).
- **Named pipes in an AppContainer.** A process in one may create named
  pipes only in its own namespace, `\\.\pipe\LOCAL\`, so QLocalServer
  couldn't listen, and an app's single-instance check (Flameshot's
  KDSingleApplication) failed and quit it. In an AppContainer, QLocalServer
  and QLocalSocket now use that namespace for names that aren't pipe paths
  ([a patch](recipes/qt6-sdk/qlocalserver-appcontainer.patch)).
- **Reproducibility:** no SBOM (it has its creation time), no `qt-cmake.bat`
  and the like (they name the build's CMake by its path in the store),
  pkg-config files with `prefix=${pcfiledir}/../..`, not `B:/prefix`, and
  `-DCMAKE_SYSTEM_VERSION=10.0.26300` on every module. CMake takes the
  version of the Windows it runs on, and Qt writes it into each of its
  `modules/*.json`, so a runner on Windows Server 2025 (10.0.26100) built
  other files than here (iteration 41). The value is the one the halves
  were published with, not the build machine's: it changes nothing else
  when not cross-compiling. Apps' recipes don't need it, as nothing they
  install records it.
- **Sources from GitHub's mirror** of each module's tag, not download.qt.io,
  which sends each machine to a mirror near it (zigsaw's fetch failed to
  set up TLS on the way here). The archives are git's files, so a module's
  git submodules are empty: Assistant's HTML viewer (qlitehtml) is one, and
  Assistant, with no documentation built to read, is left out.

Since iteration 40 the SDK has QML and Qt Quick too: qtshadertools (`qsb`,
with its own glslang and SPIRV-Cross) and qtdeclarative (QML with its JIT,
Qt Quick, Quick Controls, Quick Dialogs, Layouts, Shapes, Effects and
QQuickWidget). Quick Controls has the styles Windows uses (Basic, and
Fusion, Windows and FluentWinUI3 on it) and Material and Universal, which
apps choose (Notes does); since iteration 42 the Imagine style and Qt Labs
StyleKit, a styling framework still in Qt Labs, are left out
(`-DFEATURE_quickcontrols2_imagine=OFF`, `..._stylekit=OFF`): they took a
twelfth of qtdeclarative's build, and 9 MB of the runtime.

qtdeclarative is built as a unity build (`-DQT_UNITY_BUILD=ON`, which
Qt's CI builds too): CMake compiles its C++ files 32 to a file, so each
batch parses Qt's headers once. With that and the two styles out, its build
went from 32 minutes here to 14, and from 712 minutes of CPU time to 258;
the files it makes differ, but build the same from store to store.

qtdeclarative's build runs a Python script, so its module unpacks Python's
embeddable zip, which stays in the build. Its module builds twice: qmlcachegen compiles a module's QML to C++
as far as it knows the types, and Qt's build doesn't wait for the other
modules' type information, so what it compiled depended on the order Ninja
ran things in; the second build generates all the compiled QML again, with
every type known ([findings](findings.md#cmakes-search-paths-and-qt-quick-iteration-40)). Qt Quick draws with Direct3D 11, compiling its shaders when it runs
with Windows' own `d3dcompiler_47.dll`. Linguist, whose interface is Qt
Quick, is built again; the runtime exports it and the `qml` tool, which runs
a `.qml` file, and adds "Qt Linguist" to the Start menu. qmlls isn't built
(it needs qtlanguageserver). An app's QML modules, as
[`tests/qt/quick`](tests/qt/quick)'s, are compiled into it with
`qt_add_qml_module`; Qt's own come from the runtime's `qml` folder, which Qt
finds from `Qt6Core.dll` as it finds its plugins.

zig links its libc++ into each DLL and
program, so Qt's 14 DLLs in the runtime each have their own copy: exceptions,
`dynamic_cast` and `typeid` work across them (libc++ compares type names on
Windows), and so do `std::string`, `std::function` and `thread_local`, as a
probe found before Qt was built ([findings](findings.md#qt-6-with-zig-iteration-39)).

### Building Qt programs without a recipe

With the store's `bin` on PATH, the SDK's `cmake` builds a Qt project, with
its Ninja, zig's `c++` and `rc`, and finds Qt:

```
zigsaw pull io.qt.Qt6.Sdk
cd C:\work\hello
cmake -S . -B out -DCMAKE_BUILD_TYPE=Release
cmake --build out
zigsaw run --command=C:\work\hello\out\hello-qt.exe io.qt.Qt6
```

### Flameshot

[Flameshot](recipes/flameshot.json) 14.0.0, a screenshot tool, builds
against the SDK with CMake and runs on the runtime, from its tray icon or
the command line: `zigsaw run org.flameshot.Flameshot full --path <dir>`
saves a screenshot of the whole screen and exits. It may use your Pictures
folder, where it saves by default. Its libraries come pinned, in place of
what its CMake would fetch with git: Qt-Color-Widgets (a commit, put where
its CMake looks first), KDSingleApplication 1.2.0 (the same), and QHotkey,
which it fetched from `master` (pinned at that branch's commit when 14.0.0
came out, given with `FETCHCONTENT_SOURCE_DIR_QHOTKEY`). Its update check
and Imgur upload are off. Its `flameshot-cli.exe`, a console program that
runs `flameshot.exe` through cmd.exe, sizes its command line by
`sizeof(std::wstring)`, about 80 characters, which a path in the store
exceeds, so the image leaves it out; `zigsaw run` gives `flameshot.exe`
the console's output already. Its settings are in an INI file in AppData,
so in its data directory. Its "Launch at startup" does nothing at low
integrity; under `soft` it writes your real `HKCU\...\Run`, naming its
deployment, not its shim.

### Notes

[Notes](recipes/notes.json) 2.3.1 (`io.github.nuttyartist.notes`, Flathub's
id), a note-taking app for Markdown with folders, tags and a kanban board of
a note's to-do lists, builds against the SDK with CMake and runs on the
runtime. Its kanban board and settings are QML (compiled into it with
`qt_add_qml_module`), drawn by Qt Quick next to its Widgets. Its two git
submodules (qautostart and qmarkdowntextedit) come pinned at the commits the
tag names, and its update checker is off. Its default `PRO_VERSION=ON` is
the free build with every feature and no licence check; off, it's the paid
store build, which asks lemonsqueezy.com about a licence. 2.3.1 predates Qt
6.10, which wants `CorePrivate`, `GuiPrivate` and `WidgetsPrivate` asked for
by name: the recipe adds them to its components. Its notes database and
settings are in AppData (`Awesomeness\notes.db`), so in its data directory,
and it may use your Documents folder, where it exports notes.

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
- **Python's own image, [`org.python.python`](recipes/python.json)**,
  python.org's embeddable distribution, has the same `sitecustomize.py`, and
  a [`python314._pth`](recipes/python/python314._pth) of its own that turns
  on `import site`: embeddable Python runs `site`, and so
  `sitecustomize.py`, only then. Its standard library is a zip, which one
  loader loads every module of, so `sitecustomize.py` wraps the loader of
  `multiprocessing.connection` rather than patching it. With `site`, it also
  has a user site directory, in the app's data, so `pip install --user`
  would find a place there. The recipe has no build commands: its second
  module places the two files over the zip's.

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
it's in the Start menu with its own icon. Its version control views run
`git`, which it gets from [MinGit](recipes/mingit.json)'s image, listed as
one of its runtimes (see [Runtimes](#runtimes)): a folder in a git
repository shows its changes, in every sandbox.

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
- `GOCACHE=${cache}`: compiled packages are kept between builds. Go's cache
  keeps a compile's output with its result, and shows it again; the C code
  of cgo is compiled by zig, with the module's own cache.

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

### The OCI tools

[`recipes/oras.json`](recipes/oras.json),
[`recipes/skopeo.json`](recipes/skopeo.json) and
[`recipes/cosign.json`](recipes/cosign.json) build ORAS, skopeo and cosign
as fzf is built, from their module zips, with cgo off, and the version
details their own release builds stamp in: ORAS's commit, cosign's version,
commit and build date (the tag's commit's date, so that the image is the same
whenever it's built). [tests/oci.sh](../tests/oci.sh) runs all three against
the tests' zot registries.

- **skopeo** builds with the tags its Makefile uses without cgo,
  `exclude_graphdriver_btrfs containers_image_openpgp`: signatures are
  checked with a Go OpenPGP library instead of GPGME, and there's no
  `containers-storage:` transport, which is Linux's. It won't copy an image
  without a policy, which it looks for in `%APPDATA%\containers\policy.json`
  and then `C:\ProgramData\containers\policy.json`, so its image brings one
  that accepts any image, as Linux distributions' packages do, and its
  `CONTAINERS_POLICY_JSON` names it. `--policy` gives another. It takes
  zigsaw's images, whose config is zigsaw's own rather than an image config,
  for artifacts: `inspect` refuses them, `inspect --raw` and `copy` don't.
  On Windows its `oci:` transport takes a tag only after an absolute path
  (`oci:C:\images\layout:1`); `oci:layout` without one works.
- **skopeo's and cosign's vendor steps keep only what their command builds
  from**, as zot's does: skopeo's 32 MB of 46, cosign's 103 MB of 130
  (cosign's cloud key services are most of what remains). ORAS's is
  `go mod vendor`'s 12 MB.
- **cosign 3 signs with a key without the internet** given a signing config
  that names no services, which `cosign signing-config create --out
  signing-config.json` makes; otherwise it fetches Sigstore's from its TUF
  repository. `--tlog-upload=false` alone is refused now. Verifying with the
  key needs `--insecure-ignore-tlog`. Its signatures go to the registry as
  OCI referrers, not `sha256-....sig` tags, and zigsaw pulls a signed image
  as before. PKCS#11 tokens and PIV keys need cgo, so they're left out.
- **Logins are each app's own.** ORAS and cosign keep them in
  `.docker\config.json` and skopeo in `.config\containers\auth.json`, in the
  app's home, its data: not zigsaw's logins, nor Docker's. With no
  credential helper on their PATH, they keep the password there unencrypted
  (base64), as Docker does without one. cosign has no `logout`:
  `cosign login` writes the same file as Docker's, and removing the
  registry's entry there logs it out.

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
- CsWinRT reads Windows' types from the Windows SDK installed on the
  machine, by its version, which fails where there's none. A recipe gives
  it a directory of `.winmd` files from NuGet instead, with
  `-p:CsWinRTWindowsMetadata=`, as [Files](#files) does.
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
- CsWinRT, which writes the C# code for Files' own WinRT types and those it
  uses from the Windows App SDK, reads Windows' types from the Windows SDK
  installed on the machine. Files' projects give it a version
  (`CsWinRTWindowsMetadata`, `10.0.26100.0`), and CsWinRT looks that SDK up
  in the registry, so a machine without it stops with "Could not find the
  Windows SDK in the registry". The recipe passes the same files from NuGet
  instead: the contracts in Microsoft.Windows.SDK.Contracts 10.0.26100.8249,
  byte for byte those of the SDK 10.0.26100 that Files was first built
  with. It also empties `WindowsSdkPath`, which the XAML compiler is handed
  and doesn't need. So a machine with the SDK builds Files as one without
  it does, into the same image.

The vendor step restores both projects for x64: 3.3 GB of packages (the
Windows App SDK and its AI and ML parts, which Files excludes from its build
but NuGet downloads anyway, Win2D, CsWinRT, Sentry), 4.5 minutes; the build
takes 4. The image is 168 MB of files, 61 MB compressed.

It declares `HKCU\Software\Files Community` as a key it keeps, and has the
network, the working directory and the user's six folders. It runs in the
`soft` sandbox only, which it asks for: at low integrity and in an
AppContainer, Windows' storage APIs refuse a program without a package, and
Files shows no drives ([findings](findings.md#files)).

## Java

Java's images are Eclipse Temurin's builds of OpenJDK 25, the current
long-term release, from Adoptium's zips: the JDK as the SDK image, and
Temurin's own JRE as the runtime image apps run on. OpenJDK's licence is the
GPL 2 with the Classpath Exception, so they're published like the others.
Each brings the C runtime DLLs it needs, so nothing has to be installed on
the machine.

- **[`org.openjdk.java.Sdk`](recipes/java-sdk.json)** is the JDK: `java`,
  `javac`, `jar`, `jshell`, `javadoc`, `jdeps`, `jlink` and `keytool`, which
  it exports, without its sources (`lib/src.zip`). Its `bin` is on the PATH
  of builds that list it as an SDK. Run as an app, it builds and runs Java in
  the working directory: `java Hello.java` runs a program from its source.
- **[`org.openjdk.java`](recipes/java.json)** is the JRE: `java` and
  `javaw`, and the modules programs use, without the compiler and the tools.
  Apps list it in their `runtimes`. Its layer is 58 MB.
- **[`org.apache.maven`](recipes/maven.json)** and
  **[`org.gradle.gradle`](recipes/gradle.json)** are Java's two build tools,
  each on the JDK's image as its runtime, as [Composer](#composer-and-php-apps)
  is on PHP's: they export `mvn` and `gradle`, and give builds that list them
  as SDKs the same commands, with the JDK.

Both Java images set:

```json
"JAVA_HOME": "${app}",
"JAVA_TOOL_OPTIONS": "\"-Duser.home=${data}\\home\" -Dsun.font.layout.ffm=false -Djavax.net.ssl.trustStoreType=Windows-ROOT-LOCALMACHINE"
```

- `user.home`: Java takes it from `SHGetKnownFolderPath`, which a run's
  `USERPROFILE` doesn't move ([findings](findings.md#java)), so without it
  Maven's `.m2`, Gradle's `.gradle` and the settings folders apps keep there
  would be in your real profile. Every Java program in a run reads
  `JAVA_TOOL_OPTIONS`, those Maven and Gradle start too, and prints that it
  did, on stderr: `Picked up JAVA_TOOL_OPTIONS: ...`.
- `sun.font.layout.ffm=false`: JDK 25 shapes text with HarfBuzz through its
  foreign function interface, which can't find the C runtime in an
  AppContainer; this uses its other binding, through JNI, in every sandbox.
- `javax.net.ssl.trustStoreType=Windows-ROOT-LOCALMACHINE`: TLS trusts the
  machine's roots in Windows' store, as Windows' own programs do, rather
  than Temurin's `cacerts`, so a root a network's administrators add is
  trusted ([certificate trust](networking.md#certificate-trust)).
  `Windows-ROOT`, which has the user's own roots too, can't be read at low
  integrity: the JDK opens the user's store to write.

Apps that keep settings with `java.util.prefs` keep them in
`HKCU\Software\JavaSoft\Prefs\<their package>`: a recipe names that key in
`registry` ([registry settings](#registry-settings-kept-with-the-app)), not
the `Prefs` key above it, which all Java apps share.

### Apps on Java's runtime

An app's command is the runtime's `java.exe`, with its jar; a window of its
own gets `javaw.exe`, which has no console, so zigsaw gives it the
windowless shim:

```json
"command": "${java}\\bin\\java.exe",
"args": ["-jar", "${app}\\pdfbox-app.jar"],
"runtimes": { "java": "org.openjdk.java:25.0.5_8@sha256:..." },
"exports": {
  "pdfbox": { "command": "${java}\\bin\\java.exe", "args": ["-jar", "${app}\\pdfbox-app.jar"] },
  "pdfbox-debugger": { "command": "${java}\\bin\\javaw.exe", "args": ["-jar", "${app}\\pdfbox-app.jar", "debug"] }
}
```

An app that needs a module the JRE leaves out (`jdk.unsupported.desktop`,
for JavaFX's Swing interop, or the tools in `jdk.*`) lists the JDK's image
instead, `org.openjdk.java.Sdk`, as Scene Builder does.

Java builds don't need anything else to reproduce, as long as the archives
they make don't record when they were made: Maven's plugins take the time
from `project.build.outputTimestamp` (Apache's parent POM sets one), and
Gradle 9's archives have fixed times. A JAR made with `jar` itself takes
`--date`. One more thing to know about builds: Java resolves the build drive,
`B:`, to the build directory's real path whenever a program asks for a
canonical path (`File.getCanonicalPath`), so a tool that compares paths that
way may not match `B:\...` with what it found elsewhere.

### Maven

A Maven module vendors its dependencies and plugins by running its own build
with the local repository in the module's directory, then deletes what
records when and from where Maven fetched each file, and builds offline from
what's left, as [`tests/build/maven`](tests/build/maven) does:

```json
"vendor": {
  "commands": [
    "mvn -B -ntp -Dmaven.repo.local=vendor package -DskipTests",
    "find vendor \\( -name _remote.repositories -o -name '*.lastUpdated' -o -name resolver-status.properties -o -name 'maven-metadata-*.xml' \\) -delete",
    "rm -rf vendor/.meta"
  ],
  "dir": "vendor",
  "sha256": "..."
},
"build": ["mvn -B -ntp -o -Dmaven.repo.local=\"$PWD/vendor\" package -DskipTests", "..."]
```

- The vendor commands run the goals the build will, so the plugins Maven
  resolves only while it builds are vendored too. Files on Maven Central
  never change, and Maven takes the versions a project names, so the step
  makes the same files each time; the pinned hash would say otherwise.
- Without `_remote.repositories`, Maven takes the files it finds as ones
  installed locally, which an offline build may use.
- Maven 3.10 also fetches each repository's list of the group prefixes it
  serves into the local repository's `.meta`. Central regenerates its list,
  so a vendor directory that kept it would hash differently from week to
  week (iteration 31's PDFBox did, in CI); an offline build doesn't read it.
- A project with version ranges or SNAPSHOT dependencies needs
  `maven-metadata` files, which change: it can't be vendored this way.
- `mvn` is Maven's launcher run with the JDK's `java.exe`, not `mvn.cmd`,
  so that builds can run it: `maven.multiModuleProjectDirectory`, which
  Maven 3 requires, is the working directory. A module builds from its
  directory, where `.mvn` would be, but the launcher doesn't read
  `.mvn/jvm.config` or `MAVEN_OPTS`.
- Select a project of a multi-module build by its artifact ID,
  `-pl :pdfbox-app`, not its directory: Maven compares canonical paths, and
  a directory on `B:` matches nothing.

### Gradle

A Gradle module vendors by building with a Gradle home of its own, then
turning what Gradle downloaded into a Maven repository with `gradle-vendor`,
a command of Gradle's image; the build points every repository at it, as
[`tests/build/gradle`](tests/build/gradle) does:

```json
"vendor": {
  "commands": ["gradle -g gradle-home stage", "gradle-vendor gradle-home vendor"],
  "dir": "vendor",
  "sha256": "..."
},
"build": ["ZIGSAW_GRADLE_REPO=\"$PWD/vendor\" gradle --offline stage", "..."]
```

- Gradle keeps each file it downloads as
  `caches/modules-2/files-2.1/<group>/<module>/<version>/<hash>/<file>`,
  plugins and their markers too, and records about them that change from
  run to run. [`gradle-vendor`](recipes/gradle/GradleVendor.java), a Java
  program the JDK runs from its source, copies only the files, as
  `<group as directories>/<module>/<version>/<file>`, which is a Maven
  repository.
- [`zigsaw-offline.gradle`](recipes/gradle/zigsaw-offline.gradle), in the
  image's `init.d`, runs in every Gradle build, and does something only when
  `ZIGSAW_GRADLE_REPO` names a directory: then every Maven repository a
  build declares, in its settings, its build scripts or its projects, its
  plugins' included, whenever it declares it, is that directory. A
  repository of another kind (Ivy) stops the build.
- Dependencies whose versions are ranges or `latest`, and SNAPSHOT
  versions, can't be found in it: their metadata isn't kept.
- `gradle` is Gradle's launcher run with the JDK's `java.exe`, as
  `gradle.bat` would, with the daemon off
  (`-Dorg.gradle.daemon=false`): a run's job would end it anyway. Builds
  that ask for other JVM settings get a daemon for that build only.
- The image is Gradle's current release, 9.8.1; a project's wrapper may name
  another, which the recipe can take or not (PlantUML's names 9.3.1).

### PDFBox

[PDFBox](recipes/pdfbox.json) 3.0.8, Apache's library for PDF documents,
built from its source release on Maven Central (`-pl :pdfbox-app -am
package`), as one jar with its dependencies. Its command is its command
line (`pdfbox export:text`, `render`, `merge`, `fromtext` and more), and
`pdfbox-debugger` opens a document in its debugger, which Explorer offers
for `.pdf` files. Its font cache (`.pdfbox.cache`, from the fonts in
`C:\Windows\Fonts`) is in its data's `home`, and the debugger's window and
recent files are in `HKCU\Software\JavaSoft\Prefs\org\apache\pdfbox`, which
it keeps. Its tests download their documents, so the recipe skips them
(`-DskipTests`, which also skips the downloads). It has the working
directory and the user's Desktop, Documents and Downloads, in every sandbox.

### PlantUML

[PlantUML](recipes/plantuml.json) 1.2026.9 draws UML and other diagrams
from text. The recipe builds its GPL jar from its GitHub tag
(`gradle -Pfast jar`), without its git properties (the archive has no
`.git`), and fills in its version, commit and commit time, as upstream's CI
does, so `plantuml -version` says which it is. Its jar carries a small
build of Graphviz's `dot` 2.44.1, which it unpacks into its data's TEMP and
lays out class and component diagrams with, so it needs no other image.
`plantuml-gui` opens its window, which draws the diagrams in a folder as
they change. It keeps `HKCU\Software\JavaSoft\Prefs\net\sourceforge\plantuml`.

### Logisim-evolution

[Logisim-evolution](recipes/logisim-evolution.json) 5.0.0 designs and
simulates digital logic circuits. The recipe builds its GPL jar from its
GitHub tag with Gradle (`shadowJar`, all dependencies in one jar), the way
PlantUML's does. The build is bigger: a Kotlin build script, three plugins
from Gradle's plugin portal (Shadow, SonarQube, Versions), Checkstyle
resolved while Gradle configures the build, a second source set that runs
during the build to make the help files, and the configuration cache on.
Its offline build needed nothing beyond the vendor step and the init script.
Its build script writes the time of the build, in the build machine's time
zone, into the program, so the recipe sets the time of the tag's commit, in
UTC. Its command is its command line (`logisim --tty table circuit.circ`
simulates without a window), and `logisim-gui` opens its window, which
Explorer offers for `.circ` files. It keeps
`HKCU\Software\JavaSoft\Prefs\com\cburch\logisim`.

### Scene Builder

[Scene Builder](recipes/scenebuilder.json) 26.0.0, Gluon's designer for
JavaFX user interfaces, is built from its GitHub tag with Maven
(`package`, its jar with its dependencies but not JavaFX's) and brings
JavaFX itself.

- **JavaFX** comes from Gluon's OpenJFX 26.0.2 SDK for Windows, which the
  recipe takes as a second source: its modules' jars in `javafx\lib`, their
  DLLs in `javafx\bin`, with the Visual C++ runtime they need, and their
  licences in `javafx\legal`.
  - The app runs with those jars on the module path
    (`--module-path ${app}\javafx\lib --add-modules ...`) and its own jar on
    the class path, as upstream's installer runs it.
  - JavaFX looks for its DLLs in the `bin` folder beside its jars before it
    unpacks the copies in Maven Central's jars into `user.home\.openjfx`.
    The SDK's jars have none inside, so nothing is unpacked into the app's
    data.
  - JavaFX draws with Direct3D, or in software where there's none (CI's
    runners), in every sandbox. `-Dprism.verbose=true` (through
    `--env=JDK_JAVA_OPTIONS=...`) says which.
- **It runs on the JDK's image** (`org.openjdk.java.Sdk`), not the JRE's.
  JavaFX's `javafx.swing` needs the module `jdk.unsupported.desktop`, which
  Temurin's JRE leaves out, and Scene Builder lists Swing's `SwingNode`
  among its components when it starts.
- **Three changes to its build**:
  - `maven-compiler-plugin` 3.13.0 → 3.14.1, in the vendor step too: the
    older one rewrites the compiled `module-info.class` with an ASM that
    can't read Java 24's class files (`Unsupported class file major
    version 68`);
  - the version `26.0.0-SNAPSHOT` → `26.0.0`, as upstream's release
    workflow sets it;
  - the build date in its About box, the tag's commit time.
- **Its build's JVM runs on UTC** (`JDK_JAVA_OPTIONS=-Duser.timezone=UTC`
  in the module's env). Its jar with dependencies is made by
  maven-shade-plugin 3.2.4, which copies the dependencies' entries with
  their own times; those of jars that store them in UTC (Woodstox and three
  others, 1,224 of its 6,237 entries) come out in the JVM's time zone. Built
  on UTC+7, they were 7 hours off those of a build on CI's UTC.
- **No usage report.** Once a week it would send Gluon an id, the operating
  system and Java's version at startup. The recipe removes that call.
  Checking for updates and registering stay in its Help menu, and its
  library manager searches Maven repositories, hence `network`.
- `scenebuilder` opens its window, which Explorer offers for `.fxml` files.
  It keeps `HKCU\Software\JavaSoft\Prefs\com\oracle\javafx\scenebuilder`
  (recent files, window layouts); its log and its user library are in its
  data.

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
debugger connects to an IDE in each: in an AppContainer through the port
it declares it uses ([ports an app uses](#ports-an-app-uses)). Xdebug's
`.ini` sends its traces and profiles to `${TEMP}`, the run's, in the data
directory of the app PHP runs for: its default, `C:\Windows\Temp`, is one a
low-integrity run can't write.

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
on its [service](#services) `http`, `127.0.0.1:8471` (`--port=http=<port>`
for another, or `--listen=<host>:<port>`, which bypasses the service), with a
[router](recipes/kanboard/router.php) that refuses the directories
Kanboard's `.htaccess` keeps from the web, and opens the page in the default
browser (`--no-browser` doesn't): Explorer opens it, so the browser runs
outside the app's sandbox, and doesn't end with the server. Its Start menu
shortcut runs it, with a console window for the server's log; closing it
stops the server. `DATA_DIR` is the app's data, where Kanboard keeps its
SQLite database and files; `PLUGINS_DIR` is `plugins` in it. `kanboard-cli`
is Kanboard's command line (`kanboard-cli db:version`). It asks for the
`soft` sandbox, and works under `--sandbox=appcontainer` too, where the
browser reaches it through the service; at low integrity PHP's
`is_writable()` says no to what the run may write, and Kanboard refuses its
data directory ([known gaps](gaps.md)).

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

## TeX Live

[`org.tug.texlive`](recipes/texlive.json) is TeX Live 2026's small scheme
(LaTeX, pdfTeX, XeTeX, LuaTeX, MetaPost, BibTeX, Biber and latexmk, 430
packages): TeX Live's own Windows programs and its macros and fonts,
installed at build time by TeX Live's installer from pinned packages. What
TeX Live would bring its own copies of are images of their own, as its
runtimes: Perl's ([`org.perl.perl`](recipes/perl.json), Strawberry Perl),
for its Perl scripts such as latexmk, and Ghostscript's
([`com.artifex.Ghostscript`](recipes/ghostscript.json), built from source),
for epstopdf and ps2pdf. Its layer is 236 MB.

**Its packages are pinned against a repository that moves.** tlnet, TeX
Live's repository, has one archive per package, and replaces it in place
whenever the package changes, which some do every day. So the recipe isn't
written by hand: [`scripts/texlive-pins.sh`](scripts/texlive-pins.sh)
downloads tlnet's package database, takes the scheme's packages for
Windows, downloads each one, checks it against the database, and writes
[`recipes/texlive.json`](recipes/texlive.json) from
[`recipes/texlive/texlive.json.in`](recipes/texlive/texlive.json.in): each
archive's URL and sha256, the database's, the installer's, the version
(`2026.<the repository's revision>`) and the exports. Once tlnet has
replaced an archive, its URL serves other bytes, and builds take the pinned
one from the sources pushed next to the image (`zigsaw push --sources`,
which `scripts/publish.sh` does) instead. So, to update TeX Live: run the script, build, and publish from
the store that built it, which has every pinned file (publishing pushes
them), even after tlnet has moved on.

**The build** runs `install-tl` offline, with its own Perl, from the pinned
archives laid out as a repository (`repo/tlpkg/texlive.tlpdb`,
`repo/archive/*.tar.xz`), with a profile (written by the same script,
[`recipes/texlive/texlive.profile`](recipes/texlive/texlive.profile)):
portable (nothing in the registry, PATH or Start menu), without
documentation, sources, Windows tools or formats. The installer always
installs TeX Live's Perl and Ghostscript on Windows, and runs its scripts
with them; `cleanup` leaves both out of the image. Then the build commands
make what the installer wrote the same on every machine and right wherever
the app is deployed:

- fontconfig's `fonts.conf`, for XeTeX, names the font directories relative
  to itself (`<dir prefix="relative">../../../texmf-dist/fonts/opentype`)
  and Windows' fonts as `WINDOWSFONTDIR`, instead of the build's paths; the
  font cache the installer made goes, as XeTeX makes its own in the data
  directory.
- The dates in the headers of the files the installer generates
  (`fmtutil.cnf`, `updmap.cfg`, `language.dat`...) go, and the package
  database names tlnet as where packages come from.
- Two lines of TeX Live's Perl modules change, so its scripts run on
  Strawberry Perl: `Win32::Shortcut`, which Strawberry Perl lacks and which
  is only used for Start menu shortcuts, becomes optional, and the check of
  whether the system tree is writable writes a file (Perl's `-w` reads only
  the read-only attribute, not permissions).
- `mktexfmt` becomes fmtutil in its mktexfmt mode (TeX Live's Windows
  `mktexfmt.exe` makes the format but doesn't say where, so the run that
  wanted it stops), and the `ls-R` file lists are made again.

**Formats are made on first use**, in the data directory: the image has
none, because engines dump the time they were made into them (pdfTeX its
random seed, TeX `\time`, LuaTeX more), with or without
`SOURCE_DATE_EPOCH`. The first run of `pdflatex` takes a few seconds more;
LuaLaTeX's also builds luaotfload's font list, in the data directory too.
Runs have:

```json
"TEXMFVAR": "${data}\\texmf-var",
"TEXMFCONFIG": "${data}\\texmf-config",
"TEXMFHOME": "${data}\\texmf",
"XE_FC_CACHEDIR": "${data}\\texmf-var\\fonts\\cache",
"TEXLIVE_WINDOWS_TRY_EXTERNAL_PERL": "1",
"TEXLIVE_WINDOWS_EXTERNAL_GS": "${gs}\\bin\\gswin64c.exe"
```

The last two are how TeX Live's script runner (`runscript.tlu`) is told to
use a Perl on PATH (Perl's image's, a runtime's PATH entry) and another
Ghostscript. The tree is read-only, so there's no `tlmgr`: another set of
packages is another scheme in the script (`SCHEME=scheme-medium`), and
packages of your own go in `TEXMFHOME`. The command is `latexmk`
(`zigsaw run org.tug.texlive -pdf paper.tex`); the exports are every program
of the packages, but for tlmgr's, the scripts that write the system trees,
and documentation browsers (no documentation is installed). In an
AppContainer, kpathsea can't find its own long path where Windows doesn't let
AppContainers list the drive root (as here, on Windows 11 26300), and every
program stops at once: a known gap ([gaps](gaps.md)).
[`tests/texlive.sh`](tests/texlive.sh) runs all of it, in about 90 s.

### Ghostscript

[`com.artifex.Ghostscript`](recipes/ghostscript.json) is Ghostscript 10.08
built from its release tarball, with the libraries it bundles, with zig and
BusyBox: one program, `gswin64c.exe` (the name TeX Live's scripts look for;
`gs` is exported too), with its PostScript resources and fonts compiled in,
so it needs no `GS_LIB`. Its configure script supports MinGW; what it needs
besides:

- `ac_cv_prog_MAKE_EXISTS=yes`: it looks for `make` on PATH, which BusyBox's
  applet isn't, and `LD` set to the [autotools `ld`](#gtk) for libtiff's
  configure.
- Its makefile marks the directories it makes as GNU make's order-only
  prerequisites (`| directories`), which BusyBox's make doesn't know: the
  build empties `MAKEDIRS` and runs `make directories` first.
- `-Wp,-w`, for FreeType, becomes `-w`, which zig takes; and a stand-in for
  a Windows function in `mkromfs.c` is for MSVC only, as MinGW builds have
  the Unix one.

It builds in about 16 minutes here, as BusyBox's make compiles one file at
a time. Its licence is the AGPL 3, which the sources pushed next to its
image answer.

## PostgreSQL

[`org.postgresql.PostgreSQL`](recipes/postgresql.json) is PostgreSQL 18
built from its release tarball with Meson and zig, as PostgreSQL's MinGW
build. As GTK's runtime does, it takes its files from an SDK,
[`org.postgresql.PostgreSQL.Sdk`](recipes/postgresql-sdk.json), which builds
PostgreSQL and keeps what extensions are built with (see
[Extensions](#postgresql-extensions)); the runtime's cleanup leaves those
out. Its libraries are modules of the SDK's recipe, built static and linked in:
zlib, lz4 and zstd with CMake, libxml2 with Meson, and OpenSSL as GTK's SDK
builds it (with Perl's image and
[`openssl-unixspec.pm`](recipes/gtk4-sdk/openssl-unixspec.pm)). ICU is
Windows' own `icu.dll`: the recipe takes ICU 72.1's headers (what Windows 11
and Server 2025 ship), with `U_DISABLE_RENAMING` for the unversioned names
that DLL exports, and links mingw-w64's import library for it (`-licu`),
through two `.pc` files of its own. PL/Perl and PL/Python are linked against
Perl's image's `perl542.dll` and Python 3.14's `python314.dll` (headers and
import library from Python's NuGet package, at build time), and those images
are the app's runtimes, so their DLLs are on PATH. Its layer is 33 MB.

What PostgreSQL's MinGW build needs from zig
([`zig-mingw.patch`](recipes/postgresql/zig-mingw.patch)):

- **A .def file for `postgres.exe`.** Extensions link against the server's
  import library, which a MinGW build makes with `--export-all-symbols`; zig's
  linker takes that flag and ignores it, so the server exported only the
  variables marked `PGDLLIMPORT`, and every extension linked with undefined
  symbols. As with MSVC, the build now writes `postgres.def`, of everything
  the backend's libraries define:
  [`mingw_gendef.pl`](recipes/postgresql/mingw_gendef.pl) reads it from
  GTK's SDK's `nm`, built by the recipe, and the member lists of Meson's thin
  archives, which that `nm` doesn't read. zig's cc takes a `.def` file as an
  input.
- **No `--allow-multiple-definition` or `--disable-auto-import`**, which
  zig's linker refuses. The first let PostgreSQL's getopt replace mingw's:
  on Windows, its getopt now keeps its own variables too, as mingw's are in
  the object that has mingw's getopt.
- **MinGW's setjmp and longjmp, not GCC's builtins**, which PostgreSQL uses
  for MinGW-64: with clang's, a backend crashed after some errors (a `DO`
  block in a language that doesn't exist), on a bad portal once longjmp was
  back in `PortalRun()`. clang gives every function the unwind data that
  MinGW's longjmp needs; errors raised through PL/Perl and PL/Python, both
  ways, unwind too.
- **A windres.** Meson takes `RC` for windres, so the module's `RC` is GTK's
  SDK's [`windres.c`](recipes/gtk4-sdk/windres.c) over zig's rc, and
  PostgreSQL's `rcgen` passes it the input before the output.

Besides: PostgreSQL 17 and later don't ship their bison and flex output, so
winflexbison builds it; zlib's CMake names its static library `libzs.a`; and
libxml2's `.pc` lacks `-DLIBXML_STATIC`, and OpenSSL's lists its system
libraries as private, which the recipe puts right for static linking. The
runtime has no headers, static libraries or pgxs.
[`signal-pipes.patch`](recipes/postgresql/signal-pipes.patch) moves the named
pipes PostgreSQL emulates signals with under `\\.\pipe\LOCAL\`, the only
place an AppContainer may make them.

**Running it.** `postgresql` is
[`pg-server.c`](recipes/postgresql/pg-server.c):

- It makes the cluster on its first run, in `PGDATA` (`${data}\data`), with
  initdb: UTF-8 in the builtin provider's `C.UTF-8`, which no Windows update
  changes as it would ICU's collations (ICU's are there for
  `CREATE COLLATION` and `COLLATE "de-x-icu"`), and scram-sha-256 for every
  connection, as `postgres` with a random password.
- The password goes in `PGPASSFILE` (`${data}\pgpass.conf`), so the app's
  clients log in with it and anyone else needs it from there.
- It then runs `postgres` in the foreground, as a run's job ends what the
  run leaves behind: a `pg_ctl start` ends with its own run. Ctrl+C, or
  `pg_ctl stop` from another run, stops it.
- postgres refuses to run as an administrator, which a runner's user is: as
  initdb and pg_ctl do, the launcher runs itself again with Administrators
  deny-only first.
- In an AppContainer, initdb can't make the cluster's directory, as it
  stats each parent, which the container can't for the store's; the launcher
  makes it. initdb also picks `max_connections` and `shared_buffers` by
  running postgres through cmd.exe, which there can't start a program in the
  store, and would take its least (20 and 400kB); the launcher sets the
  server's defaults (100 and 128MB).
- initdb's last step runs a backend through cmd.exe with its output sent to
  `nul`, which an AppContainer on Server 2025 can't open (Windows 11 26300's
  can): [`initdb-nul.patch`](recipes/postgresql/initdb-nul.patch) sends it to
  a file in the cluster's directory instead, removed once the backend is
  done. Its errors were on stderr already.
- PL/Perl started Perl with `-e` and its boot code, and with `-e` Perl opens
  `nul` as its script: in an AppContainer on Server 2025, `CREATE EXTENSION
  plperl` failed with an empty error. On Windows,
  [`plperl-nul.patch`](recipes/postgresql/plperl-nul.patch) has Perl read the
  boot code from `share\postgresql\plperl_boot.pl` (PL/Perl's
  `plc_perlboot.pl`, which the build otherwise compiles in; Meson installs
  it) and runs `plperl.on_init` after it, as `-e` did, in package `main`.
  PostgreSQL's plperl suite passes with it.

The server is the app's [service](#services) `postgresql`, on 5432.
`PGPORT` is `${listen:postgresql}`, which postgres and libpq both read, so
the server and the app's clients agree in every sandbox, and in an
AppContainer, programs outside it reach the server through the service.
`--port=postgresql=5433` moves it, for the clients too; a server given `-p`
itself bypasses the service.

### PostgreSQL extensions

PostgreSQL's image has an [extension point](#extension-points),
`org.postgresql.PostgreSQL` at version `18` (an extension's `PG_MODULE_MAGIC`
is for a major version), that joins `PG_EXTENSION_DIRS` and
`PG_PRELOAD_LIBRARIES`. An extension image names its directory in the first
and, if the server must load it at start, its library in the second; the
launcher turns them into `extension_control_path` and `dynamic_library_path`
(each directory's `share` and `lib` after PostgreSQL's own) and
`shared_preload_libraries`, before the options it's given, so those win.
PostgreSQL 18 finds a control file on that path and loads its
`$libdir/<name>` from the directories after `$libdir`, so extensions build
and install as they do anywhere. `postgres` or `pg_ctl start`, run on their
own, load no extensions.

Extensions build with pgxs from the SDK, with [GNU make](#gnu-make)'s image,
as their documentation says, installing into the image's prefix rather
than the SDK's read-only deployment:

```json
"extends": { "point": "org.postgresql.PostgreSQL", "version": "18" },
"env": { "PG_EXTENSION_DIRS": "${app}" },
"sdk": { "pgsdk": "org.postgresql.PostgreSQL.Sdk:18.6@sha256:...", "make": "org.gnu.make:4.4.1@sha256:...", "zig": "...", "busybox": "..." },
"modules": [
  {
    "name": "pgvector",
    "sources": [...],
    "build": [
      "sdk=$(dirname \"$(pg_config --bindir)\") && make -j\"$(nproc)\" USE_PGXS=1 OPTFLAGS= \"COPT=-fmacro-prefix-map=$sdk=pgsdk\"",
      "make install USE_PGXS=1 OPTFLAGS= pkglibdir=\"$PREFIX/lib\" datadir=\"$PREFIX/share\" includedir_server=\"$PREFIX/include/server\""
    ]
  }
]
```

What the SDK does for that: zig's linker looks for `-lpq` only as
`libpq.a`, not as `libpq.dll.a`, so the import libraries of PostgreSQL's
DLLs are named `lib<name>.a` in place of the static ones (pg_cron linked
libpq's static library, LDAP and all, before); pgxs's `Makefile.global`
names tools by name rather than by the build's or the store's paths (Perl's
path in it made each store's SDK differ), and links without the build's
`noexport.o` (extensions mark what they export, so nothing else is);
pkg-config files are relocatable, as Qt's are. `pg_config` prints long
paths ([`pg-config-long.patch`](recipes/postgresql/pg-config-long.patch)):
PostgreSQL turns every path it works out into its 8.3 short name where the
volume has those (`include/POSTGR~1/server`), which depends on the volume and
on the order directories were made in, and the DLLs pgxs built kept them, so
pgvector's differed between this machine and a runner. Its static libraries are
compiled with `CFLAGS=-s`: zig's cc otherwise writes debug info into each
object, with clang's command line naming the store's zig and a random
temporary file, so the libraries differed between stores (programs linked
with `-s` don't keep it). An extension's build maps the SDK's directory away
(`COPT=-fmacro-prefix-map=...`, as GTK 3's SDK does with GTK's): PostgreSQL's
headers' `__FILE__`s would otherwise put the SDK's path in the store into
the DLL.

- [`org.postgresql.PostgreSQL.pgvector`](recipes/postgresql-pgvector.json),
  pgvector 0.8.7: `OPTFLAGS=` drops pgvector's default `-march=native`,
  which would make the image depend on the building machine's CPU; its
  AVX-512 functions are still chosen at run time, once zig's clang has the
  `evex512` it wants beside `avx512f` (a `sed`).
- [`org.postgresql.PostgreSQL.pg_cron`](recipes/postgresql-pg-cron.json),
  pg_cron 1.6.8, preloaded (`PG_PRELOAD_LIBRARIES=pg_cron`), in the
  `postgres` database. Its jobs connect to the server with libpq by
  default, and on Windows those connections never got past connecting (its
  poll() is WSAPoll), so every job timed out at startup; the image makes
  `cron.use_background_workers` on by default, which runs jobs in
  background workers without a connection or a password.
- [`org.postgresql.PostgreSQL.PostGIS`](recipes/postgresql-postgis.json),
  PostGIS 3.6.4 with its raster, topology and TIGER geocoder extensions (no
  protobuf, address standardizer or SFCGAL), built on [GDAL's SDK](#gdal).
  GEOS, PROJ, json-c and libiconv are the SDK's static libraries, linked
  into `postgis-3.dll` and `postgis_raster-3.dll`; GDAL is the SDK's
  `libgdal-39.dll`, which the image carries in its `bin`. PostgreSQL loads
  an extension with `LoadLibrary`, which doesn't look for its DLLs beside
  it, so the image names its `bin` in its `path`: an extension's PATH
  entries join the server's runs, and Windows finds the DLL there, in each
  sandbox. The image sets `PROJ_DATA` and `GDAL_DATA` to the copies of PROJ's
  `proj.db` and GDAL's data it carries. The build runs PostGIS's configure
  and make under BusyBox: `PATH_SEPARATOR=;` (as Ghostscript's), `perl`
  and `pg_config` given as full paths (configure looks for programs without
  `.exe`), the SQL preprocessor as `cc -E -x c -traditional-cpp`,
  FlatGeobuf's C++ with `c++ -O2` (zig's `cc -x c++` has no C++ headers, and
  without `-O` zig builds debug code, with UBSan), its archive named `.a`
  (it was `.la`, which zig's linker refuses), and functions declared
  `PGDLLEXPORT` before their use (clang refuses to add `dllexport` to a
  function already used, where `PG_FUNCTION_INFO_V1` does). `utils`, whose
  make ran two makes in `raster/rt_pg` at once that both wrote
  `rtpostgis.sql` through one temporary file, makes its targets one at a
  time (`.NOTPARALLEL`; it failed so on a runner in iteration 47). The
  loaders (`shp2pgsql`, `pgsql2shp`, `raster2pgsql`) are left out, as
  extensions export no commands; so are the upgrade scripts from earlier
  PostGIS versions, which this image never had (the `…--ANY.sql` stubs,
  links in the build, are copies). Its layer is 29 MB (12 MB without
  raster); GDAL's DLL is 42 MB of the files it unpacks.

PostgreSQL's regression suites pass on the build: regress (231 tests),
isolation (122), plpgsql, plperl and plpython. [`tests/postgresql.sh`](tests/postgresql.sh)
runs the image in each sandbox, in about 100 s.

## GDAL

[`org.gdal.GDAL`](recipes/gdal.json) is GDAL 3.13.3's raster and vector
tools: the `gdal` command and its subcommands, `gdalinfo`,
`gdal_translate`, `gdalwarp`, `ogr2ogr`, `ogrinfo` and the rest, exported,
with the `cwd` permission. As PostgreSQL's image does, it takes its files
from an SDK, [`org.gdal.GDAL.Sdk`](recipes/gdal-sdk.json), which builds
GDAL with CMake and zig and keeps what other builds link with: headers,
`gdal-config`, the import library, and static libraries of what GDAL is
built on, which are modules of its recipe: GEOS 3.15.0, PROJ 9.9.0 (with
`proj.db`), SQLite (with its R-tree, which GDAL's GeoPackage driver
needs), json-c 0.19, expat 2.9.0 and libiconv. PostGIS builds against
them (see [extensions](#postgresql-extensions)).

- GDAL is one DLL, `libgdal-39.dll`, with those libraries inside, and GDAL's
  own copies of zlib, libtiff, libgeotiff, libjpeg, libpng, giflib, LERC,
  qhull and Shapelib (`GDAL_USE_EXTERNAL_LIBS=OFF`, then the external ones
  it should use turned on by name, so nothing else it might find in a
  build is used). No curl, so no drivers for web services; no Python, Java
  or C# bindings.
- [`cpu-model.patch`](recipes/gdal/cpu-model.patch): GDAL asks whether the
  CPU has AVX2 and FMA with `__builtin_cpu_supports()`, which reads
  compiler-rt's `__cpu_model`, and zig's compiler-rt has none for Windows:
  the DLL didn't link. The patch asks CPUID instead, through `<cpuid.h>`.
- The DLL links with the [`crt-noexport`](#building-without-a-recipe)
  object, as GTK's and PostgreSQL's SDKs' do: it otherwise exported the C
  runtime's `atexit`, which the tools linking it then defined twice.
- `-DXML_STATIC`, as expat is a static library (its header otherwise
  declares its functions `dllimport`).
- The import library is named `libgdal.a`, as zig's linker never looks for
  `libgdal.dll.a`; `gdal-config` and `geos-config` work out their prefix
  from where they are, and the pkg-config files from `${pcfiledir}`, so they
  work from the SDK's deployment, wherever a store puts it (the build fails
  if one still names a drive).
- The image sets `GDAL_DATA` and `PROJ_DATA` to its `share\gdal` and
  `share\proj`.

The SDK takes 16 minutes here, 7 of them GDAL's 1,500 compiles, and its
layer is 39 MB; the tools' image is 25 MB. [`tests/gdal.sh`](tests/gdal.sh)
runs the tools in each sandbox, in about 10 s.

## osm2pgsql

[`org.osm2pgsql.osm2pgsql`](recipes/osm2pgsql.json) is osm2pgsql 2.3.1,
which imports OpenStreetMap data into PostgreSQL with PostGIS. It exports
`osm2pgsql` and `osm2pgsql-expire`, with the `network` and `cwd`
permissions. It's an app of its own, not a PostgreSQL extension, since it's
a client: it reaches a server anywhere, except a local one from an
AppContainer ([gaps](gaps.md)). It's built with CMake and zig on two SDKs:

- **PostgreSQL's** for libpq (its import library, and `libpq.dll`, which
  the image carries; OpenSSL is linked into it) and zlib.
- **GDAL's** for PROJ, SQLite and expat, all static. The image carries
  PROJ's `proj.db` and sets `PROJ_DATA`, so styles can use any EPSG
  projection.

Its recipe's own modules:

- **bzip2** 1.0.8, as a static library.
- **Lua** 5.4.9, as a static library. osm2pgsql's CMake looks for 5.1 to
  5.4.
- **nlohmann/json**, headers only.
- **Boost**'s headers only: osm2pgsql
  uses only Geometry, which is header-only. Boost's CMake release has a link
  to a directory (in a library's docs), which zigsaw's tar reader refuses,
  and building Geometry with it means building the 80 libraries it depends
  on, several compiled. The b2 release is fetched as a file instead
  (`"type": "file"`), and BusyBox's `tar` unpacks only its `boost/` headers
  (26 s). [`BoostConfig.cmake`](recipes/osm2pgsql/BoostConfig.cmake) is
  enough for osm2pgsql's `find_package(Boost CONFIG)`.

osm2pgsql's own libosmium, protozero, fmt and CLI11 (its `contrib`) are
used. The build needed:

- `-D_POSIX_THREAD_SAFE_FUNCTIONS`, for MinGW's `localtime_r`; its code
  uses that outside MSVC.
- `-DXML_STATIC`, for the static expat; `-DNOMINMAX` and
  `-DWIN32_LEAN_AND_MEAN`, as `bzlib.h` includes `windows.h`.
- `CMAKE_CXX_STANDARD_LIBRARIES=-lsqlite3 -lshell32 -lole32`, for the
  static PROJ's own dependencies.
- [`default-style.patch`](recipes/osm2pgsql/default-style.patch). On
  Windows, upstream's default style for the pgsql output is
  `default.style` in the working directory. The patch looks for it next to
  the program instead, in `..\share\osm2pgsql`, where the image has it. The
  image also has upstream's example flex styles, in
  `share\osm2pgsql\flex-config`.

The build takes 2 minutes here, and the layer is 15 MB (two 18 MB programs,
each with PROJ and SQLite inside). [`tests/osm2pgsql.sh`](tests/osm2pgsql.sh)
runs PostgreSQL's server with PostGIS under soft, and osm2pgsql against it
under soft and low, in about 40 s:

- the pgsql output with the default style, then an update (`--append`)
  that expires tiles;
- the flex output with a Lua style that `require`s a module, from PBF, with
  flat nodes and an area table in UTM;
- gzip and bzip2 input, and `-W` reading the password.

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
