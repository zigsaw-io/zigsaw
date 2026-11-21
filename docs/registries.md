# Sharing apps through registries

zigsaw images are standard OCI images, so any OCI registry can hold them:
ghcr.io, Docker Hub, a self-hosted zot or distribution. An image is named
`<registry>/<repository>[:tag][@digest]`, or just by app id for the app's
image in a remote (see [Remotes](#remotes)):

```powershell
zigsaw install org.nodejs.node                           # ghcr.io/zigsaw-io/org.nodejs.node:latest
zigsaw install org.nodejs.node:24.22.2                   # a version
zigsaw remote-add mine ghcr.io/you
zigsaw build-export org.nodejs.node mine                 # ghcr.io/you/org.nodejs.node:24.22.2, the app's version
zigsaw install mine org.nodejs.node:24.22.2              # on another machine, with the remote added there
zigsaw install ghcr.io/you/org.nodejs.node@sha256:f25237a3...   # exactly this build, no remote needed
```

An app id stands for `<remote>/<app id in lower case>`, and the image must
hold that app. Installed apps remember the full reference they came from, so
`zigsaw update` keeps using it, whatever becomes of the remote.

## Remotes

A remote, as in Flatpak, is a name for where apps' images are: a registry and
a path in it. A store has one until told otherwise, `zigsaw`, which is
`ghcr.io/zigsaw-io`, where the [published apps](#published-apps) are.

```powershell
zigsaw remotes                                   # each, in order, who signs its images, its login
zigsaw remote-add mine ghcr.io/you               # or oci+https://ghcr.io/you, as Flatpak writes it
zigsaw remote-add --sign-key=cosign.pub --login work registry.example.com/apps
zigsaw remote-modify --url=ghcr.io/you2 mine     # it moves, with who signs its images
zigsaw remote-delete mine
```

An app named by id alone comes from the first remote, and so does what
`build-export` and `build-update-repo` publish; any other is named before the
app: `zigsaw install mine org.example.App`, `zigsaw remote-info mine
org.example.App`, `zigsaw build-export org.example.App mine`. `search` looks
in every remote's catalog. A remote's name is letters, digits, `-` and `_`,
never an app's id or an image's name.

What a remote has besides its place: whose signatures count for its images
(see [Signatures](#signatures)), and the login for its registry (see
[Logging in](#logging-in)). `remote-delete` takes the signers with it, and
refuses a remote apps were installed from, as their updates are checked for
its signatures, unless given `--force`. Logins are Windows', for the user,
and every store uses them: one stays when its remote goes.

`ZIGSAW_REGISTRY` moves the first remote for as long as it's set, for CI and
scripts (`ZIGSAW_REGISTRY=localhost:5000/test`); nothing saves it. A store
keeps its remotes in `remotes.json`. The places a zigsaw before 0.105 was told
to check signatures for with `trust add` become remotes of their own, named
after their last part, the first time a newer zigsaw reads the store.

The manifest travels byte for byte, so an image has the same digest in every
store and registry. `install` downloads only blobs the store doesn't have, checks
each one against its digest, and refuses images that aren't zigsaw apps
(such as Docker container images). An image's layers, its runtimes' among
them, download several at a time.

Before it downloads an app's layers, `install` says what the app is, what it
brings and what it may reach, as `remote-info` does, and asks:

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
(`echo y | zigsaw install ...`), and nothing there means no: scripts and CI add
`-y` (`--yes`), which agrees without asking. An install over an installed version of the
app, and `zigsaw update`, ask only when the new version may reach more: the
network where it couldn't, a location it couldn't use, or could only read, or
a registry key it didn't keep; and then say only what's new. `build` doesn't
ask: the recipe is yours, and so are the images it pins.

A reference may name a multi-platform index, as tools built for several
platforms publish: then `install`, `update` and `remote-info` take the index's image
for Windows on x64 (`windows/amd64`), and the app records that image's
digest. An index without one is refused, with the platforms it has. A
recipe pins the image, not the index.

`build-export` uploads only blobs the repository doesn't have. A blob the registry
already holds in another repository is mounted from there, which uploads
nothing:

- an app's runtime layers, from the runtime's own repository next to the
  app's, where `zigsaw build-export <runtime id>` puts it: pushing
  `io.prettier.prettier` by app id mounts Node's layer from
  `org.nodejs.node`;
- all of an app installed from another repository on the same registry, from
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

## Installing lazily

`zigsaw install --lazy` installs an app before its large layers are downloaded,
so that it starts sooner. Each of their files is fetched the first time
something reads it, while the rest downloads in the background:

```powershell
zigsaw install --lazy org.tug.texlive         # 236 MB of TeX Live; a document reads some 18
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

What a list doesn't name, zigsaw writes down itself (0.96 on). While a layer
is lazy, its helper notes each file that something reads of it, and the next
version of that image you pull or update lazily has those files asked for at
once, before any run does:

```powershell
zigsaw update --lazy org.tug.texlive
#   layer sha256:98d15a334bed: 249 files that runs read before come first
```

TeX Live's list is what `pdflatex` reads. Here `lualatex` had been run on the
version before, and after that update it took 6 s instead of 18 to 20, from
ghcr.io with nothing in the store to copy from; the update took as long
either way. Where the version before was complete, so that most of the new
layer was copied from it, it took 6 s instead of 11 (one pair of runs).
[findings.md](docs/findings.md#lists-that-write-themselves-iteration-96)
has the table.

The list is this machine's, one for each image, an app's or a runtime's:
`learned\<id>.txt` in the store, paths and nothing else. A file that nothing
has read during the last three versions pulled lazily drops off it. `zigsaw
rm` leaves it for the app's next pull, `zigsaw uninstall --unused` deletes the lists of
images that nothing installed uses, and deleting the file forgets it. It does
nothing for an image's first pull, and sees only reads made before the
download finished.

The layer's deployment starts as Windows' Cloud Files placeholders, as
OneDrive's files are: listed, with their sizes, and empty. A helper process,
which is zigsaw itself, gives Windows a file's bytes when a program first
opens it. It reads them from the registry, a file's chunks in parallel
requests, keeps what it fetched for the download, and checks
each chunk against the layer's TOC, which it checks against the image's
manifest, whose signature `install` checked. So nothing unchecked reaches an
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
  again if it's gone, after a reboot say, and `zigsaw uninstall` stops it. Its log is
  in the store's `lazy` folder. Started where everything a program starts ends
  with it, as in some terminals, the helper ends then too, and says so first;
  the app's next run starts it again.
- **A file is fetched whole** when a program opens it, and its first read
  costs a little more than in a plain deployment (some 7 ms here: Defender
  looking at it).
- **Placeholders need NTFS.** On a Dev Drive (ReFS), a network share or FAT,
  `--lazy` downloads the layer whole, and says so.
- **`build-export` waits for the download**: it refuses an app still downloading.

- **The layer unpacks once no run is using it**, so that the unpack doesn't
  slow the run down; an app left open stays on placeholders until it's closed.
- **The first run after the download is cold again**: the unpacked files are
  new to Windows, so that run pays what any first run on a fresh deployment
  does (TeX Live's `pdflatex`: 15 s once, then 0.3 s).

How it works, and why it's a bridge and not a way of keeping apps, is in
[how-it-works.md](docs/how-it-works.md#lazy-pulls).

## Sources next to images

Downloads go away: a project moves its files, or its server refuses
everyone. A recipe pins each file by its sha256, which is also the digest an
OCI registry stores a blob under, so a registry can keep them:

```powershell
zigsaw build-export --sources net.frippery.busybox
```

- **`build-export --sources`** also pushes the files the app was built from (its
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

## Signatures

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
> zigsaw install org.nodejs.node
ghcr.io/zigsaw-io/org.nodejs.node: signed, by https://github.com/zigsaw-io/zigsaw/.github/workflows/reproduce.yml@refs/heads/main
```

The check is offline: the certificate must chain to Sigstore's Fulcio, and the signature
be in Sigstore's Rekor log, at a time the certificate was good. In Rekor v1 the log
promises that time; in Rekor v2 (from zigsaw 0.83.0) Sigstore's timestamp authority
vouches for it. Either way, the log's signed checkpoint and the entry's proof against it
must show the log holds the signature. The keys of all three are built into zigsaw.
Images signed before 0.81.0, with a key of zigsaw's, still count.

**What happens to an image from `ghcr.io/zigsaw-io`, on `install` and `update`**, before
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

`zigsaw remote-info` has a line saying which of these an image is. What a recipe pins by digest
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
zigsaw build-sign --print-payload org.nodejs.node > payload.json   # or the payload layer beside it
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

**For your own images**, tell zigsaw whose signature counts for their remote, once per
store: a workflow of yours that signs keyless, or a key, as Flatpak takes a remote's GPG
key.

```powershell
zigsaw remote-add --keyless=https://github.com/me/app/.github/workflows/release.yml@refs/heads/main me ghcr.io/me
zigsaw remote-modify --sign-key=cosign.pub me   # images under ghcr.io/me, by whole path components
zigsaw remotes                                  # who counts where, built-in ones too
zigsaw remote-modify --no-sign-key me           # and away again, or --no-sign-key=<fingerprint or identity>
```

`--issuer=<url>` names another identity provider than GitHub Actions'. Keys are ECDSA
P-256 only, which is what `cosign generate-key-pair` makes. `remote-add` adds nothing
unless it can add all it's given. An image under nobody says it wasn't checked, and
installs. To sign keyless, have `cosign sign-blob --bundle` sign what
`zigsaw build-sign --print-payload <image>` prints, and `zigsaw build-sign --bundle` puts the
bundle beside the image with your registry login, once it's checked it as an install would.
With a key, `cosign sign-blob` and `zigsaw build-sign`, in cosign's classic layout
(a tag named `sha256-<digest>.sig`). [`scripts/sign-images.sh`](scripts/sign-images.sh)
is what CI runs for the published recipes. No digest changes: a signature is beside its
image, not in it.

What this doesn't do is in [the gaps](docs/gaps.md).

## Logging in

Installing public images works without setup. Publishing, and installing
private images, needs a login, which a remote is given:

```powershell
zigsaw remote-modify --login zigsaw                           # asks for a user name and password
$env:TOKEN | zigsaw remote-modify --login --username=you --password-stdin mine
zigsaw remote-add --login work registry.example.com/apps      # a remote with a login, at once
zigsaw remote-modify --logout mine
```

`--login` checks the credentials with the remote's registry, then saves them
in Windows Credential Manager as `zigsaw:<registry>`, for your Windows user
only: every remote on that registry, in every store, uses it, and `zigsaw
remotes` shows it under each. Logins saved by `zigsaw login` before 0.105 are
the same, and go on working. A login is only ever sent to its own registry.
For ghcr.io, the user name is your GitHub user name, and the password a token
with the `write:packages` scope (or `read:packages`, to install private
images).

For CI and scripts, `ZIGSAW_REGISTRY_USERNAME` and `ZIGSAW_REGISTRY_PASSWORD`
work without a login, but only for one registry: ghcr.io, or the host in
`ZIGSAW_REGISTRY`. There they take the place of a saved login. `-v` shows
which credentials a command uses. zigsaw doesn't send credentials to a token
service over plain HTTP, unless the registry is on `localhost`.

Without either, zigsaw uses the login `docker login` saved for the registry,
as Docker would: from the credential helper Docker's `config.json` names
for it (`credHelpers`) or for every registry (`credsStore`), such as Docker
Desktop's `docker-credential-desktop.exe` on PATH, or else from the file
itself (`auths`). The file is `%DOCKER_CONFIG%\config.json`, or
`%USERPROFILE%\.docker\config.json`. A Docker login the registry refuses
doesn't stop an install of a public image: zigsaw goes on without it, and says so.
Identity tokens, which Docker gets from some registries' web logins, aren't
used.
