# Known gaps

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
- What an app's runs are granted on host paths stays while its
  permissions and saved overrides give it
  ([how long grants last](how-it-works.md#how-long-grants-last)): every working
  directory its runs had stays granted while it keeps `cwd`, as granting a
  big one again on each run would take a while. Under `low`, the default,
  such labels pile up: each directory you ran an app with `cwd` in, and your
  folders that installed apps may write, stay labelled low, and any
  low-integrity program, not only the app, may write there meanwhile. A
  sandbox given only on the command line grants the app's folders afresh
  on each run and takes them back after, which takes a while for a big
  folder. `--nofilesystem` on a
  run's command line doesn't take back a grant that stands for that run:
  an AppContainer run can still reach the path by its name. A run that
  didn't end (zigsaw was killed, or its console closed) leaves its grants
  until the app's next run ends, `zigsaw repair` or `zigsaw rm`.
- Stores know each other's labels only from zigsaw 0.70 on, and only once a
  store's app has changed its grants since, or `zigsaw repair` ran there: until
  then, taking a label back in one can take it from an app of the other. Each
  store has its own lock on the changes it makes, so two stores deciding about one
  label at the very same moment could disagree. What a deleted store left waits
  for a `zigsaw repair`, which `zigsaw list` says when it sees it. An app's
  AppContainer profile left by a deleted store stays in your profile, harmless.
  A deleted store's programs that lost their low label keep their medium one.
- `zigsaw grants` looks for unexplained labels only on your six folders and your
  profile, not on the rest of your drives, and only for one of a path's own:
  something inside `Documents`, labelled by itself, isn't listed.
- An installed app's files can't be deleted by hand, by anyone, as they're
  read-only (`rm -rf` and Explorer are refused): a store with apps needs `zigsaw
  rm` first. To delete one regardless, `icacls <store> /reset /T` first, then
  `zigsaw repair` from another.
- At low integrity, an app with `cwd` run from your user profile, a folder
  that holds it, or a drive's root gets its working directory read-only for
  that run, with a warning, as labelling it would let every low-integrity
  program write anywhere in it: a command that writes there fails (`npm
  init` in your home folder). Run it from a folder inside, or with
  `--sandbox=soft`. The same goes for zigsaw's store, the folder
  `zigsaw.exe` is in, a folder that holds either (the zigsaw repository,
  with `zig-out\bin\zigsaw.exe`), and a folder inside them, under
  `--sandbox=appcontainer` too.
- Windows starts a program whose file is labelled low at low integrity,
  whoever starts it. zigsaw takes the low label off the programs a run
  writes (`.exe`, `.com`, `.scr`) where it may write, but only once the
  app's runs have all ended: one started meanwhile starts at low. It misses
  programs by other names, those written while zigsaw wasn't watching (a
  run that didn't end, a program left running after its run, any program
  but the app's writing into a folder labelled for it), and the low-labelled
  libraries, scripts and documents anything writes there. When changes come
  faster than the watch takes them, zigsaw looks through the folder for
  programs written during the run, up to 50,000 entries. Toolchains' images
  (zig, Rust, Go, CMake, make, Meson, Node, Python, the JDK, Maven, Gradle,
  and the GTK, Qt and PHP SDKs) still ask for soft, so that their builds
  label nothing.
- A program zigsaw took the label off has a medium label of its own, which
  a low-integrity process can't write: the app's own low runs label it low
  again while they go, but another app's can only replace it (delete and
  write it again, or rename over it), not write into it, as 7-Zip
  overwriting it would. After `zigsaw rm` the app's own can't either.
- A zigsaw running at low integrity, as a shim a low run starts does, takes
  back nothing when the app's runs end; the next zigsaw that isn't does. If
  zigsaw's own program is labelled low, as a low run from a folder holding
  it could make it before 0.56, it runs at low itself: taking a label back
  then leaves a low label of its own on everything below the path, so
  `zigsaw repair` refuses: run it from a `zigsaw.exe` elsewhere.
- `--sandbox=low` labels only paths whose permissions you may change, which
  you may for what you own. Labelling needs the right to change a path's
  owner, which a second drive whose root gives users only Modify (a fresh
  `D:`) withholds; zigsaw then grants it to you for the change, and puts the
  permissions back as they were. A writable grant of a path you neither own
  nor may change the permissions of fails.
- `--sandbox=low` confines writing only: the app can read whatever you can,
  and use the network whatever its permissions say. At low integrity,
  writing to the registry fails outside `HKCU\Software\AppDataLow`, and the
  few directories Windows labels low itself, such as `AppData\LocalLow`, can
  be written. System32's `ping` fails at low integrity (`transmit failed.
  General failure.`): Windows' ICMP refuses it.
- An app's services are on the loopback only: serving other machines takes
  a firewall rule, which takes an administrator. Under `soft` and `low`,
  nothing keeps an app from listening wherever it likes. Under
  `--sandbox=appcontainer`, a service is published only while a run of the
  command that serves it lasts, and an app given a port of its own (`-p`,
  `--listen`) bypasses its service.
- Under `--sandbox=appcontainer`, an app's internal port is picked once and
  kept until `zigsaw rm`: a program that takes it later keeps the app from
  listening there, which the app reports in its own way.
- A zigsaw older than 0.50 ignores an image's services and leaves
  `${listen:...}` and `${port:...}` as they are: PostgreSQL's and Kanboard's
  images from then on need 0.50. One older than 0.51 leaves `${uses:...}`
  as it is: osm2pgsql's and Xdebug's images from then on need 0.51 (libpq
  refuses that `PGPORT`, and Xdebug connects to no port).
- Under `--sandbox=appcontainer`, an app's container is exempt from
  loopback isolation while a run of it with the network goes, and an
  exempt container reaches this machine's programs whatever its
  capabilities: a run of the same app without the network, at the same
  time, reaches them too.
- The loopback exemption is a setting of Windows for the whole machine, which
  a standard user's account may change, as may an administrator's and GitHub's
  runners (tested on Windows 11 26300 in iteration 70; a domain's policy could
  say otherwise). Where Windows refuses, the run says so, and the app reaches
  only the ports it uses. Two users' zigsaws changing the list at the same
  moment could undo each other's change, as the lock zigsaw takes for it is
  per session.
- Tests run as a standard user start from another account's logon, with that
  user's profile loaded: nobody has signed in to that account and used its
  desktop, Explorer, the Start menu or Settings with zigsaw's apps. Two people
  using one machine's zigsaw hasn't been tried, nor has an account a domain's
  policies restrict.
- A store on a drive whose root gives users only Modify, as a fresh second
  drive's does, can't run a low app that may write a folder the user neither owns
  nor may change the permissions of: the run stops, and says so. `icacls
  /setintegritylevel` is refused on such a drive, even for an administrator's
  unelevated account and folders it made, though zigsaw manages for those.
- An MSVC build in an account nobody has signed in to can leave its build folder
  behind, with a warning: Windows' WebCache process starts during the build, under
  the build's profile, and stays. `zigsaw prune` deletes the folder once that's
  gone. Where someone's signed in, the process is running already, under their
  real profile.
- Apps trust the roots in Windows' certificate stores
  ([certificate trust](networking.md#certificate-trust)), but BusyBox's
  `wget` doesn't check certificates at all.
- PHP's curl, Composer, Perl and libpq read Windows' roots from the file
  zigsaw writes of them when the run starts (`${roots}`): a root added to
  Windows during a run reaches their later runs only. Once Windows' roots
  change, `zigsaw prune` deletes the file a running app's run was given,
  unless it's open just then: an app that reads it again later, as PHP's
  curl does for each request, then fails until it's started again. A
  zigsaw older than
  0.53 leaves `${roots}` as it is: PHP's curl then refuses every
  connection (`error adding trust anchors from file: ${roots}`), Composer
  and Perl fall
  back to their own bundles, and libpq's `sslrootcert=system` finds no
  roots. PHP's, Composer's, Kanboard's, Perl's, PostgreSQL's and
  osm2pgsql's images from then on need 0.53 for that.
- curl over Schannel, CMake's and cargo's, checks revocation strictly: a
  certificate that names no CRL or OCSP responder is refused, saying `the
  revocation status is unknown` (CMake: `SSL connect error`), as a network
  whose CA doesn't publish one would make it. MinGit's git, on the same
  Schannel, lets it pass.
- `zig fetch` doesn't work at low integrity, so neither does `zig build`
  for a project whose dependencies aren't fetched yet: zig's std can't open
  Windows' roots there, as it asks to write them
  (`CertificateBundleLoadFailure`), and the compiler has its std built in.
  zig's image asks for soft, so only `--sandbox=low` meets this. In an
  AppContainer, it needs `--share=network`, which zig's image doesn't have.
- zig 0.17 runs `zig init`, `zig fetch` and `zig build` in Maker, a
  program it builds into its cache when first asked (a minute). On Windows
  Server 2025, in an AppContainer, building it needs zig's own path, which
  zig can't find there (as for `zig env`), so all three fail there; on
  Windows 11 26300 they work.
- Java's images trust the machine's roots in Windows' store. That leaves
  out a root added for this user only, and a root Windows hasn't fetched
  yet, which Temurin's `cacerts` (no longer used) may have had. Windows
  fetches a missing root when its own programs check a chain, not when
  Java or Python reads the store, as both do, and as zigsaw does for
  `${roots}` (which then lacks it too, where curl.se's bundle and
  Mozilla::CA's, no longer used, may have had it). On 2026-10-28, Java and
  Python here failed on example.com, whose root (SSL.com TLS ECC Root CA
  2022) Windows hadn't fetched, until a Windows program checks its chain
  (Edge, or Windows' `curl.exe`). With `cacerts`, Java reached it. Node
  adds Windows' roots to its own, so it does.
- MinGit's image no longer reads Git for Windows' system config
  (`C:\Program Files\Git\etc\gitconfig`), which its own config included.
  What that config sets for this machine's git, such as `http.sslBackend`,
  `http.proxy` or a credential helper, doesn't reach zigsaw's.
- An app in a container that isn't exempt reaches only the ports it
  declares, on `localhost`: one given another port or host of its own
  bypasses the forward, and isn't reached. zigsaw makes each forwarded
  connection itself, one at a time, waiting up to 2 s for each.
- A host path an earlier zigsaw granted an app's AppContainer, to the
  container's own SID, keeps other apps' low runs out until that app's last
  run ends, `zigsaw repair` or `zigsaw rm`, which take that SID's access
  away from every path the app's runs were granted. In the store, runs
  clear such grants from what they use.
- Apps that locate folders with `SHGetKnownFolderPath` instead of environment
  variables would bypass the data-directory redirect. None of the tested tools
  do.
- Installing an app with many files is limited by Defender scanning each new
  file: about 16 s for zig's 19.5k files, 3 s for Node.
- The registry is kept apart only for the keys an app's image declares
  (`registry`, as 7-Zip's does). At low integrity, the default, and in an
  AppContainer, an app's writes to other keys in `HKEY_CURRENT_USER` fail,
  and apps carry on without them (Flameshot's "Launch at startup", Java's
  preferences of an app whose image declares no key). Under `soft`, such an
  app writes the real registry, and leaves the keys behind after `zigsaw
  rm`. No override or run option adds a key to an app's.
- The keys an app keeps are in the real HKCU while it runs. A copy of the app
  installed the usual way, running at the same time, sees the zigsaw app's
  settings instead of its own (which are aside), and what it saves meanwhile
  goes to the zigsaw app's. Two apps that keep the same key, or two stores'
  copies of one, can't run at the same time.
- In an AppContainer, an app that makes two missing levels of keys at once in
  one of its keys, with a path from `HKEY_CURRENT_USER`, is refused (from a
  handle to its key, it works): only the key itself is granted.
- zigsaw 0.18.0 ignores the keys an image declares: it runs the republished
  7-Zip as before, with its settings in the real registry under `soft`.
- `zigsaw search` reads the default registry's catalog only; there are no
  other "remotes". The catalog lists the apps `scripts/publish.sh` publishes,
  as they were when it was made: an app pushed later without
  `push --catalog` isn't in it, or is at its older version. It has no icons
  or screenshots. Nine runtimes and SDKs have no name or summary in it yet,
  only their commands: busybox, zig, Rust, CMake, Meson, cargo-c, gettext
  and GTK's SDK and runtime. Naming any of them changes its digest, and the
  GTK SDK pins them all, so they get one at their next version (Node and Go
  got theirs in iteration 22, Perl in 53).
- An app sees only the user's folders its permissions name (Desktop,
  Documents, Downloads, Music, Pictures, Videos), linked into its profile;
  others don't exist there, and an app that asks for one to save in gets
  an error or nothing. `AppData\LocalLow` and the profile folder are your
  real ones, in every sandbox. Saved Games, Contacts, Favorites, Links and
  Searches, and the Public folders, can't be granted by name.
- A folder is granted whole: there's no `documents/Notes` for one folder in
  it. Under `low`, the default, a writable folder stays labelled low
  integrity while the app may write the folder, so any low-integrity
  program can write in all of your Documents meanwhile.
  Granting a folder changes the ACL of every file in it, which takes a
  while for a big one, and so does taking it back.
- A folder whose location Windows keeps as a path with a variable other
  than `USERPROFILE` in it, which a run's environment doesn't have, isn't
  linked: the app looks for it at that path, unexpanded, and zigsaw says so.
  Folders under `%USERPROFILE%` and at absolute paths (OneDrive's) work.
  Junctions only point to local drives: a folder on a network share isn't
  linked either.
- An app whose image names a folder in its permissions needs zigsaw 0.18.0
  or later; 0.17.0 refuses the image. Later names are left out of a run, with
  a warning.
- In an AppContainer, 7-Zip's file manager opens an archive given with
  `--file` at its root view instead: it goes through the archive's path from
  the drive root, whose folders the container can't read.
- At low integrity and in an AppContainer, an app can't add buttons or a
  progress bar to its taskbar button (Explorer refuses it), as VLC tries to.
- Now and then, VLC starts playing a file about 30 s after its window comes
  up, rather than at once. Seen twice in a day, on its first runs in a while;
  not found why.
- A first install trusts GitHub: `install.ps1` checks the zip against the
  release's `SHA256SUMS`, and both come from where the script does, so a signature it
  checked would prove nothing. `zigsaw upgrade` does check one, from then on. By hand,
  [`cosign verify-blob`](../README.md#signatures) checks a release, and anyone can compare
  the programs with a build of the tag ([Installing zigsaw](../README.md#installing-zigsaw)).
  Releases are for x64 only.
- **A missing image signature only warns, for now.** Someone who can change what
  ghcr.io serves can simply leave the signature off: wrong ones are refused, and a
  warning is all that stops this, which `--yes` doesn't stop for. Refusing is the
  direction, with no date set: only each image's current version is signed, so a plain
  refusal would also stop `pull app:<older version>`, and a new image is unsigned until
  Reproduce has rebuilt it, after the push. `zigsaw upgrade` already refuses.
- An image built with a host toolchain (MSVC) isn't compared by Reproduce, so CI never
  signs it: it keeps the key signature it had, and a new version of it would be
  unsigned.
- **Signatures don't stop an old image.** A tag moved back to an older version that was
  signed installs, older and vulnerable, as a signature says who made an image and not
  that it's the newest. No freshness (TUF or the like) is checked. Nor does anything
  notice a tag that stops moving, so that a fix never shows up.
- **Whoever can change `main`, or the workflows, can sign.** Signing is keyless, by CI
  (iteration 81), so a signature is only as good as GitHub's account security and the
  repository's branch protection, and the workflow's pinned actions. It says CI rebuilt
  the image to the same digest, not that a person looked at anything. Every signature is
  in Sigstore's public log, so one that shouldn't be there can at least be found.
- **Sigstore's keys are built in, with no TUF.** zigsaw has a fixed copy of Sigstore's
  trusted root (`src/sigstore-root.json`). Should Fulcio's authority, Rekor's keys
  (either log's) or the timestamp authority's certificates change, a zigsaw that doesn't
  know the new ones refuses what's signed with them: images as wrongly signed, releases
  as not signed. Rekor v2 rotates its log every so often (log2025-1 is the first), so
  this will come. Then a release signed by hand with the offline backup key is how such
  a zigsaw is reached (`scripts/sign-release.sh`), and `scripts/sigstore-root.sh`
  refreshes the copy.
- **Zigsaws before 0.83.0 don't take Rekor v2.** CI signs with cosign's default, which
  on 2026-11-10 is still Rekor v1 (Sigstore's signing config lists only
  rekor.sigstore.dev). If Sigstore moves that default to v2, v0.81.0 refuses every
  image and release signed from then on (v0.80.0 and older only warn, for images, as
  they don't read keyless signatures at all), and `zigsaw upgrade` from it can't go on:
  a release signed by hand with the backup key reaches it. Pinning CI to v1 was the
  other way; it was left as it is (iteration 83).
- **A key that leaks can't be revoked.** Old zigsaws trust their built-in keys for good:
  the one that signed until v0.81.0, for images and, before 0.81, releases, and the
  backup, for releases. There's no list to check, and no one is told.
- The backup key sits offline, encrypted with a passphrase, with no hardware token, as
  cosign's PIV support needs cgo, which its image doesn't have. Whoever gets it and the
  passphrase can sign a release.
- The catalog `zigsaw search` reads isn't signed, so it can list what it likes. What
  gets installed is checked, by name.
- `update --check` and the daily check don't look at signatures, so a tag moved to
  something wrongly signed is listed as an update, and refused when it's installed.
- zigsaw has no Authenticode signature: SmartScreen and Defender know nothing of the
  signatures here.
- An image pulled with no key for its registry isn't checked, and says so, on every
  registry but `ghcr.io/zigsaw-io` until `zigsaw trust add` names one. Keys are ECDSA
  P-256 only, and a signature in cosign's newer bundle format, which is its default, isn't
  read: sign with `--new-bundle-format=false`, or as `zigsaw signature` does.
- Docker's logins are used only as user names and passwords (or tokens
  used as passwords): an identity token, which Docker keeps for a registry
  after a web login, isn't, as using one takes OAuth2's refresh flow.
  Credential helpers are run only as `.exe` files on PATH, not batch files.
- From a multi-platform index, zigsaw takes the first image for
  `windows/amd64`, whatever its Windows version (`os.version`); an index
  whose entry for it is another index is refused. zigsaw doesn't push
  indexes: it builds for x64 only.
- Runtimes can't have runtimes of their own (SDKs and image sources can).
- Under `--sandbox=appcontainer`, BusyBox's sh doesn't wait for the last
  command of `sh -c`, which then ends with the run, having printed nothing,
  and the run's exit code is 0: in an AppContainer, sh doesn't see its
  parent, zigsaw, and takes itself for an orphan. A command after it
  (`sh -c "cc x.c; true"`) avoids that. Low-integrity runs had the same
  problem until zigsaw let them read its process.
- An app's alias shims are by app, not by version: an update while the app
  runs switches its later alias calls to the new version's tools. A Meson
  build directory set up with the GTK SDK's `meson` names the SDK's
  deployment, so after an update it needs `meson setup --wipe`.
- `$(pkg-config ...)` in a shell splits the paths it prints at spaces: a
  store whose path has a space (a user name with one) breaks
  `cc ... $(pkg-config --libs gtk4)`.
- Pushing mounts a runtime's layer only from the runtime's repository in the
  default layout, and an app's blobs only from where it was pulled. A blob
  the registry holds elsewhere is uploaded again.
- Of a blob that breaks off while going up in chunks, zot keeps nothing:
  the blob goes again from the start. Going on from where the registry got
  to has been seen only after a chunk zot refused (HTTP 416). ghcr.io, the
  default registry, failed the chunks of an 87 MB blob and couldn't say how
  much it had (iteration 42): zigsaw then sends the blob in one request,
  and the push's later blobs too, so a push there of a blob over 64 MiB
  sends up to a chunk more than the blob. Blobs up to 64 MiB go in one
  request, as do all of them with `ZIGSAW_UPLOAD_CHUNK_SIZE=0`; a registry
  that limits a request's size and also takes chunks badly can't take a
  bigger blob.
- A layer's compressed bytes, and so every image's digest, are what the
  deflate of the Zig that zigsaw is built with makes. A Zig whose deflate
  changed would make other digests from the same files; CI pins Zig 0.17.0,
  whose deflate makes 0.16.0's bytes, and a unit test pins them.
- Build steps are kept off the network by convention (proxy variables), not
  enforced: a tool that ignores them can still download.
- Builds need `B:` free, and run one at a time.
- The `make` builds have, BusyBox's, runs one command at a time: its `-j`
  isn't implemented. OpenSSL's and gettext's recipes compile ahead of it in
  parallel; Gnumeric's and goffice's builds, and hunspell's and enchant's in
  GTK's SDK, still compile one file at a time. Under BusyBox, configure finds
  no `install` either, and installs each file with a shell script, unless a
  recipe gives it one (gettext's does).
- Builds with MSVC depend on the machine's Visual Studio, so they don't
  reproduce elsewhere, and CI doesn't check them. Only x64 MSVC builds are
  set up.
- Vendor steps run their commands with network access and nothing more
  confining than a build's sandbox; only what they leave in their directory
  is pinned.
- Rust builds need zig in their SDK, for an assembler and C. Only the
  `x86_64-pc-windows-gnu` target is set up. Crates' C code is compiled with
  fixed flags rather than the profile's, against zig's UCRT headers but
  linked with Rust's `msvcrt.dll` libraries; C code that needs what only UCRT
  has would fail to link.
- Rust builds need the store's path to be shorter than about 100
  characters: rustc starts its linker from the Rust image's deployment, and
  can't start a program whose path is longer than Windows' 260 characters.
  The default store, `%LOCALAPPDATA%\zigsaw`, is well within that.
- cgo works only in builds that list zig in their SDK. `go build` run as
  Go's app has no C compiler: Go's image doesn't have zig as a runtime, as
  GTK's SDK has. Until zig's `cc -###` succeeds, recipes that use
  cgo have to leave out Go's build ID (`-ldflags=-buildid=`), and their
  executables are stripped.
- CMake run as an app has no compiler either, for the same reason; it's
  for builds, and for `cmake -E` and scripts. When a command it runs can't
  be started while other commands are running, Ninja 1.13.2 stops with
  `ninja: fatal: ReadFile: The handle is invalid.` (once, it crashed with
  `0xC0000409`) instead of reporting the command.
- Only recipes on CMake's image from iteration 40 on (`fa7efc2e`, now Qt's
  SDK and the apps built with it) build without looking in Program Files,
  CMake's package registries and the registry's Pythons. The others keep
  the image they were published with (`fdc6a6bb`): zstd, PHP's yaml and
  zstd extensions, Gaphor (its Graphviz), GTK's SDK and its base half,
  GNOME Text Editor and Gnumeric. They reproduced on runners, which have
  plenty installed there, so nothing they build found anything, but a
  machine with a library they look for could build them differently. Find
  modules that read the registry for their own tools can still see the
  machine.
- CMake takes the version of the Windows it runs on as the system's, and a
  project may write it into what it installs, as Qt does in its
  `modules/*.json`: such a build differs from one Windows version to
  another. Qt's SDK halves pass the version they were published with
  (`-DCMAKE_SYSTEM_VERSION=10.0.26300`); other recipes would need the same
  if what they install records it.
- Executables built with zig's `LDFLAGS` or `CGO_LDFLAGS` have no debug
  information, as a PDB would differ from build to build.
- .NET's images can't be published: Microsoft's licence for its Windows
  binaries doesn't allow it. Each machine builds the SDK and the runtime
  from Microsoft's download, in that order, before an app that names them
  (`recipes/no-publish/`); they're in no registry to pull from, and neither
  is an app built with them, such as Pinta.
- .NET builds can't use NativeAOT, which links with Visual Studio's linker
  and C runtime libraries. Only .NET 10 is set up; a project for an older
  .NET is rebuilt for it, which takes a `TargetFramework` its project lets
  the environment set, or a change to the project.
- The .NET runtime is one image with all three shared frameworks: a console
  app's runs have WPF's and ASP.NET Core's files on disk too (200 MB in all).
- In an AppContainer, `dotnet --info` and `dotnet workload list` stop at the
  workloads, with an exception: they ask Visual Studio's installer for its
  workloads, which the container can't reach. Building and running work.
- Pinta has no WebP: GTK's runtime has no WebP loader for GdkPixbuf, which
  Pinta's own Windows build brings. Its own strings follow Windows' display
  language only: `LANGUAGE` changes GTK's and libadwaita's, not Pinta's.
- Files works in the `soft` sandbox only, which its image asks for. At low
  integrity and in an AppContainer, Windows' storage APIs refuse a program
  without a package:
  Files starts and lists folders, but shows no drives, and a dialog asks for
  a permission only a package can have.
- Files runs without the package it's made for, so what its package gives
  it isn't there: starting with Windows, the `files-dev:` protocol and its
  `files-dev` alias (zigsaw's `files` command instead), the update task, and
  its out-of-process server (unused as it stands). Its C++ parts aren't
  built, as they need Visual Studio: the launcher that makes Files open
  folders in Explorer's place, and its open and save dialogs. Changing its
  language wasn't tried. It's the Dev flavour, without NativeAOT.
- Files' vendor step keeps 3.3 GB of NuGet packages, for x64 alone, among
  them the Windows App SDK's AI and ML packages, which its project excludes
  from the build but NuGet still downloads.
- TeX Live doesn't run in an AppContainer where Windows doesn't let one list
  the drive root (Windows 11 26300 here; `self-long-name` in
  `tests/acprobe.zig`): kpathsea asks for its own long path
  (`GetLongPathNameW`), which lists each directory from the root, and every
  program stops with `Can't get long name for D:\zs.`. Its programs are
  TeX Live's own builds. The soft and low sandboxes work.
- TeX Live's engines make their formats on first use, in the app's data
  directory (a few seconds each, once), since formats dumped in the build
  differ between builds; an `--ephemeral` run makes them every time.
- A published TeX Live can't be updated with `tlmgr`, only rebuilt with new
  pins (`scripts/texlive-pins.sh`).
- Microsoft Defender quarantined a development build of zigsaw 0.19.0 as
  `Trojan:Win32/Bearfoos.A!ml`, which ends a build or run in progress
  ([findings](findings.md#other-findings)), and flagged a build of what became
  0.70.0 by its exact bytes ([findings](findings.md#defender-and-exact-bytes)).
  Released programs have scanned clean, and from 0.22.0 they carry version
  information and a manifest, but zigsaw's programs aren't signed, and any
  change to their bytes could be flagged. A release is scanned before it's
  published, where its runner's Defender can scan: a verdict that comes later, on
  a released file, wouldn't be seen. Where one is, Windows says the file "contains
  a virus or potentially unwanted software", and it doesn't start, or copy.
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
  llvm-mingw's lld doesn't export them.
- A GUI app whose executable is built as a console program, as
  libadwaita's demo is upstream, gets a console shim, and a console window
  from the Start menu; its recipe has to build it as a GUI program
  (libadwaita's sets Meson's `win_subsystem`).
- A shortcut or a kind of file shows the icon of an `.ico`, or of an
  executable that has one: a recipe whose app has only an SVG has to make
  the `.ico`, as GTK's and Text Editor's do with the SDK's `rsvg-convert`.
- zigsaw names each app's taskbar button in its shortcuts (`Zigsaw.<app id>`),
  but can't set it on a program from outside: only apps on Electron's runtime
  carry it themselves. Another app started from its shortcut counts as started
  from it, and one started otherwise (a file, a console) doesn't, so its window
  may get a button of its own beside a pinned shortcut. Whether pinning a
  window pins the shortcut, and not the app's executable in the store, hasn't
  been checked: it takes pinning one by hand. An app that names its own button,
  as VSCodium does, keeps it, and a pin of its window may then run its program
  in the store without zigsaw (not checked either).
- zigsaw offers an app for a kind of file or link, and can't make it the default:
  Windows keeps that choice to the user. Only extensions and URL schemes are
  registered: no MIME types, no "New" menu entries, and no command other than
  opening.
- `--file` gives an app the file and nothing next to it. An app that
  writes a backup or a temporary file beside the document, or reads files
  the document names, needs `--filesystem` for the directory, or a
  fallback of its own. Its grant lasts until the app's last run ends:
  meanwhile, under `--sandbox=low`, every low-integrity process may write
  the file.
- Selecting several files in Explorer and opening them starts the app once
  for each. Text Editor and Rnote hand a file to the instance that's
  running already.
- GTK built with MSVC ([`recipes/gtk4-msvc.json`](recipes/gtk4-msvc.json))
  is an experiment: no translations, SVG loader, HTTP, spell checking or
  apps, and it isn't published or checked in CI. It doesn't reproduce:
  `tiffxx.lib` keeps the time it was archived
  ([findings](findings.md#gtk4-msvc-doesnt-reproduce-an-archives-member-dates-iteration-82)).
- Text Editor has no help pages (no yelp on Windows). Its spell checking
  has the languages Windows has, through WinSpell, and English (US) from
  hunspell; other hunspell dictionaries aren't in the runtime.
- GTK's SDK's `windres` takes what Rust's crates and libtool pass (`-i`,
  `-o`, `-I`, `-D`, `--target`, COFF output); GNU windres's other options,
  such as `--preprocessor-arg` or `.res` output, reach zig's `rc`, which
  refuses them. Meson uses `rc`, as the SDK's `RC` says.
- Under `--sandbox=appcontainer`, DirectWrite can't open fonts installed
  for the user only, rather than for the machine; GTK warns, and draws
  with the others.
- Pango doesn't fall back to another font for scripts its font lacks:
  Devanagari in Segoe UI shows as boxes, where Windows would use Nirmala UI.
- PHP needs Microsoft's Visual C++ Redistributable installed, which takes
  an administrator: its images don't carry it, as its licence doesn't let
  it be published.
- Xdebug's step debugger connects to the port its image uses, `dbgp`
  (9003, or where `--port=dbgp=<port>` moves it). `XDEBUG_CONFIG` with a
  `client_port` of its own still wins, and in an AppContainer that isn't
  exempt from loopback isolation, that port isn't reached.
- Installed extensions join every run of what they extend: what a run
  loads depends on what's installed, not only on the app's image, as with
  Flatpak's extensions. A run notes, each time, an installed extension that
  doesn't join (built for another version of the point, or missing one it
  needs), but nothing warns at install. Builds never get installed
  extensions. An extension's aliases aren't used, and extensions can't have
  runtimes of their own.
- `php-ext` finds the libraries PHP ships, as headers and import libraries
  for its own DLLs, and those a recipe built into the build's prefix
  before it. Those have been static libraries, linked into the extension:
  an extension that needs a DLL PHP doesn't ship would have to get it
  loaded, and none has been tried. A library's file has to have the name
  `config.w32` looks for, as yaml's needs `libyaml_a.lib`. The deps
  packages' static libraries (`*_a.lib`, MSVC's) aren't in the SDK. It
  hasn't been tried with C++ extensions, nor with thread-safe PHP, which
  isn't packaged. A `config.w32` that calls a configure function its
  stand-ins don't have fails, naming it.
- At low integrity, PHP's `is_writable()` is false even for what the run
  may write (its data, writable grants, `TEMP`): PHP leaves the integrity
  label out of its access check ([findings](findings.md#phps-is_writable-at-low-integrity)).
  PHP code that checks before it writes refuses: Kanboard doesn't start
  under `--sandbox=low`, so its image asks for `soft`. It works under `soft`
  and `--sandbox=appcontainer`.
- Kanboard is served by PHP's built-in web server, which handles one
  request at a time and is meant for development: fine for one person on
  their own machine, not for a team. Its plugin installer is off, as
  upstream's default; plugins go in `plugins` in its data by hand. Its
  router keeps `app\`, `libs\`, `vendor\` and `cli` from the web; PHP's
  server ignores Kanboard's `.htaccess` files.
- PostgreSQL's server lasts as long as the run that started it, as every
  run's processes do: `pg_ctl start` starts one that ends with pg_ctl's run,
  and there's no Windows service (that takes an administrator). Run
  `postgresql` in a console of its own, and `pg_ctl stop` or Ctrl+C there to
  stop it.
- Under `--sandbox=appcontainer`, other programs reach PostgreSQL's server
  through its service, which `postgresql` publishes: a server started with
  `postgres` or `pg_ctl start`, or given `-p`, can only be reached by the
  app's own runs (psql, pg_dump...) in an AppContainer too. In an
  AppContainer, what PostgreSQL runs through cmd.exe can't start the
  store's programs:
  `archive_command`, `restore_command`, `COPY ... PROGRAM` and psql's `\!`
  with them, and initdb's test of `max_connections` and `shared_buffers`
  (`postgresql` sets them; a cluster made with `initdb` itself there gets
  initdb's least).
- PostgreSQL's ICU collations are Windows' `icu.dll`'s (ICU 72.1 on Windows
  11 and Server 2025): a Windows update that changes ICU changes their
  version, and PostgreSQL warns about the indexes on them, as it does on any
  system whose ICU is updated. The default, `C.UTF-8`, is PostgreSQL's own.
- PostgreSQL's extensions join `postgresql`'s runs only: `postgres` or
  `pg_ctl start` run on their own load none. PostGIS has no protobuf output
  (`ST_AsMVT`, `ST_AsGeobuf`), address standardizer or SFCGAL, and none of
  its commands (`shp2pgsql`, `pgsql2shp`, `raster2pgsql`); PROJ has no grids
  beyond those in `proj.db`, and doesn't download any. PostGIS's GDAL is a
  copy of GDAL's own DLL in its image, found through the server's PATH: a
  program the server starts (`COPY ... PROGRAM`) sees it there too.
- GDAL's image has no network drivers (no curl: no `/vsicurl/`, WMS, WFS
  or other web services), none of the drivers that need a library it
  doesn't build (netCDF, HDF, PDF, WebP, JPEG-XL, PostgreSQL, Spatialite and
  the rest), and no Python, so none of GDAL's Python scripts
  (`gdal_calc.py`, `gdal_merge.py`...). Its tools reach files only in the
  directory they run from (its `cwd` permission).
- osm2pgsql, under `--sandbox=appcontainer` in a container that isn't
  exempt from loopback isolation, reaches only the local server on the port
  it uses, `postgresql` (5432, or where `--port=postgresql=<port>` moves
  it): `-P` with another port isn't reached, and libpq waits out its
  connection timeout (42 s here, unless `PGCONNECT_TIMEOUT` is set). It
  can't read PostgreSQL's password file, which is in that app's data: `-W`
  asks for the password (from the console or stdin), or set `PGPASSWORD`
  with `--env`.
- osm2pgsql's image has no `osm2pgsql-replication` (a Python script that
  needs pyosmium and psycopg) and no `osm2pgsql-gen` (it needs potrace and
  OpenCV). Its Lua is linked in statically, so a style can `require` Lua
  modules but not C modules (LPeg, LuaSocket...), which would need a Lua
  DLL.
- Composer's image can't update itself (`self-update`): its `composer.phar`
  is in the read-only image; a newer Composer is a newer image.
  `composer diagnose` reports its keys for verifying updates missing.
- zigsaw 0.24.0 and older refuse Composer's image, whose alias runs a file
  of its PHP runtime, and so Kanboard's builds; running Kanboard needs only
  PHP's runtime.
- MinGW's headers define POSIX names that MSVC's don't, and an extension
  that tests for one takes another branch than in MSVC builds of it.
  `zig-php.h` removes those found so far (`P_tmpdir`, `PATH_MAX`,
  `NAME_MAX`). Code that tests `_MSC_VER` for "Windows" takes the other
  branch with clang: igbinary's recipe patches two such tests.
- ssh2's signal test fails, as it traps `SIGINT` in bash, which Windows has
  neither of; with MSVC's build too. redis's tests run against miniredis,
  as Redis has no Windows build: 46 of them fail there for both builds
  (commands and `INFO` sections miniredis hasn't).
- A project's incremental builds are only as right as its tools'
  incremental state: one that misses a change makes what a `--clean` build
  wouldn't. The module changing in the recipe starts it afresh; a change to
  an SDK's image does only through the recipe's pin. A project moved to
  another directory starts afresh, its kept build being keyed by the
  recipe's path.
- A build that goes on from the recipe's last one (0.88) puts back the
  prefix, and nothing else. What a command wrote into another module's
  `B:\src`, or into `B:\home` or `B:\data`, is still there when a module is
  built again, where a build of every module would start without it.
  `zigsaw build --clean` is the way out; what's published is built with
  `--no-resume`.
- A file in the prefix that a later command wrote into, rather than
  replaced, can't be put back, so every module is built again: Python's
  `shutil.copy` and CMake's `file(INSTALL)` over an existing file do. The
  build says which file it was. GTK's and Qt's SDK chains, stopped in the
  middle and with a late module changed, never did (iteration 89).
- A command that stopped is run again in its directory as it left it. One
  that can't be, a `patch` half applied or a `mkdir` without `-p`, fails
  again; `--clean=<module>` starts the module afresh.
- A kept build is a whole build root for each recipe built. Together they
  get `ZIGSAW_KEPT_BUILDS_SIZE` (10 GB), which a build enforces only when it
  ends, by the sizes recorded then: one recipe's that's larger stays until
  another build ends, and a build that keeps nothing (`--no-resume`, MSVC)
  deletes none. The least recently used go first, not the largest.
- Each `zigsaw build` of a project reads all of its files to hash them,
  even when it then takes the image built before: quick for a source tree,
  slower for one with large assets that aren't ignored or skipped.
- A project's files leave out a file that a `.gitignore` ignores but git
  tracks anyway (added with `git add -f`), which git would commit. A link
  in a project fails its build, which git would commit as a link.
- `push --sources` doesn't push a project's files, as they're local, like
  a recipe's local files.
- A source whose pinned URL fails is fetched from the sources next to the
  image of the recipe's own id. A recipe copied under another id has none,
  so it builds only while the URL answers or the store has the file: copied
  from BusyBox's, whose site refuses everyone, it needs BusyBox's own recipe
  built in that store first.
- A GTK 3 app lists two runtimes, GTK's and GTK 3's, and two SDKs: GTK 3's
  images have only GTK 3 and ATK, and runtimes can't have runtimes of their
  own. GTK 3's runtime is built against one GTK runtime, pinned by its
  app; an app that pinned another one would run GTK 3 on a GLib it wasn't
  built with. GTK 3's demos are an app (`org.gtk.Gtk3demo`), as a runtime
  can't run on its own. GTK 3's SDK exports nothing: building GTK 3
  programs without a recipe takes GTK's SDK's commands, with GTK 3's
  pkg-config files added to `PKG_CONFIG_PATH` by hand.
- GTK 3's SDK is built without GTK's broadway backend and printing to a
  file (the Unix print dialog's): GTK 3 prints with Windows' own dialog.
- An app pins the builds of its runtimes by digest, so a new build of a
  runtime reaches an app only once the app is rebuilt on it and
  republished; until then, a store with that app and one on the new build
  has the runtime twice. `scripts/check-pins.sh` warns about published
  recipes in that state. It reads the registry anonymously, so an image
  that isn't public yet looks missing to it.
- GTK's extension point adds data only, a `share` directory to
  `XDG_DATA_DIRS`: an extension can't add GIO modules, GdkPixbuf loaders or
  enchant providers, which are found next to the runtime's DLLs. Its
  `share` comes after the runtime's, so it can add files but not replace
  the runtime's (an icon theme of the same name). An app on the runtime has
  to name its own `share` in `XDG_DATA_DIRS`, which GLib otherwise found
  next to its DLLs; an app that doesn't loses its own icons, schemas and
  data.
- Python's images work around two things an AppContainer refuses Python
  (`tempfile`'s directories, multiprocessing's pipes) in a
  `sitecustomize.py`. A Python run with `-S`, which skips `site`, goes
  without it.
- A Python app on GTK 3 lists three runtimes and three SDKs (GTK's, GTK
  3's, PyGObject's), and sets `PYTHONPATH`, `GI_TYPELIB_PATH` and
  `PYGI_DLL_PATH` to name its own directories and its runtimes'. There's no
  GJS for JavaScript apps, and no Vala.
- PyGObject's runtime has Python's standard library and nothing from PyPI
  but PyGObject and pycairo; an app that needs more carries it, from wheels
  a vendor step downloads. A package with C code comes as PyPI's wheel,
  built with MSVC by its project (Gaphor's Pillow), not built with zig; one
  that has no wheel for CPython 3.14 on Windows can't be had that way.
  Gaphor's help opens docs.gaphor.org, and Graphviz in it is only `dot`,
  without its cairo, Pango or image output.
- Meld's git is MinGit's, as a runtime, and runs with Meld's permissions,
  which have no network: under `--sandbox=appcontainer`, pushing from its
  version control view fails. Its help opens on meld.app.
- gobject-introspection's build, and Graphviz's in Gaphor's, use
  winflexbison's prebuilt flex and bison (its sources build with MSVC
  only). They're pinned and only on PATH for that module; nothing of theirs
  is in the SDK or the app.
- A link in a zip source becomes a small file holding the link's target, as
  zigsaw's zip reader doesn't look for links; in a tar, a link to a file
  becomes a copy of it, and any other link fails the build, one to nothing
  as well (Graphviz's tarball of its tag has one).
- Gnumeric has no help (it needs yelp), and is built without its Python and
  Perl plugins, its database plugins (libgda) and the Psiconv and Paradox
  formats. It doesn't read Applix files: the Applix plugin is left out, as
  its exporter's code isn't in the release. Its settings are in
  a key file in its data directory, not the registry, where Gnumeric for
  Windows usually keeps them.
- The CMake files of GTK's SDK's libxml2 name the directory GTK's SDK was
  built in (`B:/prefix`), so CMake's `find_package(LibXml2 CONFIG)` fails
  against the SDK; Gnumeric's recipe gives libxslt a copy with the SDK's
  real path.
- A build sees its SDK and runtime images where the store deployed them, a
  path that differs between stores. A header in one of them that names its
  own file (`__FILE__`, as GLib's `g_return_if_fail` does) puts that path
  into what's built, which then differs from a build in another store; GTK
  3's recipe maps it to a fixed name with `-fmacro-prefix-map`.
- Java's images set `JAVA_TOOL_OPTIONS`, so every Java program in a run
  prints `Picked up JAVA_TOOL_OPTIONS: ...` on stderr, and an app's own
  `JAVA_TOOL_OPTIONS` (in its `env`, or with `--env`) replaces the images',
  `user.home` with it.
- In an AppContainer, Java's `Path.toRealPath()` fails for every path, as
  no drive root lets application packages list it: a Java program that
  calls it there fails, whatever its permissions. OpenJDK 25.0.5 doesn't use
  it to load its security settings any more, and Java's images turn off the
  text shaping that does; others may remain. In an AppContainer, `jps` and
  `jcmd` can't see the program either (no `hsperfdata`).
- Maven's `mvn` doesn't read `.mvn/jvm.config` or `MAVEN_OPTS`, and takes
  the working directory as the project's top (`.mvn/maven.config` and
  extensions are read from there). Neither a Maven nor a Gradle vendor step
  can pin dependencies given as version ranges, `latest` or SNAPSHOT
  versions; Gradle's offline builds serve Maven repositories only, not Ivy
  ones.
- Java apps keep their preferences with the app only if their recipe
  declares the key (`Software\JavaSoft\Prefs\<package>`). In an
  AppContainer, an app that does may read the keys above its own (which
  other Java apps' keys are in: their names, not what's in them) while it
  runs.
- OpenJDK's images are Temurin's builds, published as they come; they
  aren't built from source, which needs MSVC and Cygwin. Each Java app
  carries its jar, not a runtime made for it with `jlink`, and there's no
  JavaFX.
- Logisim-evolution's FPGA commands run the vendor's tools (Quartus,
  Vivado, ISE) from where they're installed on the host, which its runs
  aren't granted: synthesis and download from Logisim fail unless the run
  is given those folders (`--filesystem`); this wasn't tried. Designing and
  simulating work in every sandbox.
- ZLS reaches files outside the working directory only with an override
  (`zigsaw override --filesystem=<dir> org.zigtools.zls`). On Windows
  Server 2025, in an AppContainer, it finds neither zig's library nor a
  project's modules, as `zig env` fails there (no hover on the standard
  library); on Windows 11 26300 it does.
- On Windows Server 2025, in an AppContainer, Python on PyGObject's runtime
  first warns `Failed to find real location of …\python.exe` (CPython's
  getpath can't resolve its own path there, as zig can't), then runs. NUL
  is denied there too, so Meld draws no window (its launcher opens
  `os.devnull` for pythonw's missing output and stops on
  `PermissionError: 'nul'`), and git, from MinGit's image, can't open
  `/dev/null`, so Meld's version control views don't work. A non-admin
  can't change NUL's access. On Windows 11 26300 all of it works.
- CI checks GTK's family (its images and suites) on a push only when
  something they're built or tested from changed, and weekly otherwise: a
  change to zigsaw that a GTK image no longer reproduces with shows up to a
  week later.
- Qt's family is Qt 6.12's Widgets set with QML and Qt Quick: no Qt
  Multimedia, WebEngine, Charts or the other modules, no Imagine style or
  Qt Labs StyleKit for Quick Controls (an app that asks for Imagine gets an
  error that it isn't installed), no qmlls (it needs
  qtlanguageserver), and no Assistant (its HTML viewer is a git submodule
  the source archives leave out, and no documentation is built). Qt's
  QSettings keeps settings in the registry by default, which an app keeps
  apart only for the keys its image declares; the runtime declares
  Designer's (`HKCU\Software\QtProject`).
- An app with several QML modules of its own could build differently from
  run to run, as qtdeclarative did: Qt's CMake doesn't make qmlcachegen
  wait for the other modules' type information. Qt's SDK builds
  qtdeclarative a second time to fix its own; Notes and the test app have
  one module each.
- Qt's runtime is one image: an app that only uses Widgets, as Flameshot,
  gets QML and Qt Quick with it, 153 MB deployed (56 MB compressed) where
  the Widgets set alone was 75 (29).
- Flameshot's "Launch at startup" does nothing at low integrity, its
  default sandbox; under `soft` it writes your real `HKCU\...\Run`, naming
  the program in its deployment rather than its shim, so an update leaves
  it pointing at the old version. Its `flameshot-cli.exe` isn't
  in the image (it cuts commands off at about 80 characters); `zigsaw run`
  passes `flameshot.exe`'s output on instead.
- CI checks Qt's family, like GTK's, on a push only when something it's
  built or tested from changed, and weekly otherwise. Its SDK is built in
  two halves at once, the base (16.5 minutes here with llvm-mingw, 25 with
  zig) and the SDK on the published base (19 here; 26 with zig, 48 before
  qtdeclarative's unity build). Runners differ in speed by half again: with
  zig, the base took 34 and 49 minutes on two of them, and the SDK before
  its unity build 70 and 109, so the jobs' timeout is 180 minutes.
- In an AppContainer, ORAS can't pull into a folder, nor skopeo copy into
  one (`oci:`, `dir:`): both resolve the path with Go's
  `filepath.EvalSymlinks`, which opens each folder from the drive's root
  down, and the container can't open those above what it's granted. Pushing
  from a folder, and registry to registry, work there. cosign, which only
  reads and writes its key files by name, works.
- skopeo has no `containers-storage:` transport on Windows, cosign no
  PKCS#11 tokens or PIV keys (they need cgo), and cosign's signing without a
  key (OIDC, Fulcio and Rekor) hasn't been tried. The OCI tools don't see
  zigsaw's logins nor Docker's: each logs in for itself, and keeps the
  password unencrypted in its data, where zigsaw keeps its own in Windows'
  Credential Manager.
- Chromium's and Electron's sandboxes can't start at low integrity or in an
  AppContainer: Windows refuses them a window station
  ([findings](findings.md#chromium-and-electron)). So VSCodium's,
  ungoogled-chromium's and Electron's runtime's images ask for `soft`, as do
  the apps on that runtime, and each can write whatever you can; zigsaw keeps
  their data apart, and doesn't confine them. Run with
  `--sandbox=low` or `--sandbox=appcontainer` regardless, or with an override
  that says so, they exit with code 3 and no window, after a warning from
  zigsaw that says why (in a message box, from a shortcut). Their
  processes outside its sandbox, such as VSCodium's extension host and terminal
  and either's network service, have your rights, as they do outside zigsaw.
- `--no-sandbox` gets them past that, and takes Chromium's sandbox from every
  process: at low integrity, code that takes over a renderer can read all you
  can and use the network, with no second bug. Overrides can't add it, so it's
  for each run's command line. VSCodium doesn't run in an AppContainer even
  then, nor does its `codium-cli`: Node's `realpath` walks up from a drive root
  the container can't read, and Electron refuses most of `NODE_OPTIONS`, which
  Node's image gets past it with.
- Apps on [Electron's runtime](recipes.md#apps-on-electrons-runtime) run on
  Electron's own program, not their own build of it. Its fuses are as Electron
  ships them, so an app whose build turns off `RunAsNode`, `NODE_OPTIONS` or
  `--inspect`, as draw.io's does, has them on: a program that can start the
  app's `electron.exe` with those can run code as it. zigsaw's runs don't pass
  your variables to it, and under `soft` that code could do no more than
  you, but it isn't what the app's makers shipped. `process.resourcesPath` is
  the runtime's, so an app that keeps files there needs a patch, and its
  `ffmpeg.dll` plays no H.264 or AAC. Pinning a window of one to the taskbar
  pins its shortcut, by the name both carry; that hasn't been checked by hand
  yet, nor whether its notifications show.
- Recent documents an app adds under `soft` (Electron's
  `app.addRecentDocument`, VSCodium's, SumatraPDF's, VLC's) go to your
  real Recent folder, Explorer's `RecentDocs` list, its jump list and Quick
  access, as for a program installed the usual way: Explorer writes them for
  it, outside the app's profile ([findings](findings.md#electron-as-a-runtime)).
  `zigsaw rm` doesn't take them out.
- From PowerShell, `drawio -x ...` returns before the export is done, as
  PowerShell doesn't wait for a program with windows unless its output is
  piped (`| Out-Host`); cmd, Git Bash and `zigsaw run` wait.
- A command that starts a program and ends takes the program with it, as its
  run's job ends what's left. VSCodium's `codium-cli <folder>` does that
  when no instance is running, and works when one is: `codium` is the command
  for it, and prints nothing for `--version`.
- VSCodium's terminal and extensions have your zigsaw apps' commands
  (`--share=commands`) but not programs installed the usual way: an extension
  that looks for a `node`, `python` or compiler you installed yourself doesn't
  find it. `zigsaw-host` reaches those from what's typed, or a terminal profile,
  and an extension can't be told to use it. `bin\codium-tunnel.exe` isn't in the
  image, so `codium-cli tunnel` isn't there. Its longest path is 129 characters,
  in a deployment 107 characters long at `C:\Users\Test\AppData\Local\zigsaw`: a
  user name more than about 20 characters longer than that one could reach
  `MAX_PATH`, which wasn't tried.
- `--share=commands` works under `soft` only: a zigsaw at low integrity or in an
  AppContainer can't open the store, so a run there doesn't get the commands,
  and says so. Each command runs as its own app, with its permissions: one
  without `cwd` doesn't see the project it's run from. `zigsaw.exe` is among them
  when the store's `bin` has it, as an installed zigsaw's does, so a `soft` app
  can run `zigsaw` itself: it could anyway.
- `zigsaw-host` changes the environment, not the rights: it isn't a way out of a
  sandbox, and under `soft` there's nothing to get out of. At low integrity, the
  program runs at low, with your real environment, so it reads your real settings
  and may fail to write them. It finds what's on your PATH as saved in the
  registry, not one a terminal of yours changed. It ends with the run.
- ungoogled-chromium gets a new version only as a new recipe, which each machine
  then builds; nothing checks it in CI, as it isn't published.
- A sign-in that comes back to VSCodium through a link hasn't been tried, only
  links that open files. VSCodium asks before those, as VS Code does.
- `zigsaw update --check` says what `update` would do, so an app pulled at a
  version tag (`:15.2.0`) reads as up to date when `latest` has moved on, as
  `update` wouldn't move it either. An app built from a recipe isn't checked,
  as only building it would tell.
- `scripts/check-upstream.sh` sees the sources recipes name, so not what they bring
  along: dependencies in `Cargo.lock`, `go.sum`, `composer.lock` or a vendor step,
  or the libraries inside a prebuilt app. Its rows for PHP's libraries and SQLite
  read a page with only what's current, so they can't show that the pinned version
  ever existed, and neither can Ghostscript's, whose tags don't sort. Commits and
  TeX Live aren't checked: the report counts them.
- The advisories in that report are only as good as OSV's records, which are uneven:
  PHP's critical RCEs in 8.5.11 aren't there, nor anything recent for PostgreSQL, Qt or
  GLib, which are marked as thin; others may be just as thin without being marked, as
  glib-networking was, whose five CVEs fixed in 2.90.1 OSV didn't list. A match isn't
  checked against these Windows builds either, and libjpeg-turbo 3.1.4.1 has a row for
  a crash in an API its recipes don't build (see
  [findings](findings.md#advisories)). So a critical fix can still look like any other
  update, and an update can be flagged for a bug that can't happen here.
- Those Go apps carry advisories in modules they pin, which a new Go doesn't touch (see
  [findings](findings.md#advisories)). Moving those is upstream's: a recipe builds what
  upstream's `go.mod` says.
- A scheme something else has already is only offered: installing the app doesn't
  change where its links go. zigsaw offers an app for `http` and `https` in
  Settings' Default apps, which lists it, and Windows keeps the choice to you:
  whether choosing it there works hasn't been tried
  ([findings](findings.md#default-apps)).
- VSCodium's image published in iteration 67 (`4c45eaf4`) writes
  `HKCU\Software\Classes\vscodium` on each run under `soft`, naming its
  deployment: an image's patch can't reach it. Updating to the next image, with
  zigsaw 0.68 or later, takes the key over; `zigsaw rm` or `zigsaw repair` removes
  one no installed app declares. A zigsaw before 0.68 ignores `schemes`,
  `commands`, `host` and `unsupported`: the new image runs there without links
  and without the commands, as it asks for nothing they'd need.
- An app that registers itself from inside a run is only stopped by its recipe:
  under `soft`, any program may write `HKCU\Software\Classes`, and zigsaw only
  notices such a key if it names a program in the store's deployments, at the
  next `repair` or `rm`.
- A warning that an image can't run under a sandbox is printed by every run under
  it, whatever else that run was told: `--no-sandbox` gets Chromium past it, and
  the warning stays.
- Windows' Save As dialog says "Location is not available" about an app's
  `home\Documents` if the app's permissions don't name it. Seen with
  ungoogled-chromium, whose recipe now does; saving worked once that was
  answered. Other apps that use the dialog without `documents` may show the
  same: VLC's permissions don't name it, and its dialogs weren't tried.
- A daily check that's on shows nothing unless Windows shows it: Do Not Disturb hides
  the banner (it waits for the next check), and a banner that's missed leaves nothing
  in the notification centre, as Explorer's "shown" doesn't mean anyone saw it. It comes
  back every three days, and `zigsaw list` has a line, so a fix isn't lost, only late.
- The daily check needs the user signed in at some point after noon. A machine's
  policy can refuse scheduled tasks: then `install.ps1` warns, and nothing tells you.
- People on zigsaw 0.72 or earlier have no check until they run `install.ps1` once
  more, and a release before 0.73.0 has no `VERSION`, so `zigsaw upgrade` can't go to
  one. `install.ps1 -Version` still can.
- A zigsaw installed with `-Dir` somewhere else than its store's `bin` isn't told about
  new releases, and `zigsaw upgrade` won't replace it.
- BusyBox's `make` can corrupt an empty macro given on its command line (`FOO=`): a
  recursive `make` may get garbage as its value, and fail with something like `make:
  don't know how to make P\x01\x02\xDBp\x02`, or quietly use it. How often depends on the
  name's length and the heap ([findings](findings.md#an-empty-macro-in-busyboxs-make)).
  No published recipe does this with BusyBox's `make` any more. In a recipe of your own,
  empty the macro in the `Makefile` with `sed` instead, as a value of only blanks has the
  same problem, or build with GNU make (`org.gnu.make`).
- zlib 1.4 reached only the images whose recipes build it. PHP takes php.net's prebuilt 1.3.2,
  and GDAL, Qt, Node, MinGit and Pillow carry their own copies, which the upstream report can't
  see ([findings](findings.md#zlib-inside-images)).
- `zigsaw grants` and what uses its check can print `error: reading the integrity label
  of <folder>` for one of your folders whose label it can't read, and then go on as if
  nothing happened. Only tests have been seen doing this, with a folder that didn't
  exist.
- A recipe's source on plain `http://` that redirects to `https://` panics `zigsaw
  build`, in Zig 0.17's std (`client.now.?` in `connectTcpOptions`, which only a first
  request over TLS sets). No published recipe has such a source. `https://` from the
  start is fine, redirects included.
- `zigsaw rollback` takes back only the data in the app's own volume. What it keeps in
  a volume it mounts, or in a folder of yours, stays as the newer version left it, and
  so does all of its data if that is mounted from elsewhere (`--volume=<source>:.`):
  PostgreSQL's server set up with its cluster in a named volume doesn't read it after
  going back across a major version, and nothing warns about it.
- The data kept for going back is one copy for each app, replaced at the app's next
  install. That goes for data a rollback set aside too: go back with the data, work a
  week, and take an update, and what the version you left had written is gone (the
  update says "dropped"). It's in the store beside the data, and no backup: `zigsaw
  volume export` makes one, when you run it.
- If you go back and leave the data, then go forward again, the copy kept of the older
  version's data is replaced by one of the data as it is now, which that version may
  not read: zigsaw can't tell whether it did.
- The copy leaves out the app's temporary files and its cache (`cache\` and
  `home\AppData\Local\Temp` in its data): data taken back starts with neither. An app
  that keeps something it needs there loses it by going back with its data.
- An app that runs while its version is replaced has its data copied by its next run,
  before it starts. From a shortcut, nothing shows that: a large data directory makes
  that start slow once. If the new version is started while the old one still runs, no
  copy is kept at all (a note says so, in a console).
- A file in the app's data that another program holds open without sharing it stops
  the copy, and the update goes on with a warning and no copy. Taking the data back
  fails the same way on a folder something has open, with the version already gone
  back; `zigsaw rollback --data-only` tries again.
- Copying costs the data's size and the time to read it, at every install over a
  version, `build` included; `zigsaw override --nosnapshot` is the way out for an app
  with gigabytes of it. Only on ReFS (a Dev Drive) is the copy a clone that costs
  neither. Many small files cost more than their size says: 20,000 files of 4 KiB took
  6 s here, on either kind of drive, where 1 GB in 10 files took half a second. An app
  with a profile of a hundred thousand files makes every update of it that much longer.
- Only one version is kept to go back to: the one the installed version replaced. Two
  updates in a row, and the first version is gone, as before 0.76.
- Going back brings back whatever the newer version fixed. Updates pass over only the
  very version a rollback left, so the next one reaches the app, but until then it
  runs the older one, and the daily check says nothing about it.
- A rollback isn't checked against signatures: the image was when it came in. A key
  removed since, or one that never signed it (a warning then), doesn't stop it.
- `zigsaw volume export` keeps files, folders, each file's time of last change and
  whether it's read-only. It doesn't keep ACLs, the hidden and system attributes,
  alternate data streams, or the times of folders; two hard links to one file become
  two files, and a sparse file is written whole. An import makes the files anew, with
  what the volume's folder passes on to them.
- An export passes over links, and so over the volumes an app mounts in its data and
  the folders of yours it links: an app with its cluster in a named volume needs two
  exports, the app's id and the volume's name, and nothing ties the two archives
  together. An app whose data is mounted from a folder of yours (`--volume=<folder>:.`)
  isn't exported by its id at all.
- An app's own volume is exported without its cache and temporary files unless
  `--all`: data imported from such an archive starts with neither, as data a rollback
  takes back does.
- Neither export nor import works while a run uses the volume, so there's no backup of
  a server that has to stay up: stop it, export, start it. They also hold the store's
  lock as every command does, so a `pull`, `update` or `build` waits for a long export
  to end ("waiting for another zigsaw command to finish...").
- An archive isn't signed or encrypted, and an app's has its settings and the registry
  keys it keeps: whoever has the file has those. Nothing checks, either, that data is
  imported for the app, or the version, that wrote it: the import says what the archive
  is of, and a server may not read what a newer major version wrote.
- An app's data can hold paths into the store it was in (a config file naming
  `...\volumes\<id>\...`). Imported into a store kept elsewhere, those lead nowhere, as
  after 0.85's move from `data\`.
- gzip is one thread of Zig's deflate, about 45 MB/s here; a plain `.tar` is as fast as
  the drive. There's no zstd: Zig's std only reads it.
- Importing many small files is slow where Defender watches: 20,000 files of 4 KiB took
  19 to 23 s here, three times what Windows' `tar.exe` takes for the same archive, and
  the same as a 40-line program that only creates the files
  ([findings](findings.md#what-a-file-costs-to-make-iteration-91)). Threads don't help,
  so there are none. Large files don't feel it (1 GB in 10 files: 1 s).
- A file's time of last change costs 1 KiB in a plain tar, as a header of its own:
  20,000 files of 4 KiB make an archive of 107 MiB for 78 MiB of files, where
  `tar.exe`'s, which keeps whole seconds, is 88 MiB. gzip takes most of it back.
- `import --replace` needs room for the old files and the new at once, on the volume's
  drive, and deletes the old ones for good: nothing is set aside to go back to.
- If zigsaw is killed between the renames of an `import --replace` (a few milliseconds,
  after the archive is unpacked), the volume's files are in two folders inside it,
  `.zigsaw-replaced-…` (the old) and `.zigsaw-import-…` (the new, some of them moved
  up already). Export and import of that volume then refuse and name both; an app that
  runs meanwhile finds its data gone, and nothing puts it back but you.
- Windows' own `tar.exe` (bsdtar) skips a file whose name its code page can't hold
  ("empty or unreadable filename"), from zigsaw's archives as from any with names in
  UTF-8, and it crashed here making an archive of a folder with such a name. GNU tar and
  7-Zip read them, and `zigsaw volume import` does.
- An archive from another tool with links in it (symbolic or hard) imports without
  them, with a count: Linux data with symlinks isn't whole afterwards. One whose tar
  spans several gzip members (`bgzip`, `pigz -i`) reads as cut short.
- A zigsaw before 0.76 doesn't know of `versions\`: its `update` moves a held app, and
  takes the version a rollback left, and its `prune` deletes the blobs kept for
  `rollback`, which then says how to have the version back.
- Until a lazy pull's download is done, a file nothing has read needs the registry. An
  app started offline that reads one fails as a program does whose files can't be
  read, often with a "bad image" error (`BAD_EXE_FORMAT`); a console run then names
  the file, but a GUI app may show its own error, or stop, first.
- A layer pulled lazily is served by its helper, which a run of the app, a build using
  the image, or a pull starts if it's gone. An extension pulled with `--lazy` gets one
  only from those of its own: a run of the app it extends doesn't start it.
- A helper started where everything a program starts ends with it (a job that refuses
  breakaway, as some terminals' and GitHub's runners' do) ends then too. zigsaw says
  so, and the app's next run starts one again.
- `pull --lazy` and `update --lazy` copy what the store's other eStargz layers have of the
  new one (the version an update replaces, mostly) only from blobs the store has whole: a
  version that was itself pulled lazily copies nothing until its download finished. And
  the pull's own reads of its programs' headers still come from the registry.
- A 0.79 helper with a copy plan counts the blob in blocks of 64 KiB. A zigsaw before 0.79
  can't read that map: a helper of its, on the same store, downloads the layer again.
- A placeholder is fetched whole when a program opens it, and its first read costs more
  than in a plain deployment (some 7 ms here, Defender's look at it, an unpack pays when
  writing). Explorer drawing a shortcut's icon fetches its program.
- A fetch that takes long now tells Windows how far it's got every 2 seconds, so Windows'
  60 seconds don't run out. The registry may still cut a request read very slowly (a
  local zot did, after some 70 s at 40 KB/s): that fetch fails, and the program's read is
  tried again.
- Placeholders need NTFS: on a Dev Drive (ReFS), a network share or FAT, `--lazy`
  downloads whole. Whether a registration outlives a reboot hasn't been tried; a helper
  registers the folder again if Windows forgot it.
- A zigsaw before 0.77 knows nothing of `lazy\`: on the same store it takes placeholders
  for a complete deployment, which works only while a helper serves, and its `prune`
  deletes them without stopping the helper. Let downloads finish, or `rm` such apps,
  before going back to an older zigsaw.
- An update that replaces a version pulled lazily before its download finished leaves
  nothing to go back to: its layer's blob was never complete, so `rollback` says how to
  pull that version again.
- `--lazy` helps only an image whose big layers are eStargz: its gzip layers, and those
  below the 32 MiB at which a layer is pulled lazily, download whole before anything
  starts, as the CMake of Qt's SDK does (21 MB) and Ghostscript's of TeX Live (12 MB).
  And only an app whose first use reads a small part: a file is fetched whole, so
  VSCodium, whose program is 239 MB of its layer, waits for it.
- An eStargz layer is bigger than a gzip one: each file is a gzip member of its own.
  Perl's, of many small files, is 53.6 MB against 48, so a full pull of it is that much
  longer; Qt's grew 2 to 5%.
- Only Qt's runtime and SDK, TeX Live, Perl and VSCodium have `prefetch` lists (MinGit's
  layer isn't read by what VSCodium's window does). Elsewhere a first run's files come
  as it asks, one after another, each a round trip; a list needs the image published
  again. A list says what one run read when it was recorded: another command, or a new
  version, reads other files, which then come as asked. Perl's is what TeX Live's first
  `pdflatex` reads of it, not what PostgreSQL's PL/Perl does. Qt's SDK's is 456 paths
  long, VSCodium's 193, in their recipes.
- The unpack waits while a run uses the deployment, so a long run (an editor left open)
  keeps the app on placeholders until it ends, and the layer then unpacks and swaps.
  A run that starts during the unpack gets the machine first, but not to itself.
- The first run after the swap is cold: the unpacked files are new to Windows, and that
  run pays what a run on a fresh deployment does (TeX Live's `pdflatex` 14 to 22 s once,
  then 0.3 s; llvm-mingw's `clang` 0.5 s once, then 0.24). Iteration 78 tried keeping the
  files instead, by hydrating what's left and making placeholders plain files
  (`CfRevertPlaceholder`): the result has the same bytes and attributes, but every later
  `clang` takes 0.33 s, as Windows builds libLLVM's image section anew each time (66 ms
  against 0.5), so the swap stays a rename. Reading the new files before the first run
  doesn't warm them either (0.49 s): the cost is in starting the program.
- A zigsaw before 0.78 doesn't know a 0.78 helper's `blob.sparse`: one that serves a layer
  a 0.78 helper started fetches from the registry what that one had, and downloads it all
  again.
- `--memory` limits commit, not what a program has in RAM: a program that
  reserves and commits far more than it touches reaches the limit early, and
  one refused memory fails however it fails when a machine runs out, not
  with a message of zigsaw's until the run or the build's command is over.
  Nothing is ended at the limit: a program that goes on without the memory
  goes on.
- `--cpus` tells cargo through `CARGO_BUILD_JOBS` and others through
  `NUMBER_OF_PROCESSORS`; a program that counts the machine's processors
  itself and reads neither still starts as many jobs as the machine has
  processors, on the N it was given: zig (`zig build` takes `-j`), CMake's
  `NUMBER_OF_LOGICAL_CORES`, Python's `os.cpu_count()`. The table is in
  [findings.md](findings.md#limits-through-the-job-object-iteration-93).
  A recipe that sets `CARGO_BUILD_JOBS` keeps its own number.
- Every limited run and build gets the same N processors, so two at once
  share them while the others idle. On a machine with more than 64
  processors, they are of the processor group zigsaw is in.
- A run started inside a limited run (`--share=commands`) is held to the
  outer one's limits, but hears less of them: with no `--cpus` of its own it
  keeps the outer one's processors, while its own job shows no CPU rate cap,
  so Ninja in it counts every processor of the machine, and zigsaw sets it no
  variables; and when the outer memory limit is reached in it, only the
  outer zigsaw says so, at its end. (Measured with a job inside a job; no
  app was run inside another's run.)
- Limits are per run and per build command, not per app: two runs of an app
  held to 2 GB may have 4 GB together.
