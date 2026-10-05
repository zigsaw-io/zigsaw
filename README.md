# Zigsaw

Image-based container solution for running sandboxed program on Windows.

Think Flatpak for Windows programs: apps are built from pinned sources into
OCI-style images, installed per user, and run in a clean environment with their
own data directory. No admin rights, no Hyper-V; it works on Windows Home.

Status: [iteration 10](docs/iteration-10.md) is complete. Zigsaw builds
command-line apps, and GTK 4 with its SDK and runtime, from source or from
official binaries, runs them on shared
runtimes, installs, updates and cleans them up, shares them through
registries as compressed images, and puts their commands on PATH, also those
they install while they run. Runs can be kept from writing anywhere but
their data and the paths they're granted, at low integrity, or confined to
their permissions in an AppContainer. Builds run with pinned toolchain
images (zig, BusyBox, CMake, Meson, Rust, Go with cgo), or the machine's MSVC, and
reproduce: CI checks that the recipes build the same images on a fresh
machine, and runs the end-to-end tests there, against a registry zigsaw
builds and runs itself. Registries keep the files images were built from,
so recipes build even when a download is gone. Git, Node, Python, SQLite,
ripgrep, bat, fzf, zot, zstd, GTK apps and the zig, CMake, Meson, Rust and Go toolchains are
tested.

## Quick start

Requires Zig 0.16.

```powershell
zig build                # ReleaseSafe by default; -Doptimize=Debug for a quicker compile
.\zig-out\bin\zigsaw.exe pull org.nodejs.node
.\zig-out\bin\zigsaw.exe run org.nodejs.node -e "console.log(process.version)"
```

`pull org.nodejs.node` installs the published image of Node (see
[Published apps](#published-apps)). `zigsaw build recipes\node.json` builds
the same image, with the same digest, from its recipe.

Installing an app also puts its commands (here `node`, `npm` and `npx`) in
`%LOCALAPPDATA%\zigsaw\bin`. Add that directory to your PATH, and they run
through zigsaw by name:

```powershell
[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:LOCALAPPDATA\zigsaw\bin", 'User')
```

PATH is searched in order, so if another copy of a command comes earlier (say
an installed Node), that one wins. `where node` shows which is found first.

## Commands

```
zigsaw build [--rebuild] [--keep-build-dir] <recipe.json>
                                       build an app from a recipe, install it and its commands
zigsaw pull <image>                    install an app and its commands from a registry
zigsaw push [--sources] <app-id> [<image>]
                                       publish an installed app to a registry; --sources
                                       also pushes the files it was built from
zigsaw login [--username=<user>] [--password-stdin] <registry>
                                       check and save a login for a registry
zigsaw logout <registry>               delete a registry's saved login
zigsaw run [options] <app-id> [args]   run an installed app
zigsaw list                            list installed apps, their commands and shortcuts
zigsaw update [<app-id>...]            rebuild or re-pull apps from where they came from
zigsaw rm [--delete-data] <app-id>     uninstall an app and its commands
zigsaw prune [--dry-run] [--downloads] [--data]
                                       delete what no installed app needs
```

## Published apps

The recipes in [recipes/](recipes/) are published as images in
`ghcr.io/zigsaw-io`, tagged with their version and `latest`, so these install
with `zigsaw pull <id>`:

| App | Id | Version | Commands |
|---|---|---|---|
| BusyBox | `net.frippery.busybox` | FRP-6075-g169694ebd | `busybox` |
| Git (MinGit) | `org.git_scm.MinGit` | 2.56.0.windows.1 | `git` |
| Node.js | `org.nodejs.node` | 24.21.0 | `node`, `npm`, `npx` |
| Prettier (on Node.js) | `io.prettier.prettier` | 3.9.9 | `prettier` |
| Python | `org.python.python` | 3.14.7 | `python` |
| zig | `org.ziglang.zig` | 0.16.0 | `zig` |
| SQLite (built from source) | `org.sqlite.sqlite3` | 3.53.4 | `sqlite3` |
| Rust (windows-gnu) | `org.rust-lang.rust` | 1.99.0 | `cargo`, `rustc` |
| ripgrep (built from source) | `com.github.BurntSushi.ripgrep` | 15.2.0 | `rg` |
| bat (built from source) | `com.github.sharkdp.bat` | 0.26.1 | `bat` |
| Go | `org.golang.go` | 1.27.1 | `go`, `gofmt` |
| fzf (built from source) | `com.github.junegunn.fzf` | 0.74.4 | `fzf` |
| zot, minimal (built from source) | `dev.zotregistry.zot` | 2.1.21 | `zot` |
| CMake, with Ninja 1.13.2 | `org.cmake.cmake` | 4.4.4 | `cmake`, `ctest`, `cpack`, `ninja` |
| zstd (built from source) | `com.github.facebook.zstd` | 1.5.7 | `zstd`, `unzstd`, `zstdcat` |
| Meson, with Ninja and pkgconf | `com.mesonbuild.meson` | 1.12.1 | `meson` |
| GTK SDK (built from source) | `org.gtk.Gtk4.Sdk` | 4.24.1 | none |
| GTK, with libadwaita (from its SDK) | `org.gtk.Gtk4` | 4.24.1 | `gtk4-demo`, `gtk4-node-editor`, `gtk4-print-editor`, `gtk4-query-settings`, `adwaita-1-demo` |
| GNOME Text Editor (built from source, on GTK) | `org.gnome.TextEditor` | 51.0 | `gnome-text-editor` |

Prettier runs on Node as a [runtime](#runtimes): its image brings Node's
files along, without installing Node as an app. SQLite, ripgrep, bat, fzf,
zot and zstd are [built from source](#building-from-source): SQLite with zig
and BusyBox, ripgrep and bat with [Rust](#rust), zig and BusyBox, fzf and
zot with [Go](#go) and BusyBox, zstd with [CMake](#cmake), zig and BusyBox,
whose images are their SDK. bat's C libraries (oniguruma, libgit2, zlib) are
compiled by zig. Pulling them doesn't need those. [GTK](#gtk)'s SDK is built
with Meson, CMake and zig, and its runtime is made from the SDK's image. GNOME
Text Editor runs on GTK's runtime, with GtkSourceView, libspelling and
libxml2 built into its own image. GTK's demos and Text Editor are GUI apps:
they open no console, and get [Start menu shortcuts](#start-menu-shortcuts).

Layers are gzip-compressed, so a pull downloads much less than it unpacks:
88 MB for zig's 378 MB of files, 179 MB for Rust's 649 MB.

[`scripts/publish.sh`](scripts/publish.sh) publishes the recipes listed in
[`scripts/published-recipes.txt`](scripts/published-recipes.txt).

### Reproducibility

Each image has the same digest as a build of its recipe on any machine:
sources are pinned by SHA-256, runtimes by image digest, and builds write
deterministic layers. The
[Reproduce workflow](.github/workflows/reproduce.yml)
([runs](https://github.com/zigsaw-io/zigsaw/actions/workflows/reproduce.yml))
checks this on every push to `main` and every pull request. On a fresh
Windows runner, it runs the unit tests, builds each published recipe, and
compares the digest with the image published for the recipe's version
([`tests/published.sh`](tests/published.sh)). Then it runs the end-to-end
suites (see [Testing](#testing)) on that runner too.

- A version that isn't published yet is reported, but doesn't fail the run.
- A different digest for the same version fails it. Either the build isn't
  reproducible, or the recipe changed without a new version.
- An image built with a [host toolchain](#msvc) isn't compared, since it
  isn't expected to match. (None of the published ones is.)

The workflow only checks; publishing stays manual.

## Sharing apps through registries

zigsaw images are standard OCI images, so any OCI registry can hold them:
ghcr.io, Docker Hub, a self-hosted zot or distribution. An image is named
`<registry>/<repository>[:tag][@digest]`, or just by app id for the app's
image in the default registry:

```powershell
zigsaw pull org.nodejs.node                           # ghcr.io/zigsaw-io/org.nodejs.node:latest
zigsaw pull org.nodejs.node:24.21.0                   # a version
zigsaw push org.nodejs.node ghcr.io/you/node          # tagged 24.21.0, the app's version
zigsaw pull ghcr.io/you/node:24.21.0                  # on another machine
zigsaw pull ghcr.io/you/node@sha256:f25237a3...       # exactly this build
```

An app id stands for `<default registry>/<app id in lower case>`, and the
image must hold that app. The default registry is `ghcr.io/zigsaw-io`; set
`ZIGSAW_REGISTRY` to use another, such as your own:
`ZIGSAW_REGISTRY=ghcr.io/you`. Then `zigsaw push <app-id>` publishes an app to
its image there. Installed apps remember the full reference they came from,
so `zigsaw update` keeps using it.

The manifest travels byte for byte, so an image has the same digest in every
store and registry. `pull` downloads only blobs the store doesn't have, checks
each one against its digest, and refuses images that aren't zigsaw apps
(such as Docker container images). Like `build`, it shows what the app is
allowed to reach before you run it.

`push` uploads only blobs the repository doesn't have. A blob the registry
already holds in another repository is mounted from there, which uploads
nothing:

- an app's runtime layers, from the runtime's own repository next to the
  app's, where `zigsaw push <runtime id>` puts it: pushing
  `io.prettier.prettier` by app id mounts Node's layer from
  `org.nodejs.node`;
- all of an app pulled from another repository on the same registry, from
  that one.

Registries that can't mount, or won't, get the blob uploaded instead.

Registries on `localhost` are reached over plain HTTP; all others over HTTPS.

### Sources next to images

Downloads go away: a project moves its files, or its server refuses
everyone. A recipe pins each file by its sha256, which is also the digest an
OCI registry stores a blob under, so a registry can keep them:

```powershell
zigsaw push --sources net.frippery.busybox
```

- **`push --sources`** also pushes the files the app was built from (its
  sources and what its [vendor steps](#vendor-steps) made, from the download
  cache) to the image's repository, under a manifest tagged
  `sha256-<image digest>.sources`, which keeps the registry from deleting
  them.
- **A build falls back to them.** When a pinned source's URL fails, or no
  longer serves the pinned file, `zigsaw build` fetches the file by its
  sha256 from next to the image of the recipe's app in the default registry,
  and checks it. So does a vendor step whose commands fail. The image is the
  same either way.
- [`scripts/publish.sh`](scripts/publish.sh) pushes the published images'
  sources, so their recipes build even when an upstream server is gone, as
  BusyBox's was in October 2026.

### Logging in

Anonymous pulls of public images work without setup. Pushing, and pulling
private images, needs a login:

```powershell
zigsaw login ghcr.io                                          # asks for a user name and password
$env:TOKEN | zigsaw login --username=you --password-stdin ghcr.io
zigsaw logout ghcr.io
```

`login` checks the credentials with the registry, then saves them in Windows
Credential Manager as `zigsaw:<registry>`, for your Windows user only. A
login is only ever sent to its own registry. For ghcr.io, the user name is
your GitHub user name, and the password a token with the `write:packages`
scope (or `read:packages`, to pull private images).

For CI and scripts, `ZIGSAW_REGISTRY_USERNAME` and `ZIGSAW_REGISTRY_PASSWORD`
work without a login, but only for the default registry: ghcr.io, or the host
in `ZIGSAW_REGISTRY`. There they take the place of a saved login. `-v` shows
which credentials a command uses. zigsaw doesn't send credentials to a token
service over plain HTTP, unless the registry is on `localhost`.

## Updating and cleaning up

`zigsaw update` brings every installed app, or the ones named, up to date
with where it came from. An app built from a recipe is rebuilt from that
recipe file, so editing the recipe and running `update` installs the new
version. An app pulled by tag is pulled again if the tag now points at a
different image; only the manifest is fetched when it doesn't. An app pulled
by digest is pinned and left alone.

Installing a new version deletes the files of the one it replaces, unless
that version is still running. `zigsaw prune` deletes everything else no
installed app needs: the blobs of old versions, files kept because they were
running, and whatever an interrupted build left in `tmp\`. `--dry-run` shows
what it would delete. Cached downloads, the runtimes that builds used, and
build tools' caches are kept for rebuilds unless you add `--downloads`. The data of uninstalled
apps is kept unless you add `--data`.

Nothing a running app uses is deleted, and zigsaw commands can run at the same
time: a run locks the files it uses, and `prune` waits for builds and pulls
to finish.

## Running apps

`run` options go before the app id, as with `flatpak run`:

| Option | Effect |
|---|---|
| `--command=<name>` | Run one of the app's exported commands, or another executable or batch file from the app's PATH or System32 (e.g. `--command=cmd`) |
| `--sandbox=soft\|low\|appcontainer` | `soft` (default) shapes the environment only; `low` also keeps the app from writing anywhere but its data directory and the paths granted; `appcontainer` enforces all permissions |
| `--filesystem=<cwd\|path>[:ro]` | Grant access to a host location |
| `--share=network` / `--unshare=network` | Override the app's network permission |
| `--env=NAME=VALUE` | Set an environment variable |
| `--ephemeral` | Use a fresh data directory, deleted after the run |
| `-v`, `--verbose` | Print the resolved command, environment and grants |

### Batch files

An app's command, an export, or a `--command` can be a batch file (`.cmd` or
`.bat`). zigsaw runs it through System32's `cmd.exe`, and quotes the arguments
so that the batch file gets each one exactly as given. Characters that
cmd.exe would act on, such as `&`, `|`, `%` and `^`, can't run a command of
their own. An argument with a line break can't be passed to a batch file
safely, so it's refused.

The commands of global npm packages, such as `tsc.cmd`, are batch files.

Ctrl+C behaves as when the batch file runs alone: the program it started gets
the Ctrl+C, and cmd.exe then asks "Terminate batch job (Y/N)?".

### Commands installed while an app runs

Package managers install commands too: `npm install -g typescript` puts
`tsc` in npm's global prefix, which Node's recipe keeps in its data
directory. After each run of an app, zigsaw gives the commands in its PATH
entries in `${data}` shims, as it does exports, and removes the shims of
commands that are gone:

```powershell
npm install -g typescript   # through the npm shim
tsc --version
```

- A command is an `.exe`, `.com`, `.cmd` or `.bat` file directly in such a
  directory. Its shim runs `zigsaw run --command=<name> <app>`, so it runs
  in the app's environment.
- The app's exports win over a command of the same name, and a name another
  app provides is left to it.
- An `--ephemeral` run's commands get none: they're deleted with its data
  directory.
- Rebuilding or updating the app keeps them, `zigsaw rm` removes them, and
  `zigsaw list` shows them with the exports.

Rust's image keeps cargo's home in its data directory, so what
`cargo install` installs gets a shim too.

### GUI apps

A command whose executable is a GUI program (its PE header says so, as
`gtk4-demo.exe`'s does) gets a shim that is one too, `zigsaw-shimw.exe`, as
Python has `pythonw.exe`. Started from Explorer or the Start menu, it opens no
console window, and neither does the zigsaw it starts. Started from a
terminal, it returns at once, as GUI programs do in cmd and PowerShell.

Without a console, error messages would go nowhere, so when whoever started
the shim gave it no file or pipe for stderr, it keeps the end of what zigsaw
and the app write there, and if the app fails, shows it in a message box
with the exit code. With a pipe or file for stderr, as in Git Bash or with
`2>log.txt`, the output goes there instead.

### Start menu shortcuts

A recipe can declare shortcuts to its exports, as Flatpak apps export
`.desktop` files:

```json
"shortcuts": {
  "Text Editor": { "command": "gnome-text-editor", "description": "View and edit text files" }
}
```

Installing the app puts `Text Editor.lnk` in a `Zigsaw` folder of your
Start menu. It runs the export's shim, from the app's home in its data
directory, with the icon of `icon` (an `.ico`, or an `.exe` or `.dll` with
one, in the app or a runtime) or of the export's executable. Updating the
app rewrites its shortcuts and removes those it no longer declares, and
`zigsaw rm` removes them; `zigsaw list` shows them.

Only the default store (`%LOCALAPPDATA%\zigsaw`) adds to the Start menu, so
test stores don't. `ZIGSAW_SHORTCUTS_DIR` names a folder to use instead, for
any store. zigsaw only changes `.lnk` files that run a shim of its own store,
and leaves any other file of the same name alone, with a warning.

### Changing an app's options

`zigsaw override` saves run options for an app, and every run of it gets them,
including runs through its commands on PATH. It takes the same options as
`run`, except `--command`:

```powershell
zigsaw override --sandbox=appcontainer com.github.BurntSushi.ripgrep   # rg is always sandboxed
zigsaw override --sandbox=low org.nodejs.node                          # node writes only its data and cwd
zigsaw override --filesystem=D:\src org.nodejs.node                    # node can use D:\src
zigsaw override --show org.nodejs.node                                 # what's saved
zigsaw override --reset org.nodejs.node                                # remove them all
```

New options are added to the ones already saved; a filesystem path or
variable given again replaces its earlier setting. Options given to `run`
still win for that run. Overrides are kept when an app is updated, rebuilt or
removed, and `zigsaw rm --delete-data` deletes them with the app's data.
`zigsaw list` shows them.

## Recipes

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
directory, or out of the archive, fails the build.
`cleanup` leaves files out of the app: `"/include"` is a path from
the top, and `"*.pdb"` a file name pattern that matches anywhere. Building the
same recipe always produces the same image digest.

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

### Runtimes

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
and its `env` before the app's, so Prettier's runs have npm's settings as
Node's do. Runtimes can't have runtimes of their own.

A pinned runtime doesn't change by itself: moving Prettier to a newer Node
is an edit to its recipe, like a new source hash.

### Images as sources

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
Its layer isn't unpacked again: the files stream from its deployment into
the new layer. The config records the image's digest under `build.images`,
so the runtime depends only on the SDK image, and builds again with the same
digest without building the SDK.

### Building from source

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
  Unix toolbox.
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
under the names build scripts and makefiles expect, and `dlltool`, which
Rust needs:

```json
"aliases": {
  "cc": { "command": "zig.exe", "args": ["cc", "-target", "x86_64-windows-gnu"] },
  "c++": { "command": "zig.exe", "args": ["c++", "-target", "x86_64-windows-gnu"] },
  "ar": { "command": "zig.exe", "args": ["ar"] },
  "ranlib": { "command": "zig.exe", "args": ["ranlib"] },
  "rc": { "command": "zig.exe", "args": ["rc"] },
  "dlltool": { "command": "zig.exe", "args": ["dlltool"] }
}
```

Aliases are like exports, but for builds rather than for you: each one is
`B:\bin\<name>.exe` while a build that uses the image runs, first on its
PATH. It runs the command with the alias's arguments, then its caller's, in
the caller's environment. If two images alias the same name, the one listed
first in the recipe wins. Aliases also win over BusyBox's applets of the
same name, which its sh would otherwise run instead of anything on PATH
(zig's `ar` over BusyBox's): builds list them in `BB_OVERRIDE_APPLETS`.

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

### Vendor steps

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

### CMake

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

### Meson

The Meson image, [`com.mesonbuild.meson`](recipes/meson.json), is Python's
embeddable distribution with Meson's source release, Ninja, and pkgconf,
which the recipe builds from source with that Meson and zig. Builds get
`meson`, `ninja` and `pkg-config` as [aliases](#building-from-source); run
as an app, it's `meson`. With zig in the SDK too, Meson takes zig's
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

### GTK

GTK 4 comes as two images, as Flatpak's GNOME runtime does:

- **[`org.gtk.Gtk4.Sdk`](recipes/gtk4-sdk.json)** builds GTK 4.24.1 and
  everything it needs from source with Meson, CMake and zig: zlib, libpng,
  libjpeg-turbo, libtiff, PCRE2, libffi, GLib 2.90, pixman, FriBidi,
  HarfBuzz, cairo, Pango, graphene, libepoxy, gdk-pixbuf, Microsoft's
  DirectX headers, and GTK, with its demos, then the hicolor and Adwaita
  icon themes and libadwaita 1.10, with its demo. It keeps their headers,
  import libraries and pkg-config files, so apps build against it by listing
  it in their `sdk`. It takes about 15 minutes to build from scratch.
- **[`org.gtk.Gtk4`](recipes/gtk4.json)** is the runtime: the SDK's files
  as an [image source](#images-as-sources), without the headers, libraries
  and build tools, so it builds in seconds once the SDK is there. Apps list
  it in their `runtimes`. As an app, it runs `gtk4-demo`, exports
  `gtk4-demo`, `gtk4-node-editor`, `gtk4-print-editor`,
  `gtk4-query-settings` and `adwaita-1-demo`, and adds "GTK Demo" and
  "Adwaita Demo" to the Start menu.

An app built against GTK, as [`tests/gtk`](tests/gtk) is:

```json
"command": "bin/hello-gtk.exe",
"path": ["bin"],
"runtimes": { "gtk": "org.gtk.Gtk4:4.24.1@sha256:..." },
"sdk": {
  "gtksdk": "org.gtk.Gtk4.Sdk:4.24.1@sha256:...",
  "meson": "com.mesonbuild.meson:1.12.1@sha256:...",
  "zig": "org.ziglang.zig:0.16.0@sha256:...",
  "busybox": "net.frippery.busybox:FRP-6075-g169694ebd@sha256:..."
},
"modules": [
  {
    "name": "hello",
    "sources": [{ "path": "meson.build" }, { "path": "hello.c" }],
    "build": ["meson setup out --prefix=\"$PREFIX\"", "meson install -C out"]
  }
]
```

Meson finds `gtk4` through the SDK's pkg-config files. When the app runs,
Windows finds GTK's DLLs on PATH, in the runtime's `bin`. The runtime's
variables keep GLib's files in the app's data directory (`XDG_CONFIG_HOME`
and the rest; otherwise GLib asks Windows for the user's AppData folder,
bypassing zigsaw's), and its settings in a key file there
(`GSETTINGS_BACKEND=keyfile`; otherwise the registry). GTK draws with cairo
by default on Windows; `--env=GDK_DEBUG=dcomp` turns on DirectComposition,
and with it OpenGL. GTK apps run in all three sandboxes.

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
- cairo's script tool prints `__DATE__`, which zig refuses when optimizing
  (`-Wno-error=date-time`; builds fix the date with `SOURCE_DATE_EPOCH`),
  and CRoaring in GTK leaves out its AVX-512 code, which zig's generic
  x86-64 target can't compile.

### Rust

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
way that makes rustc run `dlltool`. The `dlltool` Rust ships needs an
assembler that Rust doesn't ship
([rust-lang/rust#103939](https://github.com/rust-lang/rust/issues/103939)).
zig's image gives builds its own `dlltool` as an alias, and that one needs
none.

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

The image sets `CARGO_HOME` to `${data}\cargo`. Run as an app, cargo keeps
its home in its data directory, and what `cargo install` installs is a
[command on PATH](#commands-installed-while-an-app-runs). In builds, it's
`B:\data\cargo`, fresh for each build.

### Go

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

### MSVC

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

## How it works

**Images** are standard OCI image manifests with a zigsaw config
(`application/vnd.zigsaw.app.config.v2+json`) and deterministic tar layers,
gzip-compressed (`application/vnd.oci.image.layer.v1.tar+gzip`), so any OCI
registry can store them. The layers are those of the app's runtimes, in the
order the config lists them, then one of the app's own files. The config also
records how the image was built: the hash of every source, and any SDK
images. zigsaw still reads the plain tar layers of images made before
iteration 7, and the v1 configs of images made before runtimes existed;
older versions of zigsaw refuse v2 images, and gzip layers.

**Builds** without build commands never unpack sources to disk. zigsaw
indexes the files each source contributes and streams them from the
downloads and archives straight into the layer, compressing and hashing it on
the way. Compressed source tars are decompressed once, into the download
cache. The app's files are created once, when the layer is deployed (a gzip
layer is decompressed first, to a temporary tar), by several workers in
parallel. Rebuilding such an app creates no files at all. Creating files is
the slow part on Windows, because Defender scans each new one. Builds with
build commands need real files, so they unpack their sources into a directory
under `tmp\`, mapped to `B:`, and make the layer from what ends up in
`B:\prefix`.

**Store** (`%LOCALAPPDATA%\zigsaw`, or `%ZIGSAW_HOME%`):

```
blobs\sha256\<hex>     manifests, configs, layers
refs\<id>.json         installed app -> manifest digest
deploy\<hex>\          an unpacked layer, by layer digest, shared by all runs and apps
data\<id>\             per-app writable state, kept across runs
grants\<id>.txt        host paths granted to the app's AppContainer, or labelled low for its runs
overrides\<id>.json    run options saved with `zigsaw override`
bin\<name>.exe         command shims, with a <name>.shim file saying what each runs
cache\downloads\<hex>  fetched sources, by sha256 (and decompressed tars)
cache\images\<hex>     marks images that builds use as runtimes or SDKs, kept like downloads
cache\builds\<hex>     the image of an earlier build, by a hash of its inputs
cache\tools\<id>\      the cache of a build tool whose image uses ${cache}
tmp\                   staging area, and the data of --ephemeral runs
lock, *.lock           lock files that let zigsaw commands run side by side
```

**Command shims** are copies of the small `zigsaw-shim.exe` that is installed
next to `zigsaw.exe`. A shim reads its `.shim` file and runs
`zigsaw run --command=<name> <app>` with the caller's arguments exactly as
typed, and exits with the app's exit code. Shims are real executables rather
than `.cmd` scripts, so programs that start `node` or `git` directly find
them, and Ctrl+C doesn't ask "Terminate batch job?". Commands that are GUI
programs get `zigsaw-shimw.exe` instead, the same program built as a GUI
one, which starts zigsaw without a console (`DETACHED_PROCESS`); zigsaw
reads the subsystem from the executable's PE header when it writes the
shim. [Start menu shortcuts](#start-menu-shortcuts) are `.lnk` files that
run these shims.

**Runs** get an environment built from scratch: `PATH` is the app's
directories, then its runtimes', then System32. `USERPROFILE`, `APPDATA`,
`LOCALAPPDATA` and `TEMP` point into `data\<id>\home`. The working directory
is that home folder unless the app has the `cwd` filesystem permission. A job
object ends the whole process tree when the run ends. Deployed files deny
writes and deletes to the user, so no run, and nothing else running as you,
can change an installed app or runtime.

The app shares the terminal, so Ctrl+C and Ctrl+Break reach it just as when
it runs alone, also through a shim. zigsaw waits for it and passes on its
exit code. Closing the terminal gives the app the usual time to clean up.
Whatever the app leaves running then ends with the run, even processes it
started detached.

**`--sandbox=low`** runs the app at low integrity, with a copy of your token
that Windows lets any program make of its own. The app can then write only
where the integrity label is low: zigsaw labels its data directory, and the
host paths it may write (`cwd` and `--filesystem` paths without `:ro`). It
can still read whatever you can, and use the network. Every tool the matrix
runs works this way, including git, npm and zig builds.

- A label lasts until `zigsaw rm` removes the app, and is inherited by
  everything below the path. Meanwhile any low-integrity program can write
  there, not only the app. Removing an app keeps the labels other apps' runs
  need, and labels zigsaw didn't make.
- zigsaw won't label a drive's root, your user profile, or a directory your
  profile is in; grant a directory inside it, or read-only access.
- The first label of a large tree takes a while, as Windows labels every
  file below it: about 2 s for 20,000 files.

**`--sandbox=appcontainer`** also runs the app under a per-app AppContainer
identity (`zigsaw.<id>`). It can then read and write only its data directory,
read its own files and its runtimes', and use the host paths and network it
was granted.
Grants are ACL entries for a capability of the app's own, which only its runs
hold; `zigsaw rm` removes those on host paths again. (An entry for the
AppContainer's own SID, as zigsaw made before, would keep low-integrity
programs out of the files: see [findings](docs/findings.md).)
Windows gives an AppContainer a temporary directory of its own, under
`LOCALAPPDATA`, so zigsaw makes that one in the data directory too.
It suits self-contained tools such as busybox, ripgrep, bat, fzf, zot and
zstd. What else works depends on the version of Windows, as it decides what
AppContainers may do:

- **Windows 11 26300.9550** lets them resolve real paths, so Python, zig,
  CMake and Go builds work too. It doesn't let them see directories that
  grant them nothing, such as the drive root. Git's and Node's recipes set
  variables that keep them from looking there where they can: git's
  configuration, `ls-remote`, Node scripts and `npm install` work, but
  `git init`/`commit`, `npm install -g` and Node's `fs.realpathSync` don't.
- **Older builds of Windows 11** didn't let them resolve real paths, which
  git, Node, zig and CMake need.
- **Windows Server 2025** doesn't let them open `NUL`, so git doesn't start
  at all, and Go builds fail.

See [findings](docs/findings.md). `tests/matrix.sh` checks what the Windows
it runs on allows, and prints it.

## Testing

```bash
zig build test          # unit tests
bash tests/matrix.sh    # runs real tools through the three sandboxes (Git Bash, network)
bash tests/sandbox.sh   # what the low and appcontainer sandboxes change on the host, and rm undoes
bash tests/shims.sh     # command shims end to end, also for commands installed at run time and GUI programs; Start menu shortcuts
bash tests/store.sh     # update, prune, and what they keep while apps run
bash tests/build.sh     # building apps: runtimes, images as sources, build commands on B:, tool caches, aliases, vendor steps, CMake, Meson, Rust, Go, cgo, reproducibility
bash tests/gtk.sh       # a GTK and libadwaita app built against GTK's SDK, on its runtime, in each sandbox; the GUI shim and shortcuts; Text Editor (needs GTK_HOME or BUILD_HOME; opens windows; local only)
bash tests/ctrlc.sh     # Ctrl+C, Ctrl+Break and closing the console, in a pseudoconsole
bash tests/batch.sh     # batch files as commands: arguments arrive exactly, and run nothing
bash tests/registry.sh  # push, pull, update, mounts, logins and sources next to images, through local registries (see its header)
bash tests/published.sh # fresh builds have the published digests; anonymous pulls, latest, redirects
```

The scripts build the recipes they need from [recipes/](recipes/) into
temporary stores unless `ZIGSAW_HOME` points at one. Set `SEED_DOWNLOADS` to
another store's `cache\downloads` and they take the files from there instead
of downloading them. The matrix reports every check whose result differs from
zigsaw's intended behaviour, and fails for those; it also shows the known
gaps below that it runs into, but doesn't fail for them. It first runs a
probe ([`tests/acprobe.zig`](tests/acprobe.zig)) in an AppContainer, and
expects the AppContainer gaps whose causes the probe finds lifted to pass.
The registry tests need a local registry such as
[zot](https://zotregistry.dev) on `localhost:5000`;
[`tests/zot.sh`](tests/zot.sh) starts two, one of them wanting a login. They
are the zot that [`recipes/zot.json`](recipes/zot.json) builds, run by
zigsaw, from the store in `ZOT_HOME` or `BUILD_HOME`; without either, it
builds zot in a temporary store first:

```bash
ZOT_HOME=path/to/a/store/with/zot bash tests/zot.sh bash tests/registry.sh
```

The [Reproduce workflow](.github/workflows/reproduce.yml) runs all of them on
a fresh runner, after `published.sh`, with its build store as
`SEED_DOWNLOADS`, and as the matrix's store.

## Known gaps

- A command an app's run installs that names the app's files by their
  absolute path, as pip's launchers name their `python.exe`, stops working
  when an update deploys the app elsewhere. npm's and cargo's don't.
- A batch file that turns on delayed expansion itself
  (`setlocal EnableDelayedExpansion`) expands `!var!` in its own arguments.
- Node's image sets `NODE_OPTIONS=--preserve-symlinks
  --preserve-symlinks-main`, so that Node works under AppContainer. A
  package linked in with a symlink (`npm link`, workspaces, pnpm) then finds
  its dependencies from where the link is, not where the package is, in every
  sandbox.
- Under `--sandbox=appcontainer`, access granted to a host path lasts until
  the app is removed, even after the permission or override that granted it
  is gone, and so does a low integrity label under `--sandbox=low`.
- `--sandbox=low` confines writing only: the app can read whatever you can,
  and use the network whatever its permissions say. At low integrity,
  writing to the registry fails outside `HKCU\Software\AppDataLow`, and the
  few directories Windows labels low itself, such as `AppData\LocalLow`, can
  be written.
- A host path an earlier zigsaw granted an app's AppContainer, to the
  container's own SID, keeps other apps' low runs out until that app runs
  under `--sandbox=appcontainer` again, or is removed; that app's own low
  runs clear it too. In the store, runs clear such grants from what they
  use.
- Apps that locate folders with `SHGetKnownFolderPath` instead of environment
  variables would bypass the data-directory redirect. None of the tested tools
  do.
- Installing an app with many files is limited by Defender scanning each new
  file: about 16 s for zig's 19.5k files, 3 s for Node.
- The registry isn't isolated.
- zigsaw keeps its own registry logins; it doesn't read Docker's
  `config.json` or credential helpers.
- Multi-platform image indexes aren't supported.
- Runtimes can't have runtimes of their own.
- Pushing mounts a runtime's layer only from the runtime's repository in the
  default layout, and an app's blobs only from where it was pulled. A blob
  the registry holds elsewhere is uploaded again.
- Each blob goes up in one request, so an upload that breaks off starts
  again from the beginning, and registries that limit a request's size can't
  take big layers.
- A layer's compressed bytes, and so every image's digest, are what the
  deflate of the Zig that zigsaw is built with makes. A Zig whose deflate
  changed would make other digests from the same files; CI pins Zig 0.16.0.
- Build steps are kept off the network by convention (proxy variables), not
  enforced: a tool that ignores them can still download.
- Builds need `B:` free, and run one at a time.
- Builds with MSVC depend on the machine's Visual Studio, so they don't
  reproduce elsewhere, and CI doesn't check them. Only x64 MSVC builds are
  set up.
- Vendor steps run their commands with network access and nothing more
  confining than a build's sandbox; only what they leave in their directory
  is pinned.
- Rust builds need zig in their SDK, for `dlltool` and C. Only the
  `x86_64-pc-windows-gnu` target is set up. Crates' C code is compiled with
  fixed flags rather than the profile's, against zig's UCRT headers but
  linked with Rust's `msvcrt.dll` libraries; C code that needs what only UCRT
  has would fail to link.
- Rust builds need the store's path to be shorter than about 100
  characters: rustc starts its linker from the Rust image's deployment, and
  can't start a program whose path is longer than Windows' 260 characters.
  The default store, `%LOCALAPPDATA%\zigsaw`, is well within that.
- cgo works only in builds that list zig in their SDK. `go build` run as an
  app has no C compiler: aliases are only for builds, and Go's image can't
  have zig as a runtime. Until zig's `cc -###` succeeds, recipes that use
  cgo have to leave out Go's build ID (`-ldflags=-buildid=`), and their
  executables are stripped.
- CMake run as an app has no compiler either, for the same reason; it's
  for builds, and for `cmake -E` and scripts. When a command it runs can't
  be started while other commands are running, Ninja 1.13.2 stops with
  `ninja: fatal: ReadFile: The handle is invalid.` (once, it crashed with
  `0xC0000409`) instead of reporting the command.
- Executables built with zig's `LDFLAGS` or `CGO_LDFLAGS` have no debug
  information, as a PDB would differ from build to build.
- A Go vendor step downloads every module its `go.mod` names, whatever the
  build uses: zot's takes 14 minutes and 5 GB of temporary space, for the
  68 MB it keeps.
- zig's `rc` alias runs `zig rc` as it is, which includes Visual Studio's
  headers when the machine has Visual Studio, and zig's MinGW headers
  otherwise. A resource script that includes a header only one of them has
  builds on some machines and not others. GTK's recipe passes
  `/:auto-includes gnu`; zig's image doesn't, yet.
- DLLs that zig links without any `dllexport` export the C runtime's
  `atexit`, `_CRT_INIT` and `__mingw_module_is_dll` too, unless the link
  includes an object that excludes them, as GTK's SDK recipe does.
- A GUI app whose executable is built as a console program, as
  libadwaita's demo is upstream, gets a console shim, and a console window
  from the Start menu; its recipe has to build it as a GUI program
  (libadwaita's sets Meson's `win_subsystem`).
- Start menu shortcuts show the icon of the export's executable, and none
  of GTK's or Text Editor's has one: their icons are SVGs, which a `.lnk`
  can't use. A recipe can point `icon` at an `.ico`. Pinning a running GTK
  app's window to the taskbar pins its executable in the store, not the
  shortcut, since zigsaw sets no AppUserModelID.
- GTK's widget factory aborts at startup: its window loads an SVG through
  gdk-pixbuf, which has no SVG loader without librsvg. GTK's own SVG
  renderer covers icon themes only. The runtime doesn't export it.
- Text Editor has no spell checking (libspelling is built without enchant),
  no translations (no gettext tools in the SDK) and no help pages (no yelp
  on Windows).
- Under `--sandbox=appcontainer`, DirectWrite can't open fonts installed
  for the user only, rather than for the machine; GTK warns, and draws
  with the others.

[docs/iteration-11.md](docs/iteration-11.md) lists what hasn't been tested yet.
