
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
- Under `--sandbox=appcontainer`, access granted to a host path lasts until
  the app is removed, even after the permission or override that granted it
  is gone (`--nofilesystem` included), and so does a low integrity label
  under `--sandbox=low`. For one of the user's folders, the link in the
  app's home goes with the permission; the grant stays.
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
- The registry is kept apart only for the keys an app's image declares
  (`registry`, as 7-Zip's does). Under `soft`, an app that writes other keys
  in `HKEY_CURRENT_USER` writes the real registry, and leaves them behind
  after `zigsaw rm`; at low integrity and in an AppContainer such writes
  fail, and apps carry on without them. No override or run option adds a
  key to an app's.
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
  or screenshots. Ten runtimes and SDKs have no name or summary in it yet,
  only their commands: busybox, zig, Rust, CMake, Meson, Perl, cargo-c,
  gettext and GTK's SDK and runtime. Naming any of them changes its digest,
  and the GTK SDK pins them all, so they get one at their next version
  (Node and Go got theirs in iteration 22).
- `pull` and `update` tell what an app may reach, and don't ask whether to
  go on.
- An app sees only the user's folders its permissions name (Desktop,
  Documents, Downloads, Music, Pictures, Videos), linked into its profile;
  others don't exist there, and an app that asks for one to save in gets
  an error or nothing. `AppData\LocalLow` and the profile folder are your
  real ones, in every sandbox. Saved Games, Contacts, Favorites, Links and
  Searches, and the Public folders, can't be granted by name.
- A folder is granted whole: there's no `documents/Notes` for one folder in
  it. Under `--sandbox=low` a writable folder is labelled low integrity
  until `zigsaw rm`, so any low-integrity program can write in all of your
  Documents meanwhile. The first low or AppContainer run with a folder
  changes the ACL of every file in it, which takes a while for a big one.
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
- zigsaw keeps its own registry logins; it doesn't read Docker's
  `config.json` or credential helpers.
- Multi-platform image indexes aren't supported.
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
- Files works in the `soft` sandbox only. At low integrity and in an
  AppContainer, Windows' storage APIs refuse a program without a package:
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
  fallback of its own. Like other grants it lasts until `zigsaw rm`: under
  `--sandbox=low`, a file opened once stays writable to every
  low-integrity process until then.
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
- Xdebug's step debugger can't connect to an IDE from an app running under
  `--sandbox=appcontainer`: an AppContainer can't reach `127.0.0.1` without
  a loopback exemption (`CheckNetIsolation`), which takes an administrator.
  It does under `soft` and `low`.
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
  under `--sandbox=low`. Under `--sandbox=appcontainer` it starts, but a
  browser can't reach it, as an AppContainer can't be reached on
  `127.0.0.1` without a loopback exemption. Kanboard works under `soft`.
- Kanboard is served by PHP's built-in web server, which handles one
  request at a time and is meant for development: fine for one person on
  their own machine, not for a team. Its plugin installer is off, as
  upstream's default; plugins go in `plugins` in its data by hand. Its
  router keeps `app\`, `libs\`, `vendor\` and `cli` from the web; PHP's
  server ignores Kanboard's `.htaccess` files.
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
