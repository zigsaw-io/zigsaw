# Zigsaw

Image-based container solution for running sandboxed program on Windows.

Think Flatpak for Windows programs: apps are built from pinned sources into
OCI-style images, installed per user, and run in a clean environment with their
own data directory. No admin rights, no Hyper-V; it works on Windows Home.

Status: [iteration 3](docs/iteration-3.md) is complete. Zigsaw builds,
installs, runs, updates and cleans up command-line apps, shares them through
registries, and puts their commands on PATH. Published apps install by id,
and CI checks that their recipes build the same images on a fresh machine.
Logins are kept per registry, and batch files run as commands. Git, Node,
Python and the zig toolchain are tested.

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
zigsaw build <recipe.json>             build an app from a recipe, install it and its commands
zigsaw pull <image>                    install an app and its commands from a registry
zigsaw push <app-id> [<image>]         publish an installed app to a registry
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

The recipes in [recipes/](recipes/), except zig's, are published as images in
`ghcr.io/zigsaw-io`, tagged with their version and `latest`, so these install
with `zigsaw pull <id>`:

| App | Id | Version | Commands |
|---|---|---|---|
| BusyBox | `net.frippery.busybox` | FRP-6075-g169694ebd | `busybox` |
| ripgrep | `com.github.BurntSushi.ripgrep` | 15.2.0 | `rg` |
| Git (MinGit) | `org.git_scm.MinGit` | 2.56.0.windows.1 | `git` |
| Node.js | `org.nodejs.node` | 24.21.0 | `node`, `npm`, `npx` |
| Python | `org.python.python` | 3.14.7 | `python` |

[`scripts/publish.sh`](scripts/publish.sh) publishes the recipes listed in
[`scripts/published-recipes.txt`](scripts/published-recipes.txt).

### Reproducibility

Each image has the same digest as a build of its recipe on any machine:
sources are pinned by SHA-256, and builds write deterministic layers. The
[Reproduce workflow](.github/workflows/reproduce.yml)
([runs](https://github.com/zigsaw-io/zigsaw/actions/workflows/reproduce.yml))
checks this on every push to `main` and every pull request. On a fresh
Windows runner, it runs the unit tests, builds each published recipe, and
compares the digest with the image published for the recipe's version
([`tests/published.sh`](tests/published.sh)).

- A version that isn't published yet is reported, but doesn't fail the run.
- A different digest for the same version fails it. Either the build isn't
  reproducible, or the recipe changed without a new version.

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
what it would delete. Cached downloads are kept for rebuilds unless you add
`--downloads`, and the data of uninstalled apps is kept unless you add
`--data`.

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

The commands of global npm packages are batch files, so after
`zigsaw run --command=npm org.nodejs.node install -g typescript`, this runs `tsc`:

```powershell
zigsaw run --command=tsc org.nodejs.node --version
```

Ctrl+C behaves as when the batch file runs alone: the program it started gets
the Ctrl+C, and cmd.exe then asks "Terminate batch job (Y/N)?".

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

A recipe is a JSON file listing pinned sources and how the app runs:

```json
{
  "id": "net.frippery.busybox",
  "version": "FRP-6075-g169694ebd",
  "command": "busybox.exe",
  "path": ["."],
  "env": {},
  "permissions": { "network": false, "filesystem": [] },
  "sources": [
    {
      "url": "https://frippery.org/files/busybox/busybox-w64-FRP-6075-g169694ebd.exe",
      "sha256": "07bb1e5b095b00d68a695481f9240879f33c5724b40aa2308f999d54ed78f075",
      "dest": "busybox.exe"
    }
  ]
}
```

Sources are either a `url` (a `sha256` is required; leave it out once and the
build error prints the hash to pin) or a local `path`. A source is a single
`file`, or a `zip` extracted into `dest` with optional `strip`. The type is
inferred from the file name. Building the same recipe always produces the
same image digest.

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

`env` values, `path` entries and export arguments can use two placeholders:
`${app}` for the app's directory, and `${data}` for its data directory (the
fresh one, in an `--ephemeral` run). They're expanded each time the app runs,
so the image is the same on every machine. Node's recipe uses them to keep
global npm packages in its data directory, and their commands on its PATH:

```json
"path": [".", "${data}\\npm"],
"env": { "NPM_CONFIG_PREFIX": "${data}\\npm" }
```

## How it works

**Images** are standard OCI image manifests with a zigsaw config
(`application/vnd.zigsaw.app.config.v1+json`) and plain, deterministic tar
layers, so any OCI registry can store them.

**Builds** never unpack sources to disk. zigsaw indexes the files each source
contributes and streams them from the downloads and zip archives straight
into the layer, hashing it on the way. The app's files are created once, when
the layer is deployed, by several workers in parallel. Rebuilding an
installed app creates no files at all. Creating files is the slow part on
Windows, because Defender scans each new one.

**Store** (`%LOCALAPPDATA%\zigsaw`, or `%ZIGSAW_HOME%`):

```
blobs\sha256\<hex>     manifests, configs, layers
refs\<id>.json         installed app -> manifest digest
deploy\<hex>\          unpacked app tree, shared by all runs
data\<id>\             per-app writable state, kept across runs
grants\<id>.txt        host paths granted to the app's AppContainer
overrides\<id>.json    run options saved with `zigsaw override`
bin\<name>.exe         command shims, with a <name>.shim file saying what each runs
cache\downloads\<hex>  fetched sources, by sha256
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
directories plus System32. `USERPROFILE`, `APPDATA`, `LOCALAPPDATA` and `TEMP`
point into `data\<id>\home`. The working directory is that home folder unless
the app has the `cwd` filesystem permission. A job object ends the whole
process tree when the run ends. Deployed app files deny writes and deletes to
the user, so no run, and nothing else running as you, can change an installed
app.

The app shares the terminal, so Ctrl+C and Ctrl+Break reach it just as when
it runs alone, also through a shim. zigsaw waits for it and passes on its
exit code. Closing the terminal gives the app the usual time to clean up.
Whatever the app leaves running then ends with the run, even processes it
started detached.

**`--sandbox=appcontainer`** also runs the app under a per-app AppContainer
identity (`zigsaw.<id>`). It can then read and write only its data directory,
read its own app files, and use the host paths and network it was granted.
Host grants are ACL entries on those paths; `zigsaw rm` removes them again.
It suits self-contained tools such as busybox and ripgrep. Git, Node scripts,
npm and zig fail under it, because Windows doesn't let AppContainers resolve
real paths; see [findings](docs/findings.md).

## Testing

```bash
zig build test          # unit tests
bash tests/matrix.sh    # runs real tools through both sandboxes (Git Bash, network)
bash tests/shims.sh     # command shims end to end
bash tests/store.sh     # update, prune, and what they keep while apps run
bash tests/ctrlc.sh     # Ctrl+C, Ctrl+Break and closing the console, in a pseudoconsole
bash tests/batch.sh     # batch files as commands: arguments arrive exactly, and run nothing
bash tests/registry.sh  # push, pull, update and logins through local registries (see the script's header)
bash tests/published.sh # fresh builds have the published digests; anonymous pulls, latest, redirects
```

The scripts build the recipes they need from [recipes/](recipes/) into
temporary stores unless `ZIGSAW_HOME` points at one. The matrix reports every
check whose result differs from zigsaw's intended behaviour. The registry
tests need a local registry such as [zot](https://zotregistry.dev) on
`localhost:5000`.

## Known gaps

- Commands that an app installs while it runs, such as `tsc` from
  `npm install -g typescript`, run with `zigsaw run --command=tsc org.nodejs.node`,
  but aren't put on PATH.
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

[docs/iteration-3.md](docs/iteration-3.md) lists what hasn't been tested yet.
