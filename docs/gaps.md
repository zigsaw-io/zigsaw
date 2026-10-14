
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
  is gone, and so does a low integrity label under `--sandbox=low`.
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
- The registry isn't isolated. Under `soft`, an app that keeps its settings
  in `HKEY_CURRENT_USER`, as 7-Zip does, writes the real registry, shared
  with a copy of the app installed the usual way and left behind by
  `zigsaw rm`. At low integrity and in an AppContainer such writes fail, and
  apps such as 7-Zip carry on without saving their settings.
- Desktop, Documents, Downloads and Pictures are folders in the app's
  redirected profile, which don't exist: apps' file dialogs don't show
  yours, only the drives, and an app that asks for Documents to save in
  gets an error or nothing. `AppData\LocalLow` and the profile folder are
  your real ones, in every sandbox.
- In an AppContainer, 7-Zip's file manager opens an archive given with
  `--file` at its root view instead: it goes through the archive's path from
  the drive root, whose folders the container can't read.
- At low integrity and in an AppContainer, an app can't add buttons or a
  progress bar to its taskbar button (Explorer refuses it), as VLC tries to.
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
