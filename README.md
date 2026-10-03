# Zigsaw

Image-based container solution for running sandboxed program on Windows.

Think Flatpak for Windows programs: apps are built from pinned sources into
OCI-style images, installed per user, and run in a clean environment with their
own data directory. No admin rights, no Hyper-V; it works on Windows Home.

Status: [iteration 6](docs/iteration-6.md) is complete. Zigsaw builds
command-line apps from source or from official binaries, runs them on shared
runtimes, installs, updates and cleans them up, shares them through
registries, and puts their commands on PATH, also those they install while
they run. Builds run with pinned toolchain images (zig, BusyBox, Rust), or
the machine's MSVC, and reproduce: CI checks that the recipes build the same
images on a fresh machine, and runs the end-to-end tests there. Registries
keep the files images were built from, so recipes build even when a download
is gone. Git, Node, Python, SQLite, ripgrep, bat and the zig and Rust
toolchains are tested.

## Quick start

Requires Zig 0.16.

```powershell
zig build
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
zigsaw list                            list installed apps and their commands
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

Prettier runs on Node as a [runtime](#runtimes): its image brings Node's
files along, without installing Node as an app. SQLite, ripgrep and bat are
[built from source](#building-from-source): SQLite with zig and BusyBox,
ripgrep and bat with [Rust](#rust), zig and BusyBox, whose images are their
SDK. bat's C libraries (oniguruma, libgit2, zlib) are compiled by zig.
Pulling them doesn't need those.

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
| `--sandbox=soft\|appcontainer` | `soft` (default) shapes the environment only; `appcontainer` also enforces permissions |
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

### Changing an app's options

`zigsaw override` saves run options for an app, and every run of it gets them,
including runs through its commands on PATH. It takes the same options as
`run`, except `--command`:

```powershell
zigsaw override --sandbox=appcontainer com.github.BurntSushi.ripgrep   # rg is always sandboxed
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
once and the build error prints the hash to pin) or a local `path`. A source
is a single `file`, or an archive (`zip`, `tar`, `tar.gz`/`tgz` or `tar.xz`)
extracted into `dest` with optional `strip`. The type is inferred from the
file name. `cleanup` leaves files out of the app: `"/include"` is a path from
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

Two things about zig's C compiler, for executables that reproduce:

- **Name the target.** Without `-target`, `zig cc` builds for the machine
  it runs on, its CPU and Windows version included, so a build elsewhere
  differs, and the result may not run on older CPUs. The recipes pass
  `-target x86_64-windows-gnu`, and the `cc` and `c++` aliases do.
- **Pass `-s`.** Otherwise it writes a PDB with each executable, and those
  differ from build to build. zig also refuses `__DATE__` and `__TIME__`,
  which would differ too.

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
(`application/vnd.zigsaw.app.config.v2+json`) and plain, deterministic tar
layers, so any OCI registry can store them. The layers are those of the app's
runtimes, in the order the config lists them, then one of the app's own
files. The config also records how the image was built: the hash of every
source, and any SDK images. zigsaw still reads the v1 configs of images made
before runtimes existed; older versions of zigsaw refuse v2 images.

**Builds** without build commands never unpack sources to disk. zigsaw
indexes the files each source contributes and streams them from the
downloads and archives straight into the layer, hashing it on the way.
Compressed tars are decompressed once, into the download cache. The app's
files are created once, when the layer is deployed, by several workers in
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
grants\<id>.txt        host paths granted to the app's AppContainer
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
them, and Ctrl+C doesn't ask "Terminate batch job?".

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

**`--sandbox=appcontainer`** also runs the app under a per-app AppContainer
identity (`zigsaw.<id>`). It can then read and write only its data directory,
read its own files and its runtimes', and use the host paths and network it
was granted.
Host grants are ACL entries on those paths; `zigsaw rm` removes them again.
It suits self-contained tools such as busybox, ripgrep and bat. Git, Node
scripts, npm and zig fail under it, because Windows doesn't let AppContainers
resolve real paths, and on Windows Server 2025 git doesn't start at all; see
[findings](docs/findings.md).

## Testing

```bash
zig build test          # unit tests
bash tests/matrix.sh    # runs real tools through both sandboxes (Git Bash, network)
bash tests/shims.sh     # command shims end to end, also for commands installed at run time
bash tests/store.sh     # update, prune, and what they keep while apps run
bash tests/build.sh     # building apps: runtimes, build commands on B:, tool caches, aliases, vendor steps, Rust, reproducibility
bash tests/ctrlc.sh     # Ctrl+C, Ctrl+Break and closing the console, in a pseudoconsole
bash tests/batch.sh     # batch files as commands: arguments arrive exactly, and run nothing
bash tests/registry.sh  # push, pull, update, logins and sources next to images, through local registries (see its header)
bash tests/published.sh # fresh builds have the published digests; anonymous pulls, latest, redirects
```

The scripts build the recipes they need from [recipes/](recipes/) into
temporary stores unless `ZIGSAW_HOME` points at one. Set `SEED_DOWNLOADS` to
another store's `cache\downloads` and they take the files from there instead
of downloading them. The matrix reports every check whose result differs from
zigsaw's intended behaviour, and fails for those; it also shows the known
gaps below that it runs into, but doesn't fail for them. The registry tests
need a local registry such as
[zot](https://zotregistry.dev) on `localhost:5000`;
[`tests/zot.sh`](tests/zot.sh) starts two, one of them wanting a login:

```bash
bash tests/zot.sh path/to/zot.exe bash tests/registry.sh
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
- Under `--sandbox=appcontainer`, access granted to a host path lasts until
  the app is removed, even after the permission or override that granted it
  is gone.
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
- Pushing an app uploads its runtimes' layers to the app's repository, even
  when the registry has them in another one.
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

[docs/iteration-6.md](docs/iteration-6.md) lists what hasn't been tested yet.
