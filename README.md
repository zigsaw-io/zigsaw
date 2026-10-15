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
zigsaw build [--rebuild] [--keep-build-dir] <recipe.json>
                                       build an app from a recipe, install it and its commands
zigsaw search [<words>...]             find apps in the default registry's catalog
zigsaw info <image>                    show what an app in a registry is, needs and may reach
zigsaw pull <image>                    install an app and its commands from a registry
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
zigsaw update [<app-id>...]            rebuild or re-pull apps from where they came from
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

## Published apps

The recipes in [recipes/](recipes/) are published as images in
`ghcr.io/zigsaw-io`, tagged with their version and `latest`, and listed in
its catalog (`zigsaw search`), so these install with `zigsaw pull <id>`
(those in `recipes/no-publish/` aren't: see
[Apps you build yourself](#apps-you-build-yourself)):

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
| Perl (Strawberry Perl, for building OpenSSL) | `org.perl.perl` | 5.42.3.1 | `perl` |
| cargo-c (for building librsvg) | `com.github.lu-zero.cargo-c` | 0.10.25 | `cargo-cbuild`, `cargo-cinstall` |
| GNU gettext, with libiconv (built from source, for GTK's SDK) | `org.gnu.gettext` | 1.0 | `gettext`, `ngettext`, `msgfmt`, `msgmerge`, `msginit`, `msgcat`, `msgunfmt`, `xgettext`, `iconv` |
| GTK SDK (built from source; with zig, Meson and BusyBox) | `org.gtk.Gtk4.Sdk` | 4.24.1 | `cc`, `c++`, `ar`, `rc`, `windres`, `pkg-config`, `meson`, `ninja`, `sh`, `make`, `glib-compile-resources`, `glib-compile-schemas`, `gtk4-builder-tool`, `msgfmt`, `msgmerge`, `xgettext` |
| GTK, with libadwaita, libsoup, librsvg and enchant (from its SDK) | `org.gtk.Gtk4` | 4.24.1 | `gtk4-demo`, `gtk4-widget-factory`, `gtk4-node-editor`, `gtk4-print-editor`, `gtk4-query-settings`, `adwaita-1-demo`, `gio`, `pango-view`, `pango-list` |
| GNOME Text Editor (built from source, on GTK) | `org.gnome.TextEditor` | 51.0 | `gnome-text-editor` |
| Rnote (built from source, on GTK) | `com.github.flxzt.rnote` | 0.14.2 | `rnote`, `rnote-cli` |
| 7-Zip | `org.7_zip.7zip` | 26.04 | `7z`, `7zfm`, `7zg` |
| Notepad++ | `org.notepad_plus_plus.NotepadPlusPlus` | 8.9.8.1 | `notepad++` |
| SumatraPDF | `org.sumatrapdfreader.SumatraPDF` | 3.6.1 | `sumatrapdf` |
| VLC media player | `org.videolan.VLC` | 3.0.24 | `vlc` |

Prettier runs on Node as a [runtime](#runtimes): its image brings Node's
files along, without installing Node as an app. SQLite, ripgrep, bat, fzf,
zot and zstd are [built from source](#building-from-source): SQLite with zig
and BusyBox, ripgrep and bat with [Rust](#rust), zig and BusyBox, fzf and
zot with [Go](#go) and BusyBox, zstd with [CMake](#cmake), zig and BusyBox,
whose images are their SDK. bat's C libraries (oniguruma, libgit2, zlib) are
compiled by zig. Pulling them doesn't need those. [GTK](#gtk)'s SDK is built
with Meson, CMake, zig, Perl (for OpenSSL), Rust and cargo-c (for librsvg),
takes gettext's files from its image, and has zig, Meson and BusyBox as
runtimes, so that it builds GTK programs
[without a recipe](#building-without-a-recipe) too; its runtime is made from
the SDK's image. GNOME Text Editor runs on GTK's runtime, with GtkSourceView
and libspelling built into its own image, and checks spelling. Rnote, a
drawing and note-taking app written in Rust, runs on it too. GTK, Text Editor
and Rnote are translated. GTK's demos, Text Editor and Rnote are GUI apps:
they open no console, and get [Start menu shortcuts](#start-menu-shortcuts)
with their icons. Explorer offers Rnote for `.rnote` and `.xopp` files and
Text Editor for `.txt`, `.md` and `.log` ([file associations](#file-associations)).
7-Zip, Notepad++, SumatraPDF and VLC are the programs their projects
publish, packaged from upstream's archives, with shortcuts and the kinds of
file they open ([prebuilt GUI apps](#prebuilt-gui-apps)). 7-Zip's image is
made from its installer, which its standalone `7zr.exe` unpacks.

Layers are gzip-compressed, so a pull downloads much less than it unpacks:
88 MB for zig's 378 MB of files, 179 MB for Rust's 649 MB.

[`scripts/publish.sh`](scripts/publish.sh) publishes the recipes listed in
[`scripts/published-recipes.txt`](scripts/published-recipes.txt).

### Apps you build yourself

The recipes in [recipes/no-publish/](recipes/no-publish/) make images that
mustn't be published, as the licences of what's in them don't allow it.
`zigsaw pull` can't find them: each machine builds them, in this order.

| App | Id | Version | Commands |
|---|---|---|---|
| .NET SDK | `com.microsoft.dotnet.Sdk` | 10.0.402 | `dotnet`, `dnx` |
| .NET runtime, with ASP.NET Core and Windows Desktop (from its SDK) | `com.microsoft.dotnet` | 10.0.13 | |
| Pinta (built from source, on GTK and .NET) | `com.github.PintaProject.Pinta` | 3.1.2 | `pinta` |
| Files - Zigsaw build (built from source, on .NET) | `community.files.Files` | 4.3 | `files` |

```powershell
zigsaw build recipes\no-publish\dotnet-sdk.json   # 300 MB from Microsoft
zigsaw build recipes\no-publish\dotnet.json
zigsaw build recipes\no-publish\pinta.json
zigsaw build recipes\no-publish\files.json        # 3.3 GB of NuGet packages; about ten minutes
```

Microsoft's licence for its .NET binaries on Windows lets anyone use them
to build and test programs, and ship them in their own, but not publish
them for others to copy ([.NET](docs/recipes.md#net)). Pinta, an image
editor written in C#, runs on GTK's runtime and .NET's: its build pulls
GTK's runtime and gettext's image from the registry, and finds .NET's in the
store. Explorer offers it for images (`.ora`, `.png`, `.jpg`, `.bmp`,
`.tif`).

[Files](https://files.community/), a file manager written in C# with
WinUI 3, runs on .NET's runtime, patched to run without the MSIX package
it's made for ([Files](docs/recipes.md#files)). Its window and Start menu
shortcut say "Files - Zigsaw build", so as not to pass for the Files its
project publishes. It works in the default `soft` sandbox only: at low
integrity and in an AppContainer it starts, but shows no drives and asks
for a permission it can't be given.

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

The workflow only checks. Images are published by hand
([`scripts/publish.sh`](scripts/publish.sh)); zigsaw's own releases by the
Release workflow (see [Installing zigsaw](#installing-zigsaw)).

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
(such as Docker container images). It says what the app is and may reach
before it downloads it, as `build` does once it has built it.

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
| `--command=<name>` | Run one of the app's exported commands, or another executable or batch file from the app's PATH (its aliases included) or System32 (e.g. `--command=cmd`), or one of yours by its absolute path |
| `--sandbox=soft\|low\|appcontainer` | `soft` (default) shapes the environment only; `low` also keeps the app from writing anywhere but its data directory and the paths granted; `appcontainer` enforces all permissions |
| `--filesystem=<location>[:ro]` | Grant access to a host location: `cwd`, an absolute path, or one of [your folders](#your-folders) (`desktop`, `documents`, `downloads`, `music`, `pictures`, `videos`); for a location the app has a permission for already, this one replaces it (`documents:ro`) |
| `--nofilesystem=<location>` | Take away access that the app's permissions or its overrides give to a location |
| `--file=<path>` | Have the app open a file of yours: grants it that file, to read and write, and adds the file's path to the app's arguments (see [below](#opening-a-file)) |
| `--share=network` / `--unshare=network` | Override the app's network permission |
| `--env=NAME=VALUE` | Set an environment variable |
| `--ephemeral` | Use a fresh data directory, deleted after the run |
| `-v`, `--verbose` | Print the resolved command, environment and grants |

### Opening a file

`--file` is for handing an app one document, wherever it is, without giving
it the folder the document is in:

```powershell
zigsaw run --file=notes.rnote com.github.flxzt.rnote
zigsaw run --sandbox=low --file=D:\docs\todo.txt org.gnome.TextEditor
```

- The path may be relative to where you are; the app gets it absolute, after
  its other arguments, as its own working directory may be elsewhere.
- Under `soft` nothing more happens. Under `low`, that file alone is
  labelled low integrity, so the app can save it; under `appcontainer`, the
  app is granted that file alone. Either lasts until `zigsaw rm`, like other
  grants.
- The file has to exist, and be a file: `--filesystem` grants a directory.
- With only the file, an app can't make other files next to it. One that
  saves by writing a temporary file there and renaming it has to fall back
  to writing in place, as GLib does (so GTK's Text Editor saves); a backup
  copy next to the file fails. Rnote's recipe patches it to fall back too.
- It can't be saved as an override: it's for one run.

Files opened from Explorer come this way (see
[File associations](#file-associations)).

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
- Under `soft` that's all. Under `low`, a folder the app may write is
  labelled low integrity, and under `appcontainer` it's granted, as any
  host path would be ([how it works](#how-it-works)): for everything in
  it, until `zigsaw rm`, and the first time takes a while for a big folder.
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
  too, which can't write the registry otherwise.
- **A key of the same name that was there**, such as the settings of a 7-Zip
  installed the usual way, is moved aside to `HKCU\Software\zigsaw\aside` for
  the time the app runs, and put back after.
- **A run that doesn't end** (zigsaw killed) leaves the keys in HKCU, with a
  record in `HKCU\Software\zigsaw\keys` of where they belong; the next run,
  `zigsaw repair` or `zigsaw rm` puts them back. While another app's run
  uses a key, a run of an app that keeps it too fails, saying so.

Only keys below `Software`, and not the ones Windows keeps for everyone
(`Classes`, `Microsoft`, `Policies`...), can be declared. 7-Zip's recipe
declares `Software\7-Zip`.

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
zigsaw override --sandbox=appcontainer com.github.BurntSushi.ripgrep   # rg is always sandboxed
zigsaw override --sandbox=low org.nodejs.node                          # node writes only its data and cwd
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
aliases\<id>\          shims for the aliases an app's runs have: its own and its runtimes'
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
run these shims. A shim that a shortcut started says so (Windows puts the
shortcut's path in its `STARTUPINFO`, with `STARTF_TITLEISLINKNAME`), and
zigsaw starts the app with the same.

**File associations** are keys in `HKCU\Software\Classes`: one of zigsaw's
per app and extension, with the command, and its name in the extension's
`OpenWithProgids`. The command is a copy of the same shim in
`open\<app id>\`, whose `.shim` file says its arguments are files: it runs
`zigsaw run --command=<name> --file=<argument> <app>`. `--file` adds the
file to the run's grants as if it were a directory: a low integrity label
or an entry for the app's capability, on that file alone.

**Runs** get an environment built from scratch: `PATH` is the app's
directories, then its runtimes', then System32. `USERPROFILE`, `APPDATA`,
`LOCALAPPDATA` and `TEMP` point into `data\<id>\home`, and the user's folders
the app may use are directory junctions there, to the real ones. Windows
follows a junction as a path, and grants or denies access by what it
points to; deleting a tree or changing its ACL (inheritance) stops at the
junction. The working directory
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
host paths it may write (`cwd`, your folders and `--filesystem` paths without
`:ro`). It
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
bash tests/sandbox.sh   # what the low and appcontainer sandboxes change on the host, and rm undoes; --file; your folders (fake ones); registry keys kept with an app
bash tests/shims.sh     # command shims end to end, also for commands installed at run time and GUI programs; Start menu shortcuts; file associations (in a scratch registry key)
bash tests/store.sh     # update, prune, and what they keep while apps run
bash tests/build.sh     # building apps: runtimes, images as sources, build commands on B:, tool caches, aliases, vendor steps, CMake, Meson, Rust, Go, cgo, .NET (WinForms and WPF too), reproducibility
bash tests/gtk.sh       # a GTK and libadwaita app built against GTK's SDK, on its runtime, in each sandbox; the GUI shim, shortcuts and their icons; translations; Text Editor, Rnote and Pinta (C#, on .NET), their file associations, and opening a file with --file; GTK with MSVC if the store has it (needs GTK_HOME or BUILD_HOME; opens windows; local only)
bash tests/files.sh     # Files (C#, WinUI 3, on .NET) without a package: its layout, shim and shortcut, starting up, opening a folder, settings kept with its data (needs FILES_HOME or BUILD_HOME; opens windows; local only)
bash tests/guiapps.sh   # 7-Zip, Notepad++, SumatraPDF and VLC in each sandbox: opening a file, where their settings go, shims, shortcuts and file types (opens windows; local only)
bash tests/install.sh   # scripts/package.sh's release files, and install.ps1 installing, upgrading and removing zigsaw (in a scratch directory and registry key)
bash tests/ctrlc.sh     # Ctrl+C, Ctrl+Break and closing the console, in a pseudoconsole
bash tests/batch.sh     # batch files as commands: arguments arrive exactly, and run nothing
bash tests/registry.sh  # push, pull, update, mounts, logins, sources next to images, the catalog, search and info, through local registries (see its header)
bash tests/published.sh # fresh builds have the published digests; anonymous pulls, latest, redirects, the catalog
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
