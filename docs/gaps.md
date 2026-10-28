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
  until the app's next run ends, `zigsaw repair` or `zigsaw rm`. Two stores
  don't know each other's labels: taking one back for an app in one store
  takes it from an app of the other that needs it too.
- At low integrity, an app with `cwd` run from your user profile, a folder
  that holds it, or a drive's root gets its working directory read-only for
  that run, with a warning, as labelling it would let every low-integrity
  program write anywhere in it: a command that writes there fails (`npm
  init` in your home folder). Run it from a folder inside, or with
  `--sandbox=soft`.
- Windows starts a program whose file is labelled low at low integrity,
  whoever starts it. A low run labels the app's working directory and what's
  in it, and what a low-integrity program writes is labelled low anyway: the
  programs there then start at low integrity outside zigsaw too, until
  `zigsaw rm` takes the label back. Toolchains' images (zig, Rust, Go, CMake,
  make, Meson, Node, Python, the JDK, Maven, Gradle, and the GTK, Qt and PHP
  SDKs) ask for soft for that. Others don't: 7-Zip extracting programs, or
  MinGit checking them out, at low makes programs that start at low.
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
- The loopback exemption is a setting of Windows for the whole machine,
  which this account (an administrator's, unelevated) and GitHub's runners
  may change. A standard user's account is untested: where Windows refuses,
  the run says so, and the app reaches only the ports it uses. Two users'
  zigsaws changing the list at the same moment could undo each other's
  change, as the lock zigsaw takes for it is per session.
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
- zigsaw's releases aren't signed. `install.ps1` checks the zip against the
  release's `SHA256SUMS`, which comes from the same release; anyone can
  check the programs against a build of the tag (see
  [Installing zigsaw](#installing-zigsaw)). Releases are for x64 only.
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
  changed would make other digests from the same files; CI pins Zig 0.16.0.
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
  ([findings](findings.md#other-findings)). The released programs scan
  clean, and from 0.22.0 they carry version information and a manifest, but
  Defender's machine learning may still flag an unsigned build by what it
  does; zigsaw's programs aren't signed.
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
- A shortcut or a kind of file shows the icon of an `.ico`, or of an
  executable that has one: a recipe whose app has only an SVG has to make
  the `.ico`, as GTK's and Text Editor's do with the SDK's `rsvg-convert`.
- zigsaw sets no AppUserModelID. An app started from its shortcut counts
  as started from it; whether pinning its window to the taskbar then pins
  the shortcut, and not the app's executable in the store, hasn't been
  checked: it takes pinning one by hand.
- zigsaw offers an app for a kind of file, and can't make it the default:
  Windows keeps that choice to the user. Only extensions are registered:
  no MIME types, no URL schemes, no "New" menu entries, and no command
  other than opening.
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
  apps, and it isn't published or checked in CI.
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
  wouldn't. The recipe changing starts afresh; a change to an SDK's image
  does only through the recipe's pin. A project moved to another directory
  starts afresh, its work directories being keyed by the recipe's path.
- Each `zigsaw build` of a project reads all of its files to hash them,
  even when it then takes the image built before: quick for a source tree,
  slower for one with large assets that aren't ignored or skipped.
- A project's files leave out a file that a `.gitignore` ignores but git
  tracks anyway (added with `git add -f`), which git would commit. A link
  in a project fails its build, which git would commit as a link.
- `push --sources` doesn't push a project's files, as they're local, like
  a recipe's local files.
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
  real path. GTK's SDK's `windres` doesn't take `--include-dir` (Gnumeric's
  recipe passes `-I`).
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
  two halves at once, the base (25 minutes here) and the SDK on the
  published base (26 here; 48 before qtdeclarative's unity build). Runners
  differ in speed by half again: the base took 34 and 49 minutes on two of
  them, and the SDK before its unity build 70 and 109, so the jobs'
  timeout is 180 minutes.
