# Zigsaw

Image-based container solution for running sandboxed program on Windows.

A mix of Flatpak and Docker, but for Windows programs: apps are built from pinned sources into
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

To build zigsaw yourself instead, with Zig 0.17:

```powershell
zig build                # ReleaseSafe by default; -Doptimize=Debug for a quicker compile
.\zig-out\bin\zigsaw.exe pull org.nodejs.node
```

## Installing zigsaw

[`scripts/install.ps1`](scripts/install.ps1), which every
[release](https://github.com/zigsaw-io/zigsaw/releases) carries, installs
zigsaw for you alone, in Windows PowerShell 5.1 or later:

- It downloads the release's `zigsaw-x86_64-windows.zip` and checks it
  against the release's `SHA256SUMS` before changing anything. Both come from where
  the script does, so a first install trusts GitHub:
  [checking one by hand](#signatures) is what doesn't.
- It puts `zigsaw.exe` and the programs that come with it in `%LOCALAPPDATA%\zigsaw\bin`,
  where zigsaw puts installed apps' commands too, and adds that directory to
  your PATH, keeping the rest of PATH as it was stored (variables such as
  `%USERPROFILE%` in it stay variables).
- Run it again to upgrade. A zigsaw that's running, because an app it
  started still runs, is moved aside, and the next install deletes it. Then
  `zigsaw repair` writes the installed apps' commands, shortcuts and file
  associations again, as copies of the new shims. Afterwards, `zigsaw upgrade`
  does the same from zigsaw itself.
- It starts a [daily check for updates](#being-told-about-updates), which installs
  nothing, and says so as it does. `zigsaw updates off`, or `-NoUpdateCheck`, stops
  it, and it stays off through later installs. A store or a directory you chose
  yourself doesn't get one unless you ask.

With parameters (`-Version`, `-Dir`, `-NoPath`, `-NoUpdateCheck`, `-Uninstall`):

```powershell
& ([scriptblock]::Create((irm https://github.com/zigsaw-io/zigsaw/releases/latest/download/install.ps1))) -Version 0.19.0
```

`-Uninstall` removes zigsaw and its PATH entry once no app is installed
(`zigsaw rm` undoes what zigsaw changed for each app, which deleting its
files wouldn't). The rest of `%LOCALAPPDATA%\zigsaw`, downloads and apps'
data, stays until you delete it. Windows won't let anyone delete an installed
app's files by hand, as they're kept read-only: `zigsaw rm` them first. If a
store has gone that way regardless, `zigsaw repair` from any other takes back
what it changed ([what zigsaw changed](#what-zigsaw-changed-outside-its-stores)).

Releases are published by the [Release workflow](.github/workflows/release.yml)
when a `v<version>` tag is pushed. Their programs are built with
`zig build -Dstrip`, which leaves out the debug information that would name
the directory they were built in, for the x86-64 baseline, whatever CPU
builds them (`build.zig`'s default target), so a build of the same tag with
its Zig (0.17.0 from 0.58.0, 0.16.0 before) gives the same bytes anywhere,
and runs on any x64 CPU; the
release notes list their SHA-256. (0.18.0's were built for the CPU of
GitHub's runner, and need AVX2, BMI2 and the SHA instructions.) A build
of 0.19.0, 0.20.0 and 0.21.0 here gave their releases' bytes. From 0.22.0
the programs carry version information, which Explorer's Properties show,
and an application manifest ([`src/windows/`](src/windows/)); they have no
Authenticode signature, so SmartScreen and Defender know nothing of them, though
each release from 0.74.0 has [one of its own](#signatures).
[`scripts/package.sh`](scripts/package.sh) makes the release's files.
Up to v0.69.0, the manifest's line endings followed the checkout's: those
releases were built with CRLF, so a build gives their bytes only on a checkout
with `core.autocrlf=true`. From 0.70.0 they're pinned.

Microsoft Defender's machine learning has flagged some builds of zigsaw by their
exact bytes, as `Trojan:Win32/Bearfoos.A!ml` ([findings](docs/findings.md#defender-and-exact-bytes)).
So the Release workflow scans the programs before publishing them, and
[`scripts/defender-scan.sh`](scripts/defender-scan.sh) does the same here.

## Commands

```
zigsaw build [--clean[=<module>]] [--rebuild] [--no-resume] [--keep-build-dir]
             [--memory=<size>] [--cpus=<n>] [<recipe.json> | <dir>]
                                       build an app from a recipe, or from the zigsaw.json of a
                                       project's directory (the current one by default), install
                                       it and its commands. It goes on from the recipe's last
                                       build: modules whose inputs are the same are skipped, and
                                       one that stopped goes on at its command. --clean deletes
                                       what that build left; --clean=<module> starts that module
                                       and those after it afresh; --rebuild and --no-resume build
                                       every module in a new directory. Kept builds may take
                                       10 GB together (ZIGSAW_KEPT_BUILDS_SIZE); a build deletes
                                       the least recently used others past that, and says so.
                                       --memory and --cpus hold each of its commands to that
                                       much memory and that many processors (see Limits)
zigsaw search [<words>...]             find apps in the default registry's catalog
zigsaw info <image>                    show what an app in a registry is, needs and may reach
zigsaw ls <image>                      list the files of an app in a registry without pulling
                                       it, as far as its layers' format allows (eStargz)
zigsaw cat <image> <path>              write a file of an app in a registry to stdout, the
                                       same way
zigsaw pull [--yes] [--lazy] <image>   install an app and its commands from a registry, once
                                       you agree to what it may reach; --yes agrees without
                                       asking; --lazy installs it before its large eStargz
                                       layers are downloaded, their files fetched as they're
                                       first used while the rest downloads
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
                                       --show shows them, --reset removes them; also
                                       --nosnapshot has updates keep no copy of its data
                                       for rollback, --snapshot has them keep one again
zigsaw override [options] --global     the same for every app, below each app's own; also
                                       --real-folders lets the apps of a store that isn't your
                                       default one use your real folders, --noreal-folders
                                       stops them
zigsaw grants [<app-id>]               list what zigsaw changed outside its store for apps, in
                                       this store and others, what stores since deleted left,
                                       and low labels on your folders no record explains
zigsaw grants --take-back <path>       remove a low label that no record explains
zigsaw update [--yes] [--lazy] [<app-id>...]
                                       rebuild or re-pull apps from where they came from;
                                       one pulled again that may reach more asks first,
                                       unless given --yes; --lazy as for pull
zigsaw updates                         say what the last check found waiting, and whether a
                                       daily check is on; neither installs anything
zigsaw updates check                   look for updates of apps and zigsaw now
zigsaw updates on|off                  start or stop the daily check; off is remembered, so that
                                       installing or upgrading zigsaw leaves it off
zigsaw upgrade [--yes]                 install zigsaw's latest release over this one, once you
                                       agree; --yes agrees without asking
zigsaw update --check [<app-id>...]    list the apps a new image waits for, and what it may
                                       reach beyond theirs, installing nothing
zigsaw rollback [--yes] <app-id>       go back to the version the installed one replaced, with
                                       no network; updates then pass over the version left,
                                       though not a newer one. Asks whether its data is to
                                       go back too, to the copy kept of it as that version
                                       left it: --data says yes, --keep-data no
zigsaw rollback --data-only <app-id>   take the data back after a rollback that left it
zigsaw hold <app-id>...                have updates, and the daily check, leave the apps alone
zigsaw unhold <app-id>...              let updates reach them again
zigsaw trust                           list whose signatures images and releases are checked for
zigsaw trust add <registry/path> <key> check images under that path against a public key, as
                                       `cosign generate-key-pair` makes in cosign.pub
zigsaw trust add <registry/path> --keyless <identity> [--issuer <url>]
                                       check them for a keyless signature, by a certificate
                                       Sigstore's Fulcio gave <identity> (a workflow's URI, as
                                       cosign's --certificate-identity takes it); the issuer is
                                       GitHub Actions' unless given
zigsaw trust rm <registry/path> [<fingerprint or identity>]
                                       stop checking them for signatures added there
zigsaw signature payload <image>       print what to sign for an image, for `cosign sign-blob`
zigsaw signature push <image> <payload file> <signature file>
                                       put a key's signature beside the image, where pull looks
zigsaw signature push-bundle <image> <payload file> <bundle file>
                                       put a keyless one, as `cosign sign-blob --bundle` writes
                                       it, beside the image, once it's checked
zigsaw signature check <image>         say whether an image has a good signature
zigsaw volume create [--path=<dir>] <name>
                                       make a volume in the store, or keep one in a folder of
                                       yours; a run's --volume makes one it doesn't find
zigsaw volume ls                       list the volumes, each app's own (its data, named by
                                       its id) too, where each is, and what mounts it
zigsaw volume inspect <name>           show a volume's size, mounts, use and grants
zigsaw volume export [--all] <name> <file>
                                       write a volume's files to a tar, .tar.gz by its name,
                                       or - for stdout; an app's data by the app's id,
                                       without its temporary files and cache unless --all
zigsaw volume import [--replace] <name> <file>
                                       make a tar's files (- for stdin) a volume's, a new
                                       one or one with no files; --replace puts them in the
                                       place of the files it has, which are deleted
zigsaw volume rm <name>...             delete volumes in the store, or forget ones kept
                                       elsewhere, leaving their files; not one an override
                                       mounts, nor the data of an installed app
zigsaw volume prune [--dry-run]        delete the volumes in the store that nothing mounts:
                                       those no override names, and uninstalled apps' data
zigsaw rm [--delete-data] <app-id>     uninstall an app and its commands; --delete-data also
                                       deletes its own volume; the others it mounted stay
zigsaw prune [--dry-run] [--downloads] [--volumes] [--previous]
                                       delete what no installed app needs; --volumes also the
                                       volumes nothing mounts, --previous the versions kept
                                       for rollback with the copies of their data
zigsaw repair                          write every app's commands, shortcuts and file
                                       associations again, as after installing a new zigsaw,
                                       and take back what apps may no longer reach, and what
                                       stores since deleted left
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

`zigsaw ls <app-id>` lists an app's files, and `zigsaw cat <app-id> <path>`
writes one of them, a licence say, to stdout, without pulling the app: for
layers in eStargz, a layer format whose files can be found and read one by
one, they take a few ranged requests, and check what they read against the
layer's index. Layers in gzip, the default, can't be read that way.

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
"sdk": { "zig": "org.ziglang.zig:0.17.0@sha256:93ec2b6b36708ae8..." },
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
  ninja, cargo and zig redo only what those affect. It starts afresh when its
  module changes in the recipe, and with `zigsaw build --clean`. See
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
zigsaw pull org.nodejs.node:24.22.2                   # a version
zigsaw push org.nodejs.node ghcr.io/you/node          # tagged 24.22.2, the app's version
zigsaw pull ghcr.io/you/node:24.22.2                  # on another machine
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

### Pulling lazily

`zigsaw pull --lazy` installs an app before its large layers are downloaded,
so that it starts sooner. Each of their files is fetched the first time
something reads it, while the rest downloads in the background:

```powershell
zigsaw pull --lazy org.tug.texlive         # 236 MB of TeX Live; a document reads some 18
zigsaw list                                # org.tug.texlive ...  (downloading 37%)
```

It's for layers in eStargz (`"layer": "estargz"` in a recipe) of 32 MiB or
more: of the published images, VSCodium's, Electron's runtime, TeX Live's,
Qt's runtime and SDKs, and llvm-mingw, and Perl's and MinGit's, which TeX Live
and VSCodium run on.
An app's other layers download first, as without `--lazy`.
`zigsaw update --lazy` does the same for a new version, and, as a plain
`update` does, takes what the version before has from the store rather
than the registry: a run waits for a copy on disk, not a download, and only
what changed is fetched.

Here, from ghcr.io on a link of some 5 to 10 MB/s, from the start of the
pull to the first use (each row's two in the same hour):

| | full pull | `--lazy` |
|---|---|---|
| llvm-mingw, `clang hello.c` | 23.7 s | 15.7 s |
| Qt's runtime, Designer's window | 28.3 s | 8.8 s |
| Qt's SDK, `moc --version` | 47.4 s | 20.9 s |
| VSCodium's window | 38.0 s | 27.7 s |
| TeX Live, a first `pdflatex` | 96.6 s | 62.5 s |

Qt's rows are its images with their lists, measured in iteration 79; the
others are 78's, before 79's lists and its Perl and MinGit on eStargz. With
those, through a registry on this machine, TeX Live's first `pdflatex` came
25.9 s after the start of the pull, against 68.0 s for a full pull.
The write-ups of iterations [78](docs/iteration-78.md#results) and
[79](docs/iteration-79.md#results) have the numbers.

An image can say what its first run reads (a recipe's
[`prefetch`](docs/recipes.md#recipes)): those files come first in its
layer, and the helper asks for them all at once and puts them on disk before
the run gets to them, rather than as it asks, one after another. Qt's runtime
and SDK, TeX Live, Perl, VSCodium and Electron's runtime have such lists.

The layer's deployment starts as Windows' Cloud Files placeholders, as
OneDrive's files are: listed, with their sizes, and empty. A helper process,
which is zigsaw itself, gives Windows a file's bytes when a program first
opens it. It reads them from the registry, a file's chunks in parallel
requests, keeps what it fetched for the download, and checks
each chunk against the layer's TOC, which it checks against the image's
manifest, whose signature `pull` checked. So nothing unchecked reaches an
app, in any sandbox. Once the whole layer is downloaded and checked against
its digest, and no run of the app is going, the helper unpacks it as a plain
pull would, puts that where the placeholders were, and ends. From then on
the app is as if pulled without `--lazy`, and starts as fast.

Until then:

- **A file nothing has read needs the registry.** An app that's started
  offline and reads one fails, as a program fails whose files can't be read,
  often with a "bad image" error. zigsaw then says which file it couldn't
  fetch, and why.
- **The helper lasts as long as it has work.** Any run of the app starts it
  again if it's gone, after a reboot say, and `zigsaw rm` stops it. Its log is
  in the store's `lazy` folder. Started where everything a program starts ends
  with it, as in some terminals, the helper ends then too, and says so first;
  the app's next run starts it again.
- **A file is fetched whole** when a program opens it, and its first read
  costs a little more than in a plain deployment (some 7 ms here: Defender
  looking at it).
- **Placeholders need NTFS.** On a Dev Drive (ReFS), a network share or FAT,
  `--lazy` downloads the layer whole, and says so.
- **`push` waits for the download**: it refuses an app still downloading.

- **The layer unpacks once no run is using it**, so that the unpack doesn't
  slow the run down; an app left open stays on placeholders until it's closed.
- **The first run after the download is cold again**: the unpacked files are
  new to Windows, so that run pays what any first run on a fresh deployment
  does (TeX Live's `pdflatex`: 15 s once, then 0.3 s).

How it works, and why it's a bridge and not a way of keeping apps, is in
[how-it-works.md](docs/how-it-works.md#lazy-pulls).

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

### Signatures

Whoever could change what a registry serves could otherwise change what you install:
a tag is only a name, and a daily check would tell you to install it. So images and
zigsaw's own releases are signed, and zigsaw checks them before it installs anything.

They're signed keyless, by [Sigstore](https://www.sigstore.dev/), from zigsaw's own CI:
no key is kept anywhere. A certificate names who signed, and zigsaw takes only these:

- **an image**, by the Reproduce workflow on `main`, right after it rebuilt the image
  from its recipe and got the registry's digest. So a signature says what the
  [published jobs](#testing) check: this is what the recipe builds.
- **a release**, by the Release workflow run for that release's own tag, once a second
  runner built the tag to the same six programs and Reproduce passed on the commit.

```
> zigsaw pull org.nodejs.node
ghcr.io/zigsaw-io/org.nodejs.node: signed, by https://github.com/zigsaw-io/zigsaw/.github/workflows/reproduce.yml@refs/heads/main
```

The check is offline: the certificate must chain to Sigstore's Fulcio, and the signature
be in Sigstore's Rekor log, at a time the certificate was good. In Rekor v1 the log
promises that time; in Rekor v2 (from zigsaw 0.83.0) Sigstore's timestamp authority
vouches for it. Either way, the log's signed checkpoint and the entry's proof against it
must show the log holds the signature. The keys of all three are built into zigsaw.
Images signed before 0.81.0, with a key of zigsaw's, still count.

**What happens to an image from `ghcr.io/zigsaw-io`, on `pull` and `update`**, before
anything of it is downloaded:

- **Signed by someone who counts**: it goes on, and says who.
- **Signed wrongly**: refused, and nothing changes. Wrongly means by someone else (another
  workflow, branch or key), or of another image, or of an image under another name, or
  about anything but what was signed. An app already installed keeps running.
- **Not signed**: for now a warning, and it goes on. So this doesn't stop someone who
  simply leaves the signature off, unless you notice the warning, and a script with
  `--yes` won't: **a later release will refuse these**. A newly published image is unsigned
  until Reproduce has rebuilt it, which is on the push after publishing. Older versions
  stay unsigned on purpose, as many have known vulnerabilities.
- **A registry that won't answer** is an error, not "not signed".

`zigsaw info` has a line saying which of these an image is. What a recipe pins by digest
isn't checked, as the digest says exactly what it wants, and a signature on the app's
image covers its runtimes, whose layers its manifest lists.

**`zigsaw upgrade` always requires a signature**, of the release's `SHA256SUMS`, which
lists the zip and `VERSION`: `SHA256SUMS.sigstore.json`, keyless, as above. Until the
Release workflow has signed, nobody is told about a release. One more key counts for
releases, kept offline: should Sigstore's keys ever change past what a zigsaw knows, a
release signed with it by hand ([`scripts/sign-release.sh`](scripts/sign-release.sh))
still reaches that zigsaw. 0.73.0's `upgrade` doesn't check, so its upgrade to 0.74.0
isn't checked.

**To check by hand**, with stock [cosign](https://github.com/sigstore/cosign):

```powershell
zigsaw signature payload org.nodejs.node > payload.json   # or the payload layer beside it
cosign verify-blob --bundle bundle.json payload.json `
  --certificate-identity https://github.com/zigsaw-io/zigsaw/.github/workflows/reproduce.yml@refs/heads/main `
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
cosign verify-blob --bundle SHA256SUMS.sigstore.json SHA256SUMS `
  --certificate-identity https://github.com/zigsaw-io/zigsaw/.github/workflows/release.yml@refs/tags/v0.81.0 `
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

An image's bundle is the layer `application/vnd.dev.sigstore.bundle.v0.3+json` of the
manifest tagged `sha256-<digest>.sigstore` beside it (`oras pull` gets it). That tag is
zigsaw's, not where `cosign verify` looks: zigsaws before 0.81.0 refuse what they can't
check where they look, so this is where they don't.

**For your own images**, tell zigsaw whose signature counts, once per store: a workflow
of yours that signs keyless, or a key.

```powershell
zigsaw trust add ghcr.io/me --keyless https://github.com/me/app/.github/workflows/release.yml@refs/heads/main
zigsaw trust add ghcr.io/me cosign.pub   # images under ghcr.io/me, by whole path components
zigsaw trust                             # who counts where, built-in ones too
zigsaw trust rm ghcr.io/me               # and away again
```

`--issuer` names another identity provider than GitHub Actions'. Keys are ECDSA P-256 only,
which is what `cosign generate-key-pair` makes. An image under nobody says it wasn't
checked, and installs. To sign keyless, have `cosign sign-blob --bundle` sign what
`zigsaw signature payload <image>` prints, and `zigsaw signature push-bundle` puts the
bundle beside the image with your registry login, once it's checked it as a pull would.
With a key, `cosign sign-blob` and `zigsaw signature push`, in cosign's classic layout
(a tag named `sha256-<digest>.sig`). [`scripts/sign-images.sh`](scripts/sign-images.sh)
is what CI runs for the published recipes. No digest changes: a signature is beside its
image, not in it.

What this doesn't do is in [the gaps](docs/gaps.md).

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
`update` exits with 1. An app pulled by digest is pinned and left alone, and
so is one you [hold](#going-back-and-holding).

`zigsaw update --check` says what `update` would find, and installs nothing. It
reads each tag's manifest, and the config of an image that's new, and no
layers. An app a new image waits for gets a line on stdout, followed by what
the new version may reach beyond the installed one; nothing on stdout means
there's nothing to update. Apps with nothing new get a note on stderr. A recipe
isn't built for this, so an app built from one only says so. It exits with 1 if
an app couldn't be checked, and with 0 otherwise, whatever it found:

```
> zigsaw update --check
org.nodejs.node 24.21.0 -> 24.22.2 (5e1c07a2 -> 91bd44f0)
com.example.Tool 1.4 -> 1.5 (0a93c6d1 -> 77e2ab10)
  permits    network
```

### Going back, and holding

An update that breaks something can be undone. When a new version of an app is
installed, by `update`, `pull` or `build`, the store keeps the blobs of the version
it replaced, and `zigsaw rollback <app-id>` installs that one again. It needs no
network, as everything is in the store already; its files are unpacked again, so it
takes about as long as an install that downloads nothing. Should the earlier version
reach more than the installed one, it asks first, as `update` does, unless given
`--yes`. The image was checked against its signature when it came in, and isn't again.

```
> zigsaw rollback com.github.junegunn.fzf
installed com.github.junegunn.fzf 0.74.4
  ...
went back: com.github.junegunn.fzf 0.74.5 -> 0.74.4 (sha256:703f25eb6bc0 -> sha256:4d8759253203)
  `zigsaw update` passes over 0.74.5 from now on, and takes a newer version; `zigsaw rollback com.github.junegunn.fzf` returns to it
```

From then on, `update`, `update --check` and the [daily check](#being-told-about-updates)
pass over the version you went back from, with a note, but not a newer one: when the
next version comes out, it's an update as any other. `rollback` again returns to the
version you left. `zigsaw list` shows `(previous <version>)` while there's one to go
back to, `(previous <version>, with data)` if its data is kept as well, and
`(skips <version>)` after a rollback.

Only one version is kept, the one the installed version replaced, and only its blobs:
`prune` keeps them, and deletes its unpacked files as before. `prune --previous` forgets
those versions, and deletes their blobs. A zigsaw before 0.76 doesn't know of them, and
its `prune` deletes them; `rollback` then says how to have the version back, as
`zigsaw pull <image>@<digest>` while its registry still has it.

**Its data can go back too.** An app that changed how it keeps its data, as
PostgreSQL's server does from one major version to the next, may not read it any more
after going back. So when an install replaces an app's version, zigsaw first copies the
app's data, [its own volume](#volumes), as that version left it, and says how much that
was and how long it took:

```
  kept     its data as 18.6 left it (39.9MiB in 978 file(s), copied in 280 ms), for `zigsaw rollback`
```

`rollback` then says what is kept, and asks whether the data is to go back with the
version. Its answer is no unless you say yes. Here between two images of PostgreSQL
18.6, a new cluster with one table:

```
> zigsaw rollback org.postgresql.PostgreSQL
org.postgresql.PostgreSQL's data as 18.6 left it just now is kept (39.9MiB in 978 file(s)). Taking it back sets aside what 18.6 wrote since, until the next update of the app.
Take its data back too? [y/N] y
installed org.postgresql.PostgreSQL 18.6
  ...
went back: org.postgresql.PostgreSQL 18.6 -> 18.6 (sha256:0198588f23b9 -> sha256:f0f2fa89b421)
  `zigsaw update` passes over 18.6 from now on, and takes a newer version; `zigsaw rollback org.postgresql.PostgreSQL` returns to it
  its data went back too, to how 18.6 left it just now; what 18.6 wrote since is set aside, and returns with `zigsaw rollback --data org.postgresql.PostgreSQL`, until the next update of the app
```

`--data` answers yes and `--keep-data` no, without asking; with nothing to answer, as
in a script, the data stays. Taking the data back swaps two folders in the store, so it
takes no time, and nothing is lost by it: what the newer version wrote since is set
aside in the copy's place, and going forward again, with `rollback --data`, brings it
back. If you left the data and the older version turns out not to read it,
`zigsaw rollback --data-only <app-id>` takes the data back without changing the version.

What to know about the copy:

- **One is kept for each app**, as one previous version is. The next install of the app
  replaces it, the data a rollback set aside included: the update says so when it drops
  that. `prune` keeps the copies and says what they take; `prune --previous` deletes them
  with the versions, and `rm` deletes an app's.
- **It's the app's own volume only.** A volume the app mounts and a folder of yours it
  may use are neither copied nor changed, and are there again after going back. An app
  whose data is mounted from elsewhere (`--volume=<source>:.`) gets no copy.
- **Its temporary files and cache are left out**, and start empty in data taken back.
- **It's taken while the app doesn't run.** If it runs when its version is replaced, its
  next run takes the copy before it starts, which a large one makes slower to start.
- **It costs the size of the data, and the time to copy it, at each update.**
  `zigsaw override --nosnapshot <app-id>` keeps an app's data from being copied, and
  `--snapshot` has it copied again; with `--global`, every app's. On a Dev Drive the
  copy shares its blocks with the data, and takes next to nothing of either.
- **It's no backup**: it's in the store, beside the data, and gone with the next update.

`zigsaw hold <app-id>...` keeps updates away from apps altogether, until
`zigsaw unhold <app-id>...`. `update` notes that a held app is held and leaves it, named
or not, and nothing contacts its registry: `update --check` and the daily check never
list it, and what a check found before goes from `zigsaw updates`. `pull`, `build` and
`rollback` still install what they're asked to, and the app stays held. `zigsaw list`
shows `(held)`. `rm` forgets all of this along with the app.

### Being told about updates

Nothing updates by itself: a program you depend on doesn't change between two runs
because a day went by. But a fix nobody hears about helps nobody, so `install.ps1`
starts a daily check, which only tells you:

- **What it is:** a scheduled task of your own, named `Zigsaw update check`, which
  needs no administrator, runs with your rights and only while you're signed in, and
  starts `zigsaw-notify.exe`, a program with no window. `zigsaw grants` lists it.
- **What it reaches:** once a day, the registry each of your apps came from, for that
  app's manifest and, if it's new, its config; and `github.com`, for a one-line file
  saying zigsaw's latest version and, if it's new, the signature that says so. No layers,
  so it's small on a metered connection too.
  It sends nothing that identifies you beyond what any request does, and a login you
  saved for a private registry goes to that registry as usual.
- **What it does:** if something's waiting, a notification says so. Clicking it opens
  a terminal listing what's waiting and the commands that install it. Nothing gets
  installed unless you run those.
- **How often:** a banner lasts seconds, and one you miss is gone, so what's waiting
  is told again every three days until you've looked at it, by clicking or with
  `zigsaw updates`. Something new is told at once. While Windows holds notifications
  back (full screen, Do Not Disturb) it waits for the next check. `zigsaw list` has a
  line about it too.

```
> zigsaw updates
Last checked 3 hours ago.

Waiting to be installed, with `zigsaw update`:
  org.nodejs.node 24.21.0 -> 24.22.2 (5e1c07a2 -> 91bd44f0)

zigsaw 0.74.0 is out; this is 0.73.0. `zigsaw upgrade` installs it.

A daily check is on; it installs nothing. `zigsaw updates off` stops it.
```

`zigsaw updates` only reads what the last check kept; `zigsaw updates check` looks
now. An app pulled by digest is pinned, one built from a recipe only rebuilding
can tell about, and one you hold is left alone: none is ever listed. Nor is a version
you went back from with `rollback`. `zigsaw updates off` removes the task and
remembers, in `updates\off` in the store; `zigsaw updates on` starts it again. A store
that isn't the default one gets a task only if `updates on` is run for it, and that
task, should the store be deleted, is removed by `zigsaw repair` or when it next runs.

`zigsaw upgrade` installs zigsaw's latest release, once you agree (or with `--yes`),
as `install.ps1` does, and more carefully: it checks the [signature](#signatures) of the
release's `SHA256SUMS`, the zip against that, starts the new program to see that it runs
here and is the version it should be, and only then replaces the old ones, moving those
that are running aside. Should anything go wrong before that, nothing changes. It never
runs by itself. It only replaces a zigsaw in its store's `bin`; one anywhere else, as a
build of your own, says how to install one instead, and isn't told about new releases.

### Removing what's old

Installing a new version deletes the files of the one it replaces, unless
that version is still running. `zigsaw prune` deletes everything else no
installed app needs: the blobs of old versions, files kept because they were
running, and whatever an interrupted build left in `tmp\`. It keeps the blobs
of each app's previous version, and the copy of the app's data as that version
left it, for [`rollback`](#going-back-and-holding), and
says how much they take; `--previous` deletes them too. `--dry-run` shows
what it would delete. Cached downloads, the runtimes that builds used,
build tools' caches and the [builds kept for the next one to go on
from](docs/recipes.md#going-on-from-the-last-build) stay unless you add
`--downloads`. The
[volumes](#volumes) nothing mounts, the data of uninstalled apps among them, are kept
unless you add `--volumes`; `prune` names them.

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
| `--share=commands` / `--unshare=commands` | Put [your zigsaw apps' commands](#your-apps-commands-and-your-own-programs) on the run's PATH, or not (`soft` sandbox only) |
| `--share=host` / `--unshare=host` | Put [`zigsaw-host`](#your-apps-commands-and-your-own-programs) on the run's PATH, or not (not in an AppContainer) |
| `--port=<name>=<port>` | Serve one of the app's [services](#services) on another port, or reach a port it [uses](#reaching-this-machine) on another |
| `--env=NAME=VALUE` | Set an environment variable |
| `--noextension=<id>` | Leave out an installed [extension](docs/recipes.md#extension-points), which otherwise joins the runs of what it extends; `--extension=<id>` has one an override leaves out join again |
| `--volume=<source>:<path>[:ro]` | Mount a [volume](#volumes), by its name, or a folder of yours, by its absolute path, at a path in the app's data directory; at `.`, as all of its data |
| `--novolume=<path>` | Take away the mount an override has at that path |
| `--ephemeral` | Use a fresh data directory, deleted after the run; the volumes mounted in it stay |
| `--memory=<size>` | Let the app and all it starts have no more memory than this together (`2GB`, `512MB`); `none` takes away what an override has ([limits](#limits)) |
| `--cpus=<n>` | Run the app and all it starts on n processors; `all` takes away what an override has ([limits](#limits)) |
| `-v`, `--verbose` | Print the resolved command, environment and grants, and afterwards the most memory the run had |

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

An image may ask for another sandbox than low, which `pull` and `info`
show. Kanboard's asks for `soft`, as PHP can't tell it may write its data at
low integrity. So do toolchains' (zig, Rust, Go, CMake, make, Meson, Node,
Python, the JDK, Maven, Gradle, and the GTK, Qt and PHP SDKs): Windows
starts a program labelled low at low integrity wherever it's started from,
and what a low-integrity compiler writes is labelled low. Your overrides choose over the image, and a run's `--sandbox`
over both: `zigsaw override --sandbox=soft <app>` for one app, `zigsaw
override --global --sandbox=soft` for every app ([below](#changing-an-apps-options)).

Low integrity won't label your user profile, a folder that holds it, or a
drive's root, as every low-integrity program could then write anywhere in
it. An app that may write its working directory, run from one of those,
gets it read-only for that run, with a warning: `7z` from your home folder
reads it, and can't extract an archive there. Run it from a folder inside,
or with `--sandbox=soft`. Nor will any sandbox let an app write zigsaw's
store, the folder `zigsaw.exe` is in, or a folder that holds either: every
app's programs would then start at low integrity.

A program a run writes comes out labelled low too: 7-Zip extracting one, or
git checking one out. zigsaw takes the label off once the app's runs have
ended, so that it starts at medium integrity, as any program you run does.

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

### Your apps' commands and your own programs

A run's PATH has the app's own directories and the system's, so that what it does
doesn't depend on what's on the machine. An app that's there to run other things,
as an editor's terminal is, can ask for more, or you can give it more with an
override:

```
zigsaw override --share=commands org.example.Editor
```

- **`--share=commands`** puts the store's `bin` on its PATH, after the system's. In
  the app's terminal, `zig` or `rg` then runs the app you installed, as itself: with
  its own data and sandbox, and ending with the run that started it. An extension
  that looks for a tool finds it the same way. It works under `soft` only, as a
  zigsaw at low integrity can't open the store; a run under another sandbox says so.
- **`--share=host`** puts `zigsaw-host` on its PATH, as `flatpak-spawn --host` is on
  Linux: `zigsaw-host cargo build` finds `cargo` on your own PATH, and runs it in
  your real environment, with your real `USERPROFILE`. It keeps the run's rights, so
  in a low run it runs at low integrity, and it ends with the run. It isn't there in
  an AppContainer, whose programs couldn't read their own files.

VSCodium's image asks for both. Its terminal gets your real environment with a
profile in its settings, which an extension's commands don't:

```json
"terminal.integrated.profiles.windows": {
  "Host shell": { "path": "zigsaw-host", "args": ["powershell"] }
}
```

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
- Deleting the app's data (`zigsaw rm --delete-data`, `prune --volumes`,
  `--ephemeral`) removes the links, never what's in your folders.
- A store that isn't your default one, `%LOCALAPPDATA%\zigsaw`, leaves your real
  folders out of its apps' runs, and says so, until `zigsaw override --global
  --real-folders`, which is saved in that store. If `ZIGSAW_HOME` is your real
  store, run that once: from 0.70.0 its apps lose your folders until you do. A
  folder named by its path, or a working directory, isn't affected.
- `ZIGSAW_USER_FOLDERS=<dir>` makes `<dir>\Documents` and so on stand in for
  yours, in any store: the tests use it.

#### What zigsaw changed outside its stores

`zigsaw grants` lists it: for each app, the low labels on your paths and what its
container was given, and why each is there and how long it lasts; what other
stores of yours changed; and what stores since deleted left behind. Windows keeps
a label until something takes it away, so deleting a store doesn't. A copy of each
store's list is kept outside it, in `HKCU\Software\Zigsaw\Grants`, for that:
`zigsaw repair`, from any store, takes back what a deleted one left, unless a
store that's still there needs it. `install.ps1` runs `repair` on an upgrade.
It lists the [daily check for updates](#being-told-about-updates) as well, the one
thing zigsaw puts in Task Scheduler, which `zigsaw updates off` removes.

It also looks at your six folders and your profile, and lists under **Not
explained** a low label that no record has, as a program other than zigsaw could
leave, or a zigsaw before 0.70. `zigsaw grants --take-back <path>` removes one; a
label a record has goes the way it came, with `zigsaw rm` or an override, as the
app would only make it again. `zigsaw list` says, in one line, when anything is
left over or unexplained.

The GUI apps zigsaw publishes declare the folders they open files from:
7-Zip, Notepad++, SumatraPDF, Text Editor and Rnote your Desktop, Documents
and Downloads (Rnote Pictures too, for exports), and VLC your Desktop,
Downloads, Music, Pictures and Videos. Images that use folder names need
zigsaw 0.18.0 or later; and a permission this zigsaw doesn't know, from a
later one, is left out of a run with a warning, rather than refused.

### Volumes

A volume, as Docker has them, is a folder that apps keep files in. Every app has
one of its own, named by its id: its data directory, `volumes\<app-id>` in the
store, which its first run makes. `zigsaw rm --delete-data` deletes it with the
app; without that it stays, a volume nothing mounts, until `zigsaw volume prune`
or the app's return. An `--ephemeral` run has a fresh one instead, deleted as
the run ends.

`--volume` mounts another volume at a path in the app's data directory. It
outlives the app's own, and other apps may mount it too:

```powershell
zigsaw override --volume=pgdata:data org.postgresql.PostgreSQL   # its cluster, PGDATA, in a volume
zigsaw override --volume=D:\settings\codium:home\AppData\Roaming\VSCodium com.vscodium.codium
                                                                  # its settings in a folder of yours
zigsaw override --volume=D:\pg:. org.postgresql.PostgreSQL        # all of its data on D:
zigsaw volume create --path=D:\volumes\pg pg                      # a named volume kept on D:
zigsaw volume ls
```

```
> zigsaw volume ls
NAME                      LOCATION                                 MOUNTED BY
org.postgresql.PostgreSQL store                                    org.postgresql.PostgreSQL as its data
pgdata                    store                                    org.postgresql.PostgreSQL at data
```

- The source is a volume's name, or a folder of yours by its absolute path (a bind
  mount). A volume's name has 2 to 64 letters, digits, `_` and `-`; one the store
  doesn't have yet is made in it, in `volumes\<name>`, by the first run that mounts it.
  `zigsaw volume create --path=<dir> <name>` names a folder elsewhere instead, which
  may have files already. An app's own volume has the app's id for its name, and
  only that app mounts it.
- The path is relative to the app's data directory: `data` is the folder PostgreSQL's
  `PGDATA` names, `home\AppData\Roaming\<app>` where an app keeps its settings. It
  can't be where zigsaw keeps something of its own (`registry`, `home` and its
  `AppData`, the temporary folder, your folders' links), and two mounts can't
  overlap. `:ro` makes the mount read-only, under `low` and `appcontainer`.
- The path `.` is the data directory itself: the source takes the place of the app's
  own volume, and everything the app keeps is then in it, its settings and registry
  keys too. That is how an app's data goes to another drive. Only one app may have a
  folder as its data, it can't be read-only, and an `--ephemeral` run leaves it out.
  `--novolume=.` gives the app a volume of its own again, a fresh one: the files stay
  in the folder.
- Windows has no mount namespaces, so a mount is a link (a directory junction) at that
  path, to the volume's folder; one at `.` is a link at `volumes\<app-id>`, so the
  app's paths stay what they were. Deleting the app's own volume stops at a link, and
  leaves the volume it points to as it is.
- The folder is granted as a `--filesystem` path is, and as long: labelled low under
  `low`, given to the app's AppContainer under `appcontainer`. A mount only on the
  command line, and its link, go when the app's last run ends; a saved one
  (`zigsaw override --volume`) stays until `--novolume=<path>` takes it away. As with
  folders, a volume one app may write is writable by every low-integrity program
  while it's labelled.
- The first run of a saved mount moves the app's own files at the path into the
  volume, if the volume is empty, as Docker fills an empty volume: how PostgreSQL's
  cluster moves into one. It only renames, so the volume has to be on the drive of
  the app's data. A mount on the command line, a read-only one, or one of a volume
  that has files refuses instead, and leaves the app's files as they are.
- `zigsaw volume inspect <name>` shows a volume's size, what mounts it, and what it was
  granted. `zigsaw volume rm` deletes a volume in the store, and forgets one kept
  elsewhere, leaving its files; it refuses one an override mounts, one a run uses,
  and the data of an app that's installed (`zigsaw rm --delete-data` deletes that).
- One rule says what's left over: a volume in the store that nothing mounts. No
  override names it, and it isn't the data of an installed app. `zigsaw volume prune`
  and `zigsaw prune --volumes` delete those, the data of uninstalled apps with the
  named ones; `zigsaw prune` names them, and `--dry-run` shows what would go. Before
  0.85 that was `prune --data`, for apps' data only: it now says to use `--volumes`.
- An `--ephemeral` run mounts its volumes too: a fresh app, and the volume's files.
- A zigsaw before 0.80 can't read overrides that have volumes: `override --reset`
  makes it work again.

**A volume as a file, and back.** `zigsaw volume export` writes a volume's files to a
tar, and `zigsaw volume import` makes a tar's files a volume's: a copy to keep before
something risky, or an app's data on its way to another machine.

```powershell
zigsaw volume export pgdata D:\backup\pgdata.tar                 # a named volume
zigsaw volume export org.postgresql.PostgreSQL D:\backup\pg.tar.gz   # an app's data, by its id
zigsaw volume import pgdata D:\backup\pgdata.tar                 # into a new volume, or an empty one
zigsaw volume import --replace org.postgresql.PostgreSQL D:\backup\pg.tar.gz   # over the data it has
zigsaw volume export pgdata - | ssh other zigsaw volume import pgdata -        # through a pipe
```

- The file is a plain tar that `tar`, 7-Zip and `podman volume import` read, with the
  volume's files at its root; a name that ends in `.tar.gz` or `.tgz` makes it gzip.
  Import takes a tar from any of them, compressed or not, whatever its name.
- It keeps files, folders (empty ones too), each file's time of last change and whether
  it's read-only. Not ACLs, other attributes or alternate streams.
- **An app's own volume goes without its temporary files and its cache** (`cache\` and
  `home\AppData\Local\Temp`), as the copy kept for [`rollback`](#going-back-and-holding) does;
  `--all` has those too. The keys it keeps in the registry are in the archive, as they're
  in its data between runs. A named volume is always exported whole.
- **A link is passed over**, and export says how many: a volume mounted in the app's data
  is a link there, and is exported by its own name.
- **Neither works on a volume a run uses**: the archive has the files as one moment left
  them, and an import never changes files under an app. Stop the app first.
- **Import leaves files alone unless you say `--replace`.** Without it, a volume that has
  any refuses. With it, the archive is unpacked beside the old files first; only when
  all of it is there are they swapped, and the old ones deleted. An archive that is cut
  short, isn't a tar, or has a name Windows can't have (or a path that leads out of the
  volume) leaves the volume as it was. The volume's folder stays the same one, so what it
  was granted and what mounts it stay too; links among the old files go with them, never
  what they lead to, and the app's next run makes its mounts again.
- Importing by an app's id works before the app is installed: the data waits in
  `volumes\<app-id>` for it. `zigsaw volume prune` would delete it meanwhile, as any
  uninstalled app's.
- An app whose data is mounted from elsewhere (`--volume=<source>:.`) has no volume of
  its own to export: export the volume it names, or copy the folder.
- **Coming from a zigsaw before 0.85**, which kept an app's data in `data\<app-id>`:
  the first command of the new one moves each app's data to `volumes\<app-id>`, and
  says so; the data of an app that's running moves once it has ended. `zigsaw repair`,
  which installing and `zigsaw upgrade` run, points commands and shortcuts there. A
  path an app saved in its own settings as `...\data\<app-id>\...` no longer leads
  anywhere, and a zigsaw before 0.85 run on the store afterwards starts each app
  with empty data in `data\`. If that left files, the new one tells you about them
  and leaves them; if it left only empty folders, from 0.86 on the new one deletes
  them without a word.

### Limits

A run, and each command of a build, can be held to an amount of memory and a number
of processors. Both hold the whole process tree: the app, everything it starts, and
what those start. Neither needs administrator rights, and neither is ever set by an
image or a recipe: they are yours, per machine.

```
zigsaw run --memory=2GB --cpus=4 org.example.App       # this run
zigsaw override --memory=4GB org.example.App           # every run of the app, its shims' too
zigsaw override --global --cpus=8                      # every app of the store
zigsaw run --memory=none --cpus=all org.example.App    # this run, without what's saved
zigsaw build --memory=8GB --cpus=8 recipes/rnote.json  # each of the build's commands
```

- **`--memory=<size>`** takes bytes, or a number with `K`, `M`, `G` or `T` (1024-based,
  `2GB`, `512M`). It counts memory the processes have committed, together. Past it
  Windows refuses a process more, exactly as it does when the page file is full, so
  the program fails the way it does then: most say "out of memory" or "The paging
  file is too small" and exit. zigsaw then says which limit was reached, after the
  run, or after the build's command.
- **`--cpus=<n>`** gives the tree n of your processors, one of each core before a
  second of any, the faster cores first on a machine with two kinds. Programs that
  ask Windows which processors they have count n: Go, Node and BusyBox's `nproc` do.
  The tree is also capped at n processors' worth of the machine's processor time,
  which costs nothing more and is what Ninja counts by. For programs that count the
  machine's processors whatever they are given, `NUMBER_OF_PROCESSORS` and
  `CARGO_BUILD_JOBS` are set to n, unless the app, the recipe's module or `--env`
  sets them: cargo then starts n compilers. With as many processors as zigsaw itself
  has, or more, `--cpus` limits nothing and sets nothing.
- `zigsaw -v run` prints the most memory the run had at once, and `zigsaw -v build`
  the same for each command that takes a second or more: a number to pick a limit
  from.
- A limited run inside another (an app that runs your other apps' commands) gets the
  tighter of the two. What `zigsaw-host` starts counts toward the run that started it.

What limits don't do is in [gaps.md](docs/gaps.md).

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

Chromium's and Electron's programs bring a sandbox of their own, which Windows
doesn't let start at low integrity or in an AppContainer: VSCodium,
ungoogled-chromium and draw.io ask for `soft`, and exit at once under the others
([what's needed](docs/recipes.md#chromium-and-electron),
[what was found](docs/findings.md#chromium-and-electron)). draw.io runs on
Electron's runtime, a 158 MB image that apps made with Electron can share, as
other apps share Node's or Java's
([apps on it](docs/recipes.md#apps-on-electrons-runtime)).

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

Each shortcut also names the app's taskbar button (its AppUserModelID),
`Zigsaw.<app id>`. Windows of a program that names the same button are the
shortcut's, however the program was started, and pinning one to the taskbar
pins the shortcut, which runs the app through zigsaw. Apps on
[Electron's runtime](docs/recipes.md#apps-on-electrons-runtime) name it; an app
that names a button of its own, as VSCodium does, keeps its own. Shortcuts made
before 0.92 get the name from `zigsaw repair`, which an upgrade runs.

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

### URL schemes

A recipe can declare the kinds of link its app opens, as Flatpak apps declare
`x-scheme-handler` types:

```json
"schemes": {
  "vscodium": { "command": "codium-url", "description": "VSCodium link" }
}
```

Installing the app registers them for your user only, with no administrator, and
`zigsaw rm` removes them. `zigsaw list` and `zigsaw info` show them with what it
opens, as `vscodium:`.

- **A scheme nothing else has opens with the app.** One something does have, such
  as `http` or one a program installed the usual way registered, stays as it is, and
  the app is only offered for it.
- **Offered means listed for Settings' Default apps**, with the app's file types,
  where you may choose it. zigsaw never makes an app the default: Windows keeps
  that to you.
- **A link opens through a shim of its own**, in the store's `open` directory, which
  takes one argument, a URL of a scheme that app declares, and otherwise starts
  nothing. A link can't reach the app as a switch, whatever the app itself checks
  ([findings](docs/findings.md#what-windows-does-with-a-link)). It's granted nothing:
  the app gets the text of the link, in the sandbox it always has.
- **An export names what goes before the link.** VSCodium's `codium-url` is
  `VSCodium.exe --open-url --`.
- A scheme can't be one of Windows' own (`file`, `ms-settings` and the like).

An app that registers itself from inside a run, as Electron apps do, gets a key
that names its program in the store's deployments, and skips zigsaw. Installing an
image that declares the scheme takes such a key over, and `zigsaw repair` and
`zigsaw rm` remove one that nothing declares. A recipe should take that call out
([Chromium and Electron](docs/recipes.md#chromium-and-electron)).

### Changing an app's options

`zigsaw override` saves run options for an app, and every run of it gets them,
including runs through its commands on PATH. It takes the same options as
`run`, except `--command`:

```powershell
zigsaw override --sandbox=appcontainer com.github.BurntSushi.ripgrep   # rg reads only what it may
zigsaw override --sandbox=soft org.7_zip.7zip                          # 7z writes anywhere, as before 0.54
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
bash tests/reach.sh     # what a run may reach of the rest of the machine: the store's commands on its PATH, each running as its own app; zigsaw-host, your real environment with the run's rights; an image saying it can't run under a sandbox; URL schemes and Default apps in a scratch key, and one private scheme followed through Windows, which rm removes (30 s; opens a console for a moment)
bash tests/limits.sh    # --memory and --cpus on runs, in each sandbox, saved as overrides, through a shim, and on builds; what zigsaw says when a limit is reached
bash tests/shims.sh     # command shims end to end, also for commands installed at run time and GUI programs; Start menu shortcuts; file associations (in a scratch registry key)
bash tests/store.sh     # update, prune, and what they keep while apps run, and for rollback
bash tests/upstream.sh  # scripts/check-upstream.sh with made-up recipes, pages, repositories and OSV answers, and that scripts/upstream.txt covers every recipe's sources (no network; runs on Linux too)
bash tests/rebuild.sh   # scripts/rebuild.sh with made-up recipes and a stand-in zigsaw: its order, pins, stopping and going on (no network; runs on Linux too)
bash tests/build.sh     # building apps: runtimes, images as sources, projects with a zigsaw.json, builds that go on from the last one, build commands on B:, tool caches, aliases, vendor steps, CMake, Meson, Rust, Go, cgo, .NET (WinForms and WPF too), extension points, PHP extensions with zig, reproducibility
GROUP=langs bash tests/build.sh # only one group of its sections (tests/build.sh --groups lists them), as a CI job does
SECTIONS=php bash tests/build.sh # only these sections
bash tests/standard-user.sh account.txt # zigsaw as a real standard user, in an account of its own you've made: the Quick start, your real folders (safe there), a guard's refusal, a store deleted by hand, and the suites that need no app's image
bash scripts/defender-scan.sh # what Defender makes of a package's programs (scripts/package.sh first)
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
bash tests/chromium.sh # ungoogled-chromium, VSCodium and draw.io (on Electron's runtime, with a test app beside it) in each sandbox, with Windows' word on how their processes are confined: pages, WebGL, H.264, a second launch, downloads, a task in VSCodium's terminal with your apps' commands and zigsaw-host, an extension saving a file, a diagram exported from the console, packaged mode, a taskbar button per app, one deployment of the runtime for both; links through the shims and through Windows; shims, shortcuts and what they leave outside, the keys of HKCU's Classes, RegisteredApplications, Clients and Run included
bash tests/zls.sh       # ZLS's language server sessions over stdio in each sandbox: the standard library's documentation, a module a project's build.zig declares, a syntax error; its shim (needs ZLS_HOME or BUILD_HOME, or builds it)
bash tests/php.sh       # PHP's runtime in each sandbox, HTTPS; seven extensions built with php-ext (yaml and zstd with libraries their recipes build) join PHP's runs once installed, and pass their test suites (ssh2 and redis against servers built with Go); an app with two as runtimes, and Xdebug's step debugger; Composer offline; Kanboard's pages and API, in an AppContainer through its service too (needs PHP_HOME or BUILD_HOME; local only)
bash tests/install.sh   # scripts/package.sh's release files, and install.ps1 installing, upgrading and removing zigsaw (in a scratch directory and registry key); `zigsaw upgrade` from a later release of the same code, a running program moved aside and every way of refusing; the daily check in a scratch default store (about 2 min)
bash tests/upgrade.sh   # v0.80.0 and v0.83.0 from GitHub, each with a store of its own (data, a command a run added, a shortcut, a named volume, keys a killed run left in HKCU), upgraded with `zigsaw upgrade` to this checkout's package: everything where this zigsaw keeps it, and still working (RELEASES narrows it; under 1 min)
bash tests/zot.sh bash tests/updates.sh # what a check finds, keeps and tells, and that nothing installs anything; real scheduled tasks under this run's own name, which it removes, and the real one untouched (under 1 min; without a registry, only the task rows)
bash tests/zot.sh bash tests/rollback.sh # the version an update replaces is kept, rollback goes back to it without the network and updates pass over the version left, a newer one gets through, hold and unhold; an install over a version copies the app's data, a rollback asks and takes it back or leaves it, --data-only, while the app runs, a swap that didn't finish, --nosnapshot (under 1 min)
bash tests/zot.sh bash tests/lazy.sh # pull --lazy: placeholders served under each sandbox, a file's chunks in a few requests, a recipe's prefetch files first in the layer and hydrated ahead, a helper that comes back, goes on from what the last one fetched and says what it couldn't fetch, a download that fetches nothing twice, the swap once the download's done and no run uses it, rm, a job that keeps what it starts, a whole download where placeholders can't be, update --lazy copying what the version before has (a source gone, a copy wrong), and a slow fetch telling Windows how far it's got (under 1 min; needs NTFS: LAZY_WORK, and LAZY_DEV_DRIVE for a real Dev Drive row; LAZY_WAIT=90000 for a fetch past Windows' 60 s)
bash tests/zot.sh bash tests/signing.sh # what pull, update and info do with an image's good, wrong and missing signature, with keys `zigsaw trust` adds (under 1 min)
bash tests/self.sh      # zigsaw building this checkout's zigsaw.json makes the same programs as zig build -Dstrip (the Release workflow runs it on its package); an incremental build of a copy after a change makes what --clean does
bash tests/ctrlc.sh     # Ctrl+C, Ctrl+Break and closing the console, in a pseudoconsole
bash tests/batch.sh     # batch files as commands: arguments arrive exactly, and run nothing
bash tests/registry.sh  # push, pull, update, mounts, chunked uploads that break off, multi-platform indexes, logins (zigsaw's and Docker's), sources next to images, the catalog, search and info, through local registries (see its header)
bash tests/oci.sh       # ORAS, skopeo and cosign against local registries, under tests/zot.sh: a file pushed and pulled, an image zigsaw pushed listed, copied to the registry that wants a login and into an OCI layout, signed with a key pair without the internet and verified, each tool's own login; a few runs in an AppContainer (needs OCI_HOME or BUILD_HOME, or builds them)
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
