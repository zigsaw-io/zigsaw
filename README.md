# Zigsaw

Image-based container solution for running sandboxed program on Windows.

Think Flatpak for Windows programs: apps are built from pinned sources into
OCI-style images, installed per user, and run in a clean environment with their
own data directory. No admin rights, no Hyper-V; it works on Windows Home.

## Quick start

In PowerShell, as yourself (no administrator):

```powershell
irm https://github.com/zigsaw-io/zigsaw/releases/latest/download/install.ps1 | iex
zigsaw pull org.nodejs.node
node -e "console.log(process.version)"
```

The first line installs zigsaw in `%LOCALAPPDATA%\zigsaw\bin` and adds that
directory to your PATH (see [Installing zigsaw](#installing-zigsaw)).
`pull org.nodejs.node` installs the published image of Node (see
[Published apps](#published-apps)), and its commands, here `node`, `npm` and
`npx`, in that same directory, so they run through zigsaw by name.
`zigsaw build recipes\node.json` builds the same image, with the same
digest, from its recipe. `zigsaw search` finds the others, and `zigsaw info`
shows what one is and may reach before you install it (see
[Finding apps](#finding-apps)).

PATH is searched in order, so if another copy of a command comes earlier (say
an installed Node), that one wins. `where node` shows which is found first.

To build zigsaw yourself instead, with Zig 0.16:

```powershell
zig build                # ReleaseSafe by default; -Doptimize=Debug for a quicker compile
.\zig-out\bin\zigsaw.exe pull org.nodejs.node
```

## Installing zigsaw

[`scripts/install.ps1`](scripts/install.ps1), which every
[release](https://github.com/zigsaw-io/zigsaw/releases) carries, installs
zigsaw for you alone, in Windows PowerShell 5.1 or later:

- It downloads the release's `zigsaw-x86_64-windows.zip` and checks it
  against the release's `SHA256SUMS` before changing anything.
- It puts `zigsaw.exe` and its two shim programs in `%LOCALAPPDATA%\zigsaw\bin`,
  where zigsaw puts installed apps' commands too, and adds that directory to
  your PATH, keeping the rest of PATH as it was stored (variables such as
  `%USERPROFILE%` in it stay variables).
- Run it again to upgrade. A zigsaw that's running, because an app it
  started still runs, is moved aside, and the next install deletes it. Then
  `zigsaw repair` writes the installed apps' commands, shortcuts and file
  associations again, as copies of the new shims.

With parameters (`-Version`, `-Dir`, `-NoPath`, `-Uninstall`):

```powershell
& ([scriptblock]::Create((irm https://github.com/zigsaw-io/zigsaw/releases/latest/download/install.ps1))) -Version 0.19.0
```

`-Uninstall` removes zigsaw and its PATH entry once no app is installed
(`zigsaw rm` undoes what zigsaw changed for each app, which deleting its
files wouldn't). The rest of `%LOCALAPPDATA%\zigsaw`, downloads and apps'
data, stays until you delete it.

Releases are published by the [Release workflow](.github/workflows/release.yml)
when a `v<version>` tag is pushed. Their programs are built with
`zig build -Dstrip`, which leaves out the debug information that would name
the directory they were built in, for the x86-64 baseline, whatever CPU
builds them (`build.zig`'s default target), so a build of the same tag with
Zig 0.16.0 gives the same bytes anywhere, and runs on any x64 CPU; the
release notes list their SHA-256. (0.18.0's were built for the CPU of
GitHub's runner, and need AVX2, BMI2 and the SHA instructions.) A build
of 0.19.0, 0.20.0 and 0.21.0 here gave their releases' bytes. From 0.22.0
the programs carry version information, which Explorer's Properties show,
and an application manifest ([`src/windows/`](src/windows/)); they aren't
signed. [`scripts/package.sh`](scripts/package.sh) makes the release's files.

## Commands

```
zigsaw build [--rebuild] [--clean] [--keep-build-dir] [<recipe.json> | <dir>]
                                       build an app from a recipe, or from the zigsaw.json of a
                                       project's directory (the current one by default), install
                                       it and its commands; --clean starts a project's modules
                                       without the work directories its last build left
zigsaw search [<words>...]             find apps in the default registry's catalog
zigsaw info <image>                    show what an app in a registry is, needs and may reach
zigsaw pull [--yes] <image>            install an app and its commands from a registry, once
                                       you agree to what it may reach; --yes agrees without
                                       asking
zigsaw push [--sources] <app-id> [<image>]
                                       publish an installed app to a registry; --sources
                                       also pushes the files it was built from
zigsaw push --catalog <app-id>...      make the default registry's catalog list these apps
zigsaw login [--username=<user>] [--password-stdin] <registry>
                                       check and save a login for a registry
zigsaw logout <registry>               delete a registry's saved login
zigsaw run [options] <app-id> [args]   run an installed app
zigsaw list                            list installed apps, their commands and shortcuts,
                                       and the kinds of file they open
zigsaw override [options] <app-id>     save run options that every run of the app gets;
                                       --show shows them, --reset removes them
zigsaw override [options] --global     the same for every app, below each app's own
zigsaw update [--yes] [<app-id>...]    rebuild or re-pull apps from where they came from;
                                       one pulled again that may reach more asks first,
                                       unless given --yes
zigsaw rm [--delete-data] <app-id>     uninstall an app and its commands
zigsaw prune [--dry-run] [--downloads] [--data]
                                       delete what no installed app needs
zigsaw repair                          write every app's commands, shortcuts and file
                                       associations again, as after installing a new zigsaw
zigsaw version                         print zigsaw's version
```

## Finding apps

`zigsaw search` lists the apps in the default registry's catalog, and finds
the ones that have every word you give it (ignoring case) in their id, name,
summary, commands, shortcuts or the kinds of file they open:

```
> zigsaw search pdf
ID                              VERSION DESCRIPTION
org.sumatrapdfreader.SumatraPDF 3.6.1   SumatraPDF: A reader for PDF, EPUB, MOBI, XPS, DjVu, CHM and comic books
```

`zigsaw info <app-id>` shows what an app is before you install it, from its
image in the registry: its name, homepage and licence, how much a pull
downloads, its runtimes, commands, shortcuts and kinds of file, what it may
reach, and how it was built. It takes any image, in the catalog or not
(`zigsaw info ghcr.io/you/app:1.0`). `pull` says what the app may reach
before it downloads it, and `update` says so when a new version may reach
something else.

The catalog is an artifact next to the images, `<registry>/catalog:latest`
(`ghcr.io/zigsaw-io/catalog`), so `ZIGSAW_REGISTRY` changes it too. It lists
each app as the registry has it at its `latest` tag, as its image describes
it. A recipe's `name`, `summary`, `homepage` and `license` (an SPDX
expression) go into its image, and into the standard annotations that ghcr.io
shows on a package's page. Images without them are listed with their
commands. `zigsaw push --catalog <app-id>...` makes the catalog, from what
the registry has; [`scripts/publish.sh`](scripts/publish.sh) does it for
every published app. zigsaw keeps the last catalog it read in
`cache\catalog\`, and uses it when the registry can't be reached, saying
from when it is.

## Building your own project

A project can keep its recipe at its root, as `zigsaw.json`, where it would
keep a Makefile. `zigsaw build` in its directory builds it, as `make` does,
and installs it:

```powershell
cd C:\work\hello      # which has zigsaw.json
zigsaw build          # or, from anywhere: zigsaw build C:\work\hello
hello                 # its command
```

Its source is the project itself: a `path` that names a directory, here the
recipe's own:

```json
"sdk": { "zig": "org.ziglang.zig:0.16.0@sha256:0379659d0e7a87ac..." },
"modules": [
  { "name": "hello", "sources": [{ "path": "." }], "shell": "cmd", "build": ["zig build -Doptimize=ReleaseSafe -p %PREFIX%"] }
]
```

- **The build gets the files git would commit**: those the project's
  `.gitignore` files don't ignore, without `.git` and without empty
  directories, so not `zig-out`, `target` or `node_modules` when the
  project ignores them. zigsaw reads the `.gitignore` files itself, as git
  on Windows does (ignoring case), so git needn't be installed. Your global
  excludes don't count, so a checkout builds the same on any machine.
  `"skip": ["/docs", "*.log"]` leaves out more, with
  [`cleanup`'s](docs/recipes.md#recipes) patterns.
- **Your checkout stays as it is.** The files are copied to the build's
  `B:\src\<module>`, and the build happens there.
- **An unchanged project isn't built again.** The hash of its files is one of
  the build's inputs, so `zigsaw build` with nothing changed takes the image
  it built before, as does a change to a file git ignores. The image records
  the hash, and the same files make the same image anywhere.
- **A changed one builds incrementally.** Its module keeps `B:\src\<module>`
  between builds, with what the build left there (`.zig-cache`, `build`,
  `target`), and only the files that changed are written again, so make,
  ninja, cargo and zig redo only what those affect. It starts afresh when the
  recipe changes, and with `zigsaw build --clean`. See
  [incremental builds](docs/recipes.md#incremental-builds).
- `zigsaw update <app-id>` builds it again from the directory as it is then.

This repository has one: [`zigsaw.json`](zigsaw.json) builds zigsaw from
the checkout, in zig's image, with `zig build -Dstrip` as releases are built,
and its programs are the same bytes as those of a `zig build -Dstrip`
outside zigsaw ([`tests/self.sh`](tests/self.sh)). It exports nothing, as
zigsaw's own commands are on PATH already. See
[projects](docs/recipes.md#projects) for the details.

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
(such as Docker container images). An image's layers, its runtimes' among
them, download several at a time.

Before it downloads an app's layers, `pull` says what the app is, what it
brings and what it may reach, as `info` does, and asks:

```
test.example.notes 1.2: Notes
  A notebook
  download   12.4MiB
  commands   notes
  opens      .note
  permits    the network; your Documents
Install it? [Y/n]
```

Without a console to ask on, the answer is the next line on stdin
(`echo y | zigsaw pull ...`), and nothing there means no: scripts and CI add
`--yes`, which agrees without asking. A pull over an installed version of the
app, and `zigsaw update`, ask only when the new version may reach more: the
network where it couldn't, a location it couldn't use, or could only read, or
a registry key it didn't keep; and then say only what's new. `build` doesn't
ask: the recipe is yours, and so are the images it pins.

A reference may name a multi-platform index, as tools built for several
platforms publish: then `pull`, `update` and `info` take the index's image
for Windows on x64 (`windows/amd64`), and the app records that image's
digest. An index without one is refused, with the platforms it has. A
recipe pins the image, not the index.

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

A blob bigger than 64 MiB goes up in chunks of that size, so that a
registry that limits a request's size takes it, and an upload that breaks
off, or that the registry fails, goes on from where the registry got to; a
registry that has lost track of an upload that broke off (zot drops it)
gets the blob again, from the start. A registry that refuses the first
chunk, or fails one and can't say how much it has, as ghcr.io does, gets
the blob in one request after all, and so do the push's later blobs.
`ZIGSAW_UPLOAD_CHUNK_SIZE` sets the chunk size in bytes (0 sends every blob
in one request), and `-v` says how each chunk went.

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

Without either, zigsaw uses the login `docker login` saved for the registry,
as Docker would: from the credential helper Docker's `config.json` names
for it (`credHelpers`) or for every registry (`credsStore`), such as Docker
Desktop's `docker-credential-desktop.exe` on PATH, or else from the file
itself (`auths`). The file is `%DOCKER_CONFIG%\config.json`, or
`%USERPROFILE%\.docker\config.json`. A Docker login the registry refuses
doesn't stop a pull of a public image: zigsaw pulls without it, and says so.
Identity tokens, which Docker gets from some registries' web logins, aren't
used.

## Updating and cleaning up

`zigsaw update` brings every installed app, or the ones named, up to date
with where it came from. An app built from a recipe is rebuilt from that
recipe file, so editing the recipe and running `update` installs the new
version. An app pulled by tag is pulled again if the tag now points at a
different image; only the manifest is fetched when it doesn't. If the new
image may reach more than the installed one, `update` asks first, as `pull`
does, unless given `--yes`; an app you don't agree to stays as it is, and
`update` exits with 1. An app pulled by digest is pinned and left alone.

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
| `--command=<name>` | Run one of the app's exported commands, or another executable or batch file from the app's PATH (its aliases included) or System32 (e.g. `--command=cmd`), or one of yours by its absolute path |
| `--sandbox=soft\|low\|appcontainer` | `low` (the default, unless the app's image asks for another) keeps the app from writing anywhere but its data directory and the paths granted; `soft` shapes the environment only; `appcontainer` enforces all permissions ([sandboxes](#sandboxes)) |
| `--filesystem=<location>[:ro]` | Grant access to a host location: `cwd`, an absolute path, or one of [your folders](#your-folders) (`desktop`, `documents`, `downloads`, `music`, `pictures`, `videos`); for a location the app has a permission for already, this one replaces it (`documents:ro`) |
| `--nofilesystem=<location>` | Take away access that the app's permissions or its overrides give to a location |
| `--file=<path>` | Have the app open a file of yours: grants it that file, to read and write, and adds the file's path to the app's arguments (see [below](#opening-a-file)) |
| `--share=network` / `--unshare=network` | Override the app's network permission. With the network, a run gets your `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and `NO_PROXY` |
| `--port=<name>=<port>` | Serve one of the app's [services](#services) on another port, or reach a port it [uses](#reaching-this-machine) on another |
| `--env=NAME=VALUE` | Set an environment variable |
| `--noextension=<id>` | Leave out an installed [extension](docs/recipes.md#extension-points), which otherwise joins the runs of what it extends; `--extension=<id>` has one an override leaves out join again |
| `--ephemeral` | Use a fresh data directory, deleted after the run |
| `-v`, `--verbose` | Print the resolved command, environment and grants |

### Sandboxes

Every run has the app's own environment and data directory. What else
keeps it in is the run's sandbox:

- **`low`**, the default: the app runs at low integrity, so it writes only
  its data directory and what its permissions let it write, which zigsaw
  labels low integrity (the first time takes a while for a big folder). It
  reads what you can, and has the network whatever its permissions say.
- **`soft`**: nothing is enforced; the app writes wherever you can.
- **`appcontainer`**: every permission is enforced, reading and the network
  too, in an AppContainer of the app's own.

An image may ask for another sandbox than low: Kanboard's asks for `soft`,
as PHP can't tell it may write its data at low integrity, which `pull` and
`info` show. Your overrides choose over the image, and a run's `--sandbox`
over both: `zigsaw override --sandbox=soft <app>` for one app, `zigsaw
override --global --sandbox=soft` for every app ([below](#changing-an-apps-options)).

Low integrity won't label your user profile, a folder that holds it, or a
drive's root, as every low-integrity program could then write anywhere in
it. An app that may write its working directory, run from one of those,
gets it read-only for that run, with a warning: `node` from your home
folder reads it, and `npm init` there can't write `package.json`. Run it
from a folder inside, or with `--sandbox=soft`.

What a low run labels stays labelled while the app may write it, so that
its next runs don't label it again ([how long grants last](docs/how-it-works.md#how-long-grants-last)):
each working directory of an app with `cwd`, and your folders that apps
name, such as Documents. Any low-integrity program may write a labelled
folder, not only the app; give the app the folder `:ro`, or take it away
with `--nofilesystem`, if you'd rather not. [Known gaps](docs/gaps.md) has
what doesn't work at low integrity.

### Opening a file

`--file` is for handing an app one document, wherever it is, without giving
it the folder the document is in:

```powershell
zigsaw run --file=notes.rnote com.github.flxzt.rnote
zigsaw run --file=D:\docs\todo.txt org.gnome.TextEditor
```

- The path may be relative to where you are; the app gets it absolute, after
  its other arguments, as its own working directory may be elsewhere.
- Under `low`, that file alone is labelled low integrity, so the app can
  save it; under `appcontainer`, the app is granted that file alone; under
  `soft` nothing more happens. The label or grant lasts until the app's last
  run ends: a second run that hands the file to a first one, as Text
  Editor's does, leaves the first able to save it
  ([how long grants last](docs/how-it-works.md#how-long-grants-last)).
- The file has to exist, and be a file: `--filesystem` grants a directory.
- With only the file, an app can't make other files next to it. One that
  saves by writing a temporary file there and renaming it has to fall back
  to writing in place, as GLib does (so GTK's Text Editor saves); a backup
  copy next to the file fails. Rnote's recipe patches it to fall back too.
- It can't be saved as an override: it's for one run.

Files opened from Explorer come this way (see
[File associations](#file-associations)).

### Services

An app that other programs connect to, such as PostgreSQL's server or
Kanboard's web server, declares a service: a name and a port on
`localhost`. `zigsaw info` lists them. The service is on that port in every
sandbox, so a client finds it in the same place whichever sandbox the app
runs in:

```powershell
zigsaw run --sandbox=appcontainer org.postgresql.PostgreSQL   # serves localhost:5432
psql -h localhost -p 5432 -U postgres                          # a client outside zigsaw
zigsaw override --port=postgresql=5433 org.postgresql.PostgreSQL
```

An AppContainer can't be reached from outside, so there the app listens on
an internal port of its own, and zigsaw's relay, in the app's container,
publishes the service while the run lasts. `--port` moves a service, for
the app's own clients too. Services are on the loopback only
([networking](docs/networking.md), [recipes](docs/recipes.md#services)).

### Reaching this machine

Under `soft` and `low`, an app reaches the servers on this machine as any
program does. Under `appcontainer`:

- A run of an app with the network has its container exempt from loopback
  isolation while the app's runs go, so it reaches them too. Windows lets
  you change that setting without elevation; the app's last run to end
  takes it back, and so do `zigsaw repair` and `zigsaw rm` after a run that
  was killed. With `ZIGSAW_LOOPBACK_EXEMPTION=0`, zigsaw never exempts one.
- An app that isn't exempt reaches only the ports it declares it uses, such
  as osm2pgsql's PostgreSQL and Xdebug's debugger client: zigsaw makes those
  connections outside its container and hands them in. `zigsaw info` lists
  the ports, and `--port` moves one:

```powershell
zigsaw run --sandbox=appcontainer --port=postgresql=5433 org.osm2pgsql.osm2pgsql -d osm data.osm.pbf
```

([networking](docs/networking.md), [recipes](docs/recipes.md#ports-an-app-uses))

### Certificates

Apps trust the root certificates Windows trusts: a root that a network
inspecting TLS has added for the machine works in every sandbox. Most
images' TLS reads Windows' stores; Node's adds them to its
own list, and Java's reads the machine's in place of its own. The programs
that take only a file of roots, PHP's curl, Composer, Perl and libpq's
`sslrootcert=system`, get one that zigsaw writes of Windows' roots when a
run starts, which their images name with `${roots}`
([networking](docs/networking.md#certificate-trust)).

### Your folders

A run's profile is the app's own, in its data directory, so an app sees
none of your Desktop, Documents, Downloads, Music, Pictures or Videos
folders, unless its permissions name them, as Flatpak's `xdg-documents`
does:

```json
"permissions": { "filesystem": ["cwd", "desktop", "documents", "downloads"] }
```

```powershell
zigsaw run --filesystem=pictures:ro org.notepad_plus_plus.NotepadPlusPlus
zigsaw override --nofilesystem=documents org.gnome.TextEditor
```

- Each folder the app may use is a link (a directory junction) in its
  home, `home\Documents` and so on, to yours: where the app, and any
  program that asks Windows for the folder, looks for it. So it's in the
  app's file dialogs, by its name, and pinned in their Quick access, which
  the dialogs keep in the app's profile. A folder it may not use isn't
  there at all, and its link goes when the permission does.
- Under `low`, a folder the app may write is labelled low integrity, and
  under `appcontainer` it's granted, as any host path would be
  ([how it works](docs/how-it-works.md)): for everything in it, while the
  app's permissions or overrides give it the folder under that sandbox
  ([how long grants last](docs/how-it-works.md#how-long-grants-last)), and
  the first time takes a while for a big folder. Under `soft` that's all.
  A low label lets every low-integrity program write there, not only the
  app; if you'd rather not, give the app the folder `:ro`, or take it away
  with `--nofilesystem`.
- Folders that Windows keeps elsewhere, such as Documents in OneDrive, are
  linked to where they are. A folder you don't have, and one the app's
  data directory is in, are left out.
- A folder the app made itself in its home before it had the permission,
  with files in it, stays: zigsaw never deletes app data, and says so
  instead of linking.
- Deleting the app's data (`zigsaw rm --delete-data`, `prune --data`,
  `--ephemeral`) removes the links, never what's in your folders.
- `ZIGSAW_USER_FOLDERS=<dir>` makes `<dir>\Documents` and so on stand in for
  yours: the tests use it, so that no run labels or grants your folders.

The GUI apps zigsaw publishes declare the folders they open files from:
7-Zip, Notepad++, SumatraPDF, Text Editor and Rnote your Desktop, Documents
and Downloads (Rnote Pictures too, for exports), and VLC your Desktop,
Downloads, Music, Pictures and Videos. Images that use folder names need
zigsaw 0.18.0 or later; and a permission this zigsaw doesn't know, from a
later one, is left out of a run with a warning, rather than refused.

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

### Prebuilt GUI apps

Most Windows programs are published built, and ask Windows where to keep
their settings rather than reading `APPDATA`. A run points `USERPROFILE`
into the app's data directory, and Windows derives most of the user's
folders from it, so those programs keep their settings there too:

| What a program asks Windows for | In a zigsaw run |
|---|---|
| Roaming and Local AppData, the temporary directory | the app's data directory, in every sandbox (in an AppContainer, Local AppData is the container's own folder in it) |
| Desktop, Documents, Downloads, Music, Pictures, Videos | in the app's data directory too: links to yours for the folders its permissions name ([your folders](#your-folders)); the others don't exist there, and file dialogs leave them out |
| `AppData\LocalLow`, the profile folder itself, ProgramData | the real ones; at low integrity only LocalLow can be written, and in an AppContainer none |
| `HKEY_CURRENT_USER` | the keys the app's image declares: kept with its data, and there for its runs, in every sandbox (below); the rest is the real registry: writable under `soft`; at low integrity only `Software\AppDataLow`; in an AppContainer nothing |

[docs/findings.md](docs/findings.md#prebuilt-gui-apps) has the probe that
asked, and what 7-Zip, Notepad++, SumatraPDF and VLC do in each sandbox:
Notepad++, SumatraPDF and VLC keep everything in their data directories;
7-Zip's file manager keeps its settings in the registry.

#### Registry settings kept with the app

A recipe names the keys in `HKEY_CURRENT_USER` where its app keeps its
settings, and zigsaw keeps those with the app's data:

```json
"registry": ["Software\\7-Zip"]
```

- **Between runs**, the keys are in a hive file in the app's data directory,
  `registry\user.dat`, so they go with `rm --delete-data`, an `--ephemeral`
  run starts without them, and an update keeps them.
- **While the app runs**, they're where it looks for them, in HKCU: the
  first run copies them in, the last to end copies them back and deletes
  them. Each run labels them low or grants them to the app, as its sandbox
  needs, so 7-Zip saves its settings at low integrity and in an AppContainer
  too, which can't write the registry otherwise. In an AppContainer the app
  may also read the keys above them, below `Software`, which a program opens
  on its way there (Java's preferences open each key from
  `Software\JavaSoft\Prefs` down), until the keys go back.
- **Keys above them that weren't there** are made with them, and deleted
  with them while they're empty; keys that were there, empty or not, stay.
- **A key of the same name that was there**, such as the settings of a 7-Zip
  installed the usual way, is moved aside to `HKCU\Software\zigsaw\aside` for
  the time the app runs, and put back after.
- **A run that doesn't end** (zigsaw killed) leaves the keys in HKCU, with a
  record in `HKCU\Software\zigsaw\keys` of where they belong; the next run,
  `zigsaw repair` or `zigsaw rm` puts them back. While another app's run
  uses a key, a run of an app that keeps it too fails, saying so.

Only keys below `Software`, and not the ones Windows keeps for everyone
(`Classes`, `Microsoft`, `Policies`...), can be declared. 7-Zip's recipe
declares `Software\7-Zip`; PDFBox's, where Java keeps its debugger's
preferences, `Software\JavaSoft\Prefs\org\apache\pdfbox`.

Recipes for such programs leave out what makes them write next to their
executable, which zigsaw installs read-only (Notepad++'s `doLocalConf.xml`),
and their updaters: zigsaw updates them. VLC's turns off its first-run
privacy question and its update check with arguments.

### Start menu shortcuts

A recipe can declare shortcuts to its exports, as Flatpak apps export
`.desktop` files:

```json
"shortcuts": {
  "Text Editor": { "command": "gnome-text-editor", "description": "View and edit text files", "icon": "share/icons/org.gnome.TextEditor.ico" }
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

An app started from its shortcut counts as started from it, as a program
Explorer starts from one does, though zigsaw's shim and zigsaw are in
between: the shortcut's path is in its start-up information.

### File associations

A recipe can declare the kinds of file its app opens, by extension, as
Flatpak apps declare MIME types:

```json
"associations": {
  ".rnote": { "command": "rnote", "description": "Rnote document" },
  ".xopp": { "command": "rnote", "description": "Xournal++ document" }
}
```

Installing the app registers it for those extensions, for your user only,
which takes no administrator. Explorer then lists the app under "Open with",
calls such a file what `description` says, and shows it with the icon of
`icon` (as for shortcuts) or of the export's executable.

- zigsaw only offers the app. It never makes it the default for an
  extension: that's your choice, in Explorer, and Windows guards it. The
  first time you open a file of a kind nothing else opens, Windows asks
  whether to use the app.
- Opening a file runs the export with [`--file`](#opening-a-file), through a
  shim of its own in the store's `open` directory. So the app is granted
  that file, and only that file, whatever sandbox its overrides choose.
- Updating the app registers what it declares then, and `zigsaw rm` removes
  it all. `zigsaw list` shows the extensions.
- What's registered is a key of zigsaw's own for each extension
  (`Zigsaw.<app id>.<extension>` under `HKCU\Software\Classes`) and its name
  under the extension's `OpenWithProgids`. zigsaw changes nothing else
  there, and removes only keys that name its store.

As with shortcuts, only the default store registers.
`ZIGSAW_CLASSES_KEY` names a key under `HKEY_CURRENT_USER` to use in place
of `Software\Classes`, for any store; the tests use one.

### Changing an app's options

`zigsaw override` saves run options for an app, and every run of it gets them,
including runs through its commands on PATH. It takes the same options as
`run`, except `--command`:

```powershell
zigsaw override --sandbox=appcontainer com.github.BurntSushi.ripgrep   # rg reads only what it may
zigsaw override --sandbox=soft org.nodejs.node                         # node writes anywhere, as before 0.54
zigsaw override --filesystem=D:\src org.nodejs.node                    # node can use D:\src
zigsaw override --filesystem=documents:ro org.videolan.VLC             # VLC reads your Documents
zigsaw override --nofilesystem=downloads org.videolan.VLC              # but not your Downloads
zigsaw override --show org.nodejs.node                                 # what's saved
zigsaw override --reset org.nodejs.node                                # remove them all
```

New options are added to the ones already saved; a filesystem location or
variable given again replaces its earlier setting, and `--filesystem` and
`--nofilesystem` for the same location replace each other. A location's
setting also replaces the app's own permission for it: `documents:ro` makes
an app that may write your Documents read it only. Options given to `run`
still win for that run. Overrides are kept when an app is updated, rebuilt or
removed, and `zigsaw rm --delete-data` deletes them with the app's data.
`zigsaw list` shows them.

`--global` in place of an app saves options for every app, below each
app's own overrides, and over what apps' images ask for:

```powershell
zigsaw override --global --sandbox=soft   # every app writes anywhere, as before 0.54
zigsaw override --global                  # what's saved
zigsaw override --global --reset          # remove them
```

They're kept in the store's `overrides.json`.

## Testing

```bash
zig build test          # unit tests
bash tests/matrix.sh    # runs real tools through the three sandboxes (Git Bash, network)
bash tests/sandbox.sh   # which sandbox a run gets (low by default, the image's, store-wide and app overrides); what the low and appcontainer sandboxes change on the host, how long it lasts, and rm undoes; a working directory low won't label, read-only; --file; your folders (fake ones); registry keys kept with an app
bash tests/network.sh   # an app's service reached from the host in each sandbox, on its port, one --port or an override moves it to, and not after the run; in an AppContainer, an internal port the app's runs agree on and reach each other on without the network, and a port another program holds; an AppContainer run with the network exempt from loopback isolation while it goes (not without the network, nor with ZIGSAW_LOOPBACK_EXEMPTION=0), a killed run's exemption taken back by repair, one you made kept; a port the app uses reached directly, or through zigsaw's forward when not exempt, and --port moving it; proxy variables passed to runs with the network; eight first AppContainer runs at once; the probe's report of what Windows lets AppContainers do on the loopback and over AF_UNIX (tests/netprobe.zig)
bash tests/shims.sh     # command shims end to end, also for commands installed at run time and GUI programs; Start menu shortcuts; file associations (in a scratch registry key)
bash tests/store.sh     # update, prune, and what they keep while apps run
bash tests/build.sh     # building apps: runtimes, images as sources, projects with a zigsaw.json, build commands on B:, tool caches, aliases, vendor steps, CMake, Meson, Rust, Go, cgo, .NET (WinForms and WPF too), extension points, PHP extensions with zig, reproducibility
GROUP=langs bash tests/build.sh # only one group of its sections (tests/build.sh --groups lists them), as a CI job does
bash tests/gtk.sh       # a GTK and libadwaita app built against GTK's SDK, on its runtime, in each sandbox; the GUI shim, shortcuts and their icons; translations; Text Editor, Rnote and Pinta (C#, on .NET), their file associations, and opening a file with --file; dictionaries and an icon through the runtime's extension point; Gaphor's self-test in each sandbox; GTK with MSVC if the store has it (needs GTK_HOME or BUILD_HOME; opens windows)
bash tests/gtk3.sh      # a GTK 3 app built against GTK 3's SDK and GTK's, on both runtimes, in each sandbox; GTK 3's demos; Gnumeric's ssconvert between CSV, Excel and OpenDocument in each sandbox, its file associations, and opening a file with --file; PyGObject loading GTK 3 and GTK 4, Meld comparing files and folders and showing a git repository's changes in each sandbox, and the published apps all on one build of each GTK runtime (needs GTK_HOME or BUILD_HOME; opens windows)
bash tests/texlive.sh   # TeX Live: pdfLaTeX, XeLaTeX and LuaLaTeX with fonts found by name and formats made on first use in the data directory, BibTeX, MakeIndex, Biber, MetaPost, latexmk on Perl's image, epstopdf and ps2pdf on Ghostscript's, reproducible PDFs, at low integrity too; the AppContainer row is a known gap where Windows hides the drive root (needs TEXLIVE_HOME or BUILD_HOME)
bash tests/postgresql.sh # PostgreSQL's server in each sandbox, its cluster made on first use with a password its clients find; TLS, pgcrypto, ICU collations, lz4 and zstd, XML, PL/Perl and PL/Python and errors raised through them, a dump restored, a zstd backup, pg_ctl stopping it from another run, plperl.on_init, the pgvector, pg_cron and PostGIS extension images joining (an HNSW index, a job every second, a point transformed with PROJ's proj.db, GEOS, GeoJSON, GML, a GiST index and a topology, and PostGIS's rasters on GDAL: values, statistics, a raster reprojected, GeoTIFF and PNG) and --noextension leaving one out; a client outside an AppContainer reaching it through its service (needs POSTGRES_HOME or BUILD_HOME with PostgreSQL and the three extensions)
bash tests/gdal.sh      # GDAL's tools in each sandbox, from the directory they run in: PROJ's proj.db, a GeoTIFF made, read with statistics, warped and turned into a PNG, GeoJSON into a GeoPackage and KML, a clip with GEOS, the gdal command (needs GDAL_HOME or BUILD_HOME)
bash tests/osm2pgsql.sh # osm2pgsql under soft and low, against PostgreSQL's server with PostGIS under soft, from the directory it runs in: the pgsql output with its default style, an update expiring tiles, the flex output with a Lua style requiring a module, from PBF with flat nodes and an area table in UTM, gzip and bzip2 input, -W reading the password, osm2pgsql-expire; and in an AppContainer, reaching the server through its declared port (needs OSM2PGSQL_HOME or BUILD_HOME with osm2pgsql, PostgreSQL and PostGIS)
bash tests/certs.sh     # which apps trust a root CA added to Windows: a test CA made for the run, which each client must refuse until it's in LocalMachine\Root, then trust in each sandbox (Python, Node, Java on the JDK and the JRE, MinGit, CMake, zig, psql, PHP); adding the CA takes an elevated shell, or CERTS_ELEVATE=1 for a UAC prompt (needs CERTS_HOME or BUILD_HOME with Python's image, and the clients' images)
bash tests/qt.sh        # a Qt Widgets app built against Qt's SDK with CMake, on its runtime, in each sandbox: plugins found from the runtime, image formats, Schannel, translations; a Qt Quick window drawn with Direct3D 11 in each sandbox; the SDK's cmake without a recipe; the qml tool; Designer's and Linguist's windows, shims and shortcuts; Flameshot in each sandbox, and its full command saving a screenshot; Notes in each sandbox, its QML and database (needs QT_HOME or BUILD_HOME; opens windows)
bash tests/files.sh     # Files (C#, WinUI 3, on .NET) without a package: its layout, shim and shortcut, starting up, opening a folder, settings kept with its data (needs FILES_HOME or BUILD_HOME; opens windows; local only)
bash tests/guiapps.sh   # 7-Zip, Notepad++, SumatraPDF and VLC in each sandbox: opening a file, where their settings go, shims, shortcuts and file types (opens windows; local only)
bash tests/zls.sh       # ZLS's language server sessions over stdio in each sandbox: the standard library's documentation, a module a project's build.zig declares, a syntax error; its shim (needs ZLS_HOME or BUILD_HOME, or builds it)
bash tests/php.sh       # PHP's runtime in each sandbox, HTTPS; seven extensions built with php-ext (yaml and zstd with libraries their recipes build) join PHP's runs once installed, and pass their test suites (ssh2 and redis against servers built with Go); an app with two as runtimes, and Xdebug's step debugger; Composer offline; Kanboard's pages and API, in an AppContainer through its service too (needs PHP_HOME or BUILD_HOME; local only)
bash tests/install.sh   # scripts/package.sh's release files, and install.ps1 installing, upgrading and removing zigsaw (in a scratch directory and registry key)
bash tests/self.sh      # zigsaw building this checkout's zigsaw.json makes the same programs as zig build -Dstrip (the Release workflow runs it on its package); an incremental build of a copy after a change makes what --clean does
bash tests/ctrlc.sh     # Ctrl+C, Ctrl+Break and closing the console, in a pseudoconsole
bash tests/batch.sh     # batch files as commands: arguments arrive exactly, and run nothing
bash tests/registry.sh  # push, pull, update, mounts, chunked uploads that break off, multi-platform indexes, logins (zigsaw's and Docker's), sources next to images, the catalog, search and info, through local registries (see its header)
bash tests/published.sh # fresh builds have the published digests; anonymous pulls, latest, redirects, the catalog
GROUP=java bash tests/published.sh # only one group of scripts/published-groups.txt, as a CI job does
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
a fresh runner, in a store of the published images the matrix runs and zot
([`tests/seed-store.sh`](tests/seed-store.sh) pulls them, and builds a
version that isn't published yet), as `SEED_DOWNLOADS` and the matrix's
and ZLS's store. The jobs that run `published.sh` check that those images
are what the recipes build. `tests/gtk.sh` and `tests/gtk3.sh` run the
same way, in a job of their own, in a store of GTK's published images and
the apps on them, which they install again rather than build, when GTK's
family is checked; the runner has no GPU, so GTK's OpenGL check is a known
gap there; and it runs Windows Server 2025, where Meld's window in an
AppContainer is one too. `tests/build.sh` runs in
jobs of its own, one for each group of its sections, beside them.
