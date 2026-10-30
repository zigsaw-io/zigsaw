# Findings

## Does the no-admin stack hold up?

Iteration 1 asked whether zigsaw can run real command-line tools reproducibly
on Windows (Home edition included) without admin rights. We tested six tools
in both sandboxes with [`tests/matrix.sh`](../tests/matrix.sh): busybox,
ripgrep, MinGit, Node + npm, Python (embeddable) and the zig toolchain. Tested
on Windows 11 Home 10.0.26300 with Defender real-time protection on.

### Summary

- **The `soft` sandbox works for every tool tested.** All 26 checks behave as
  intended. Each app gets a hermetic environment, a data directory that
  persists, and working-directory access. All six tools, including git, npm
  and zig builds, keep their state in the data directory.
- **The `appcontainer` sandbox only suits self-contained tools.** Busybox,
  ripgrep and Python mostly work, and the permissions are enforced. Git, Node
  scripts, npm and zig fail because of two Windows restrictions on
  AppContainers that zigsaw can't lift without admin rights.
- One reproducibility hole in `soft` mode was found and fixed: apps could
  modify installed app files.
- **Re-checked in iteration 8** (see [below](#re-checked-on-windows-11-263009550)):
  on Windows 11 26300.9550, restriction 1 is gone, and git and Node work
  under `appcontainer` in part. A low-integrity sandbox would suit every
  tool tested.
- **The `low` sandbox (iteration 9)** works for every tool the matrix runs,
  and keeps them from writing outside their data directory and the paths
  they may write (see [below](#the-low-sandbox)). It confines nothing else.
- **Prebuilt GUI apps (iteration 17)** keep their settings in their data
  directory in all three sandboxes, since Windows derives AppData from
  `USERPROFILE`; the registry, `LocalLow` and the user's Documents and the
  like don't follow (see [below](#prebuilt-gui-apps)).
- **The registry (iteration 19)**: a key in HKCU labelled low, or granted
  to an app's capability, is one the app can write at low integrity and in
  an AppContainer, so zigsaw keeps an app's keys with its data and puts them
  there for its runs (see [below](#the-registry)).

### Matrix

`ok` = exits 0, `fails` = exits non-zero. ✗ marks results that differ from
the intended behaviour.

| Tool | Check | soft | appcontainer |
|---|---|---|---|
| busybox | runs, exit codes, writes to data dir | ok | ok |
| busybox | app files are read-only | fails (intended) | fails (intended) |
| busybox | write to an ungranted host dir | ok (not enforced) | fails (intended) |
| busybox | background children end with the run | ok | ok |
| ripgrep | runs, searches the granted cwd | ok | ok |
| ripgrep | read an ungranted host file | ok (not enforced) | fails (intended) |
| git | `--version` | ok | ok |
| git | `config --global`, `init`/`commit`, `ls-remote` over HTTPS | ok | ✗ fails |
| node | `-e`, `fetch` over HTTPS | ok | ok |
| node | script file, `fs.realpathSync`, `npm install` | ok | ✗ fails |
| python | script file, HTTPS with system certificates | ok | ok |
| python | `os.path.realpath` | ok | ✗ fails (returns unresolved path) |
| python | network denied by `--unshare=network` | ok (not enforced) | fails (intended) |
| python | write into its own app dir | fails (intended) | fails (intended) |
| zig | `version` | ok | ok |
| zig | `env`, `init` + `build run` | ok | ✗ fails |

### Why the AppContainer failures happen

**1. Converting a path to a drive letter is denied.**
`GetFinalPathNameByHandleW` with `VOLUME_NAME_DOS` fails with
`ERROR_ACCESS_DENIED`, while the same call with `VOLUME_NAME_NT`
(`\Device\HarddiskVolume3\...`) succeeds. The failing step is mapping the
volume device to `C:`, which goes through the Mount Manager, and
AppContainers can't open it. Git calls this to get its working directory,
Python and Node use it for `realpath`, and zig uses the same mapping to find
its own executable. Rust's `std::fs::canonicalize` calls the same API, so
Rust tools that canonicalize paths will likely fail the same way.

**2. `C:\` itself grants nothing to AppContainers.** The drive root has no
entry for `ALL APPLICATION PACKAGES`, so `lstat("C:\\")` fails with `EPERM`.
Node's JavaScript `realpath` checks every parent folder of a path, so loading
any script file fails, and npm with it.

Neither can be fixed without admin. The root folder's permissions belong to
SYSTEM/TrustedInstaller, and the Mount Manager's access rules are set by
Windows. We tested this with a probe program that calls
`GetFinalPathNameByHandleW` with each flag combination inside the
AppContainer. The probe ruled out missing grants on parent folders as the
cause.

**3. On Windows Server 2025, `NUL` is denied too** (iteration 6, seen on
GitHub's `windows-2025` runners). Git opens `/dev/null` as it starts, and
fails ("could not open '/dev/null' for reading and writing: Permission
denied"), so even `git --version` fails there. On Windows 11 it starts. Go's
toolchain opens `NUL` too, while it builds ("error obtaining buildID for go
tool compile: open NUL: Access is denied"), so Go builds that work under an
AppContainer on Windows 11 fail there (iteration 7). The matrix marks these
AppContainer failures as known gaps, so CI only fails when a result
changes.

## Re-checked on Windows 11 26300.9550

Iteration 8, 2026-10-05. From iteration 7 on, several known AppContainer
gaps passed on the development machine: `git --version`, `zig env`, zig's
project, and Python's realpath. Three Windows updates (KB5124010, KB5121794,
KB5124009) were installed on 2026-10-03, between iteration 6's matrix, where
they failed, and iteration 7's.

[`tests/acprobe.zig`](../tests/acprobe.zig) (`zig build acprobe`) checks the
causes found above, from inside an AppContainer, on this machine:

| Check | soft | appcontainer |
|---|---|---|
| `final-path-dos`: the working directory's path with its drive letter | ok | ok |
| `self-path-dos`: the same for its own executable | ok | ok |
| `final-path-nt`: the NT path, as a control | ok | ok |
| `mount-manager`: opening the Mount Manager | ok | ok |
| `drive-root`: the drive root's attributes | ok | denied |
| `nul`: NUL, to read and write | ok | ok |

- **Restriction 1 is gone here.** AppContainers can open the Mount Manager
  now, so paths resolve to drive letters. Python's realpath, zig and CMake
  work.
- **Restriction 2 remains, and is wider than the drive root.** An
  AppContainer can't read the attributes of any directory that doesn't
  grant it access. Those are the drive root, `C:\Users`, and the parents of
  the paths zigsaw grants.
- **Windows Server 2025 isn't known.** CI's runners denied `NUL` in
  iterations 6 and 7. The matrix now prints the probe's results, so the
  Reproduce run's log shows them.

What the remaining failures need:

- **git** fails in repository discovery: it stats the working directory's
  parent, to stop at a filesystem boundary, and dies when that's denied
  ("failed to stat '...Temp'"). With `GIT_DISCOVERY_ACROSS_FILESYSTEM=1`,
  which MinGit's recipe now sets, git skips that stat, and `config --global`
  and `ls-remote` work. Creating files, git stats each directory of their
  path from the drive root, so `init` and `commit` still fail.
- **Node** resolves script and module paths with its JavaScript realpath,
  which `lstat()`s each directory of the path, the drive root first. With
  `NODE_OPTIONS=--preserve-symlinks --preserve-symlinks-main`, which Node's
  recipe now sets, it doesn't, and scripts, `npm install` and npm's global
  commands work. `fs.realpathSync` still fails, and so does `npm install -g`:
  npm itself `lstat()`s `C:\Users`. `fs.realpathSync.native` works.

[`tests/matrix.sh`](../tests/matrix.sh) runs the probe first, and expects each
known gap whose causes the probe finds lifted to pass, so a regression
fails it. Where the causes remain, the gap stays a known gap.

### A low-integrity sandbox

Option 2 below, tried by hand: `zigsaw-acprobe --low <command>` runs a
command with a copy of the user's token labelled low integrity, which needs
no privileges. The tools ran from their deployments, with their home and the
working directory labelled low (`icacls <dir> /setintegritylevel low`):

| | low integrity |
|---|---|
| The probe's six checks | all ok |
| git: `--version`, `config --global`, `init` | ok |
| Node: a script, `npm install`, `fetch` over HTTPS | ok |
| Python: a script, `realpath` | ok |
| zig: `env`, `cc` | ok |
| Writing to a directory not labelled low, or into the store | denied |
| Reading a file not labelled low | ok |

- **Every tool tested works**, unlike under AppContainer: low integrity
  restricts writing, not reading or path resolution.
- **It confines writes only.** Reading and the network stay open, as in
  `soft`.
- **AppContainer grants break it.** A file whose ACL grants a particular
  AppContainer access can't be read by a low-integrity process outside that
  AppContainer, even though the user is granted full access. zigsaw grants
  each app's AppContainer read access to its deployments the first time the
  app runs under `--sandbox=appcontainer`. After that, zig at low integrity
  can't find its own executable, and Python doesn't start. A low-integrity
  sandbox would need deployments granted some other way, such as through
  `ALL APPLICATION PACKAGES`. *Resolved in iteration 9; see below.*

## The low sandbox

Iteration 9, 2026-10-05, Windows 11 26300.9550.

### Which grants keep low integrity out

Python's deployment, copied without zigsaw's entries, then given one allow
entry (read and execute, inherited) at a time, and run at low integrity
(`zigsaw-acprobe --low`):

| The entry's SID | At low integrity |
|---|---|
| none (the control) | runs |
| an AppContainer's package SID, `S-1-15-2-` and seven numbers, as zigsaw granted until now | fails: every open is denied |
| `ALL APPLICATION PACKAGES` (`S-1-15-2-1`) | runs |
| `ALL RESTRICTED APPLICATION PACKAGES` (`S-1-15-2-2`) | runs |
| a capability SID (`S-1-15-3-1024-` and eight numbers) | runs |

- **Only package SIDs do it**, and they deny everything: reading a file,
  listing the directory, and resolving the path (the probe's
  `final-path-dos`, `self-path-dos` and `final-path-nt` all fail with
  `ACCESS_DENIED`). The user's own full access doesn't help.
- **Executables still start**, as the process that starts them maps the
  file, which is why busybox seemed unaffected: it loads no DLL of its own.
  Python fails loading its DLLs, and zig resolving its own path.
- **zigsaw now grants a capability of each app's own** instead: a SID
  derived from `zigsaw.<id>` (`DeriveCapabilitySidsFromName`), which only
  that app's AppContainer runs hold. It isolates apps from each other as
  the package SID did, and low integrity ignores it. Runs remove the old
  entries from what they use: any package SID's from deployments and data
  directories, which only zigsaw grants, and the app's own from host paths.

### Programs written at low integrity (iteration 56)

Windows starts a program at the lower of the starting process's integrity
and the program file's label. Probed on Windows 11 26300, unelevated, with
BusyBox copying a program (tests/hostprobe.zig, which prints its own
level) in each sandbox, and `icacls` for the labels:

| The program | Its label | Starts at |
|---|---|---|
| written at low into an `(OI)(CI)` low folder | `Low:(I)(NW)`, inherited | low |
| written in an AppContainer into a granted, unlabelled folder | `Low:(NW)`, its own | low |
| either, given an own medium label (`AddMandatoryAce`, no flags) | `Medium:(NW)` | medium |
| the same, after its folder is labelled `(OI)(CI)` low again | `Medium:(NW)`, kept | medium |

- **Making a file stop inheriting its label takes a privilege**:
  `SetNamedSecurityInfoW` with `PROTECTED_SACL_SECURITY_INFORMATION` or
  `UNPROTECTED_SACL_SECURITY_INFORMATION` fails with 1314
  (`ERROR_PRIVILEGE_NOT_HELD`, SeSecurityPrivilege), even for the file's
  owner. An own label needs only WRITE_OWNER, and an own medium label beats
  an inherited low one.
- **A low process can't write into a file with an own medium label**, but
  can delete it, or rename another over it, through its low folder's
  FILE_DELETE_CHILD. An own low label lets it write again; so does clearing
  the own label, where the folder's is inherited.
- **ReadDirectoryChangesW** from the medium zigsaw sees what low and
  AppContainer processes write, in subfolders too, including a file renamed
  into place (actions 1, 3, 4 and 5).
- **A process at low integrity that takes a label back makes it worse**:
  writing an empty label SACL from a low-integrity zigsaw (its own program
  was labelled low) left an own low label on the folder and on everything
  below it. A low-integrity process can only set its own level.
- **How CI's Kanboard ran at low** (iterations 54 and 55):
  tests/published.sh ran its smoke runs from its scratch folder, which held
  the pull store. MinGit, low with `cwd`, labelled that folder, the label
  reached every deployment, and php.exe started at low under Kanboard's
  soft run, where PHP's `is_writable()` says no ([below](#phps-is_writable-at-low-integrity)).

### The matrix

`tests/matrix.sh` runs each check in `soft`, then `appcontainer`, then
`low`, so each low run reads files an AppContainer run has just been
granted. Every check's low result is as intended, 0 mismatches:

| Tool | Check | soft | appcontainer | low |
|---|---|---|---|---|
| busybox | write to an ungranted host dir | ok (not enforced) | fails (intended) | fails (intended) |
| ripgrep, bat, zstd | read an ungranted host file | ok (not enforced) | fails (intended) | ok (not enforced) |
| git | `init`/`commit` in cwd | ok | fails (known gap) | ok |
| node | `fs.realpathSync`, `npm install -g` | ok | fails (known gap) | ok |
| python | network denied by `--unshare` | ok (not enforced) | fails (intended) | ok (not enforced) |
| all twelve tools | every other check | as in soft | | as in soft |

- **Labels propagate.** zigsaw labels a directory with an inherited low
  label (`(OI)(CI)(NW)`); the files already in it, and those the app
  creates, inherit it, and removing the label removes theirs. 20,000 files
  took 2.2 s to label, about what granting them to an AppContainer takes
  (2.4 s).
- **A low run's first label of its data directory** is the slow part, once:
  zig's first low run took 9 s, with its cache.
- **Windows Server 2025 isn't known.** CI runs the matrix there, as an
  administrator; it wasn't seen from here.

## Prebuilt GUI apps

Iteration 17, 2026-10-14, Windows 11 26300. The tools above are
command-line programs that read their folders from environment variables,
and the GUI apps of iterations 10 to 16 were built here against GTK, with
GLib's folders set by variables too. Most Windows programs are published
built, and ask Windows instead.

### Where Windows sends a program

[`tests/hostprobe.zig`](../tests/hostprobe.zig) (`zig build hostprobe`) asks
what a desktop program asks, run as an app
([`tests/hostprobe/app.json`](../tests/hostprobe/app.json)): the paths
`SHGetKnownFolderPath` gives, whether a file can be made there, and what the
registry allows. "data" is the app's data directory, `home` the profile
zigsaw makes in it:

| | soft | low | appcontainer |
|---|---|---|---|
| RoamingAppData | data `home\AppData\Roaming` | the same | the same |
| LocalAppData | data `home\AppData\Local` | the same | the container's folder in data (`...\Packages\zigsaw.<id>\AC`) |
| LocalAppDataLow | real, writable | real, writable | the container's folder in data |
| Documents, Downloads | data `home\Documents`..., missing | the same | the same |
| Profile | real, writable | real, read-only | real, unreadable |
| ProgramData | real, writable | real, read-only | real, unreadable |
| `GetTempPath2` | data, as TEMP | the same | the container's Temp in data |
| `GetUserProfileDirectory` | real | real | real |
| write `HKCU\Software` | ok (the real registry) | denied | denied |
| write `HKCU\Software\AppDataLow` | ok | ok | denied |
| read `HKLM` | ok | ok | ok |
| create the file dialog (COM) | ok | ok | ok |
| open the clipboard, without a window | ok | ok | denied |

- **AppData follows `USERPROFILE`.** Windows keeps the user's folders as
  `%USERPROFILE%\AppData\Roaming` and so on, and expands that with the
  program's own environment, so the redirect zigsaw sets for programs that
  read variables steers those that ask Windows as well.
- **What doesn't follow it**: LocalLow, which Windows derives from the
  profile it knows from the token; the profile folder itself; ProgramData;
  and the registry. Under `soft` a program can write all of them; at low
  integrity only LocalLow and `HKCU\Software\AppDataLow`; in an AppContainer
  none of them.
- **Desktop, Documents, Downloads and Pictures** follow it too, into a home
  that doesn't have them. In a file dialog they're gone: Notepad++'s Open
  dialog showed This PC and the drives only.
- Runs' environment has no `ProgramData`, `ProgramFiles`, `PUBLIC` or
  `COMPUTERNAME`. None of the four apps below missed them, so they stay out
  (builds share the environment, and CMake, for one, searches
  `ProgramFiles`).

### Four apps

7-Zip 26.04 (its file manager), Notepad++ 8.9.8.1, SumatraPDF 3.6.1 and
VLC 3.0.24, from upstream's archives
([`tests/guiapps.sh`](../tests/guiapps.sh)). Each opened a file given with
`--file`, named it in its title, and was closed as its close button would:

| App | soft | appcontainer | low | Its settings |
|---|---|---|---|---|
| 7-Zip's file manager | ok | opens its root view instead (known gap) | ok | `HKCU\Software\7-Zip`: the real registry under soft; not saved otherwise. Since iteration 19, kept with its data, and saved in all three sandboxes ([the registry](#the-registry)) |
| Notepad++ | ok | ok | ok | data, `AppData\Roaming\Notepad++` |
| SumatraPDF | ok | ok | ok | data, `AppData\Local\SumatraPDF` (in an AppContainer, the container's folder) |
| VLC | ok | ok | ok | data, `AppData\Roaming\vlc` |
| VLC decoding a clip without a window | ok | ok | ok | |

- **No app needed a change to zigsaw.** Their recipes leave out what makes
  them write next to their executable (Notepad++'s portable marker,
  `doLocalConf.xml`): SumatraPDF falls back to AppData by itself when it
  can't write there.
- **7-Zip's file manager in an AppContainer** starts, and shows its root
  instead of the archive: it goes through the path from the drive root, and
  the container can't read the folders above what it's granted, the
  restriction that keeps Node's realpath from working there.
- **VLC** asks about privacy on its first start, in a dialog that keeps its
  window from closing, and checks for updates when it has no settings yet,
  which held up its closing by more than ten seconds once. Its recipe passes
  `--no-qt-privacy-ask --no-qt-updates-notif`.
- **The taskbar**: at low integrity and in an AppContainer, VLC's calls to
  add buttons to its taskbar button fail with `E_ACCESSDENIED`, as Explorer
  runs at medium integrity.
- Both upstream archives that publish hashes (Notepad++, VLC) had the hashes
  pinned. The four images are the same from three stores.

## The user's folders

Iteration 18, 2026-10-14, Windows 11 26300. Before giving an app the
user's Documents and the like as a directory junction in its home, the
probes checked that nothing zigsaw does to a data directory reaches
through one into the folder, and that the sandboxes treat a path through a
junction as the folder's own:

| Probe | Result |
|---|---|
| Zig 0.16's `Io.Dir.deleteTree` on a tree with a junction in it | removes the junction; the folder's files stay |
| Zig 0.16's `Dir.walk` | reports the junction as a `sym_link`, and doesn't go into it |
| Git Bash's `rm -rf` | removes the junction only |
| A low integrity label on the data directory, and an AppContainer grant of it (`SetNamedSecurityInfoW`, inherited) | change the junction's own ACL, not the folder's |
| Labelling, and granting, a folder with a junction in it that denies Everyone listing, as Windows' `Documents\My Music` | works; the junction's target is left alone; `zigsaw rm` puts both back |
| A low-integrity process through the junction | reads; writes only once the folder is labelled |
| An AppContainer process through the junction | neither reads nor writes until the folder is granted to its capability; then both |
| `SHGetKnownFolderPath` for Documents, with `home\Documents` a junction | `home\Documents`, writable, in all three sandboxes |

- `User Shell Folders` on this machine names all six folders as
  `%USERPROFILE%\<name>` (`Personal` for Documents, `My Video` for Videos,
  Downloads by its GUID), which is why a run's `USERPROFILE` moves them.
- Creating a junction needs no privilege, unlike a symbolic link, which
  needs Developer Mode or an administrator.
- So zigsaw's own deletes (`zigsaw rm --delete-data`, `prune --data`,
  `--ephemeral`) were safe as they were; `tests/sandbox.sh` now checks that
  they leave a folder's files.

In Notepad++'s Open dialog, with fake folders standing in for the user's:

- Typing `shell:Personal` goes to **Documents**, which the dialog names
  and shows as the known folder, with the fake folder's file in it, under
  `soft`, `low` and `appcontainer` alike.
- **Quick access**: the dialog's navigation pane had Home, Gallery,
  OneDrive and the drives, but none of the user's folders pinned. Its pins
  are kept in `%APPDATA%\Microsoft\Windows\Recent\AutomaticDestinations`,
  in the app's profile in a run, and the dialog only makes its file there,
  with the default pins, if the folder exists. Explorer would make the
  folder in a real profile; nothing does in an app's. Once zigsaw made it,
  the dialog pinned Downloads and Documents (the folders the app has), in
  all three sandboxes. Desktop isn't among the pane's default pins.

## The registry

Iteration 19, 2026-10-15, Windows 11 26300. Before keeping an app's keys in
`HKEY_CURRENT_USER` with its data, [`tests/regprobe.zig`](../tests/regprobe.zig)
(`zig build regprobe`; [`tests/regprobe/app.json`](../tests/regprobe/app.json)
makes an app of it) checked what that takes, without administrator rights.

At medium integrity, as zigsaw:

| Probe | Result |
|---|---|
| `RegLoadAppKey` on a file in a directory of the user's | loads it, creating `user.dat`, `.LOG1` and `.LOG2`; privately, only through the key it returns |
| The same file loaded again while it's loaded | the same hive: what one handle wrote, the other sees |
| `RegCopyTree` from an HKCU key into the hive | `ERROR_ACCESS_DENIED`, even for values alone |
| `RegCopyTree` from the hive into HKCU | works |
| Copying value by value (`RegEnumValue`, `RegSetValueEx`, subkeys through their handles), both ways | keeps every type (SZ, EXPAND_SZ, MULTI_SZ, DWORD, QWORD, BINARY), the default value and the subkeys; 2,000 values in 109 ms |
| `RegRenameKey` in HKCU | works |

In the sandboxes, a key in HKCU that zigsaw prepared, and one it didn't:

| The app, in its run | soft | low, key labelled low (inheritable) | appcontainer, key granted to the app's capability (inheritable) |
|---|---|---|---|
| reads, sets and deletes values | ok | ok | ok |
| makes a subkey (`RegCreateKeyEx` from HKCU with the whole path) | ok | ok | ok |
| makes two missing levels at once that way | ok | ok | `ERROR_ACCESS_DENIED` |
| makes two missing levels at once from a handle to the key | ok | ok | ok |
| writes a sibling key zigsaw didn't prepare | ok | denied | denied |
| reads a key zigsaw didn't prepare | ok | ok | denied |

- So zigsaw copies an app's keys value by value, and a run labels or grants
  them: in every sandbox the app can write them.
- **7-Zip 26.04's file manager**, with `HKCU\Software\7-Zip` prepared, saved
  the same settings on close in all three sandboxes: `FM` with its window's
  position, panels, list mode and folder history, and `FM\Columns`. It makes
  its keys one level at a time, so an AppContainer's limit doesn't reach it.

## .NET

Iteration 20, 2026-10-15, Windows 11 26300, with the .NET SDK 10.0.402 from
Microsoft's zip, which also has the runtime 10.0.13. This machine has .NET
SDK 10.0.303 installed too, in `C:\Program Files\dotnet`, and long paths
turned on (`LongPathsEnabled=1`).

**Licence.** Microsoft's .NET binaries for Windows come under the
[.NET Library License](https://github.com/dotnet/core/blob/main/license-information.md)
(`LICENSE.txt` in the zip), not MIT as on Linux and macOS. It allows using
any number of copies to build and test programs, and shipping its files
inside programs you develop, under conditions; but not to "publish the
software for others to copy". An image of the SDK or the runtime on a
registry would be that, so their recipes are in `recipes/no-publish/`, and
each machine builds them from Microsoft's download.

The SDK image's variables, each tried without:

| Without | What happens |
|---|---|
| `ProgramFiles(x86)` (zigsaw's runs don't pass it) | every NuGet command fails: `Value cannot be null. (Parameter 'path1')`. NuGet on .NET takes the machine-wide settings' directory from the variable `PROGRAMFILES(X86)`, or `PROGRAMFILES` |
| `DOTNET_CLI_HOME` | the CLI writes its first-use sentinel to the real `C:\Users\<you>\.dotnet` (at low integrity, refused, and the CLI stops with `UnauthorizedAccessException`), and NuGet's packages would go to the real `.nuget\packages`: both find the profile with `SHGetKnownFolderPath`, which the run's `USERPROFILE` doesn't move |
| `DOTNET_ROOT` | a program the SDK built, run with `--command`, ran on the machine's .NET (`C:\Program Files\dotnet\shared\Microsoft.NETCore.App\10.0.11`) |
| `DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK` | each first run in a fresh profile, so every build, prints "An issue was encountered verifying workloads" |

`DOTNET_GENERATE_ASPNET_CERTIFICATE=false` and
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=false` weren't tried without, as that would
change this machine (a certificate in the user's store, an entry in the
user's PATH, which this machine's own .NET first runs left three times). With
all of them, after runs under soft, low and appcontainer: the real profile's
`.dotnet` unchanged, no `.nuget`, the user's PATH and certificate store
unchanged.

| Check | soft | low | appcontainer |
|---|---|---|---|
| `dotnet new console`, `build`, `run` in a granted working directory | ok | ok | ok |
| the built program, with `--command` | ok | ok | ok |
| `dotnet --info` | ok | ok | stops at the workloads: Visual Studio's setup COM server (`{177F0C4A-...}`) refuses the container |
| a console program with a NuGet package, on the runtime image | ok | ok | ok |
| a Windows Forms form and a WPF window, on the runtime image | ok | ok | ok |

- **Builds reproduce.** The SDK, the runtime, the two programs and Pinta
  made the same images in two stores, the NuGet packages vendored afresh in
  each, PDBs included: the compiler is deterministic, and its paths are on
  `B:`. The apphost the SDK writes resources into (Pinta's icon) is the same
  too.
- **Long paths.** The SDK's deepest file is 145 characters into it, so 252
  in the default store of a user named `Test`. A store whose own path is 102
  characters long worked throughout (deploying, building, running, `dotnet
  user-jwts`), but with long paths turned on; with them off, not tried.
- **Pinta 3.1.2** looks for its icons and translations in `..\share` from
  its executable, unless it finds `Pinta.sln` two levels up (a development
  build), as its Windows build lays it out; with them next to the executable
  its own icons were all missing. Its release tarball lacks the Windows
  installer's files, among them `bundle_gtk.targets`, which its project
  imports on Windows, to copy GTK's DLLs from MSYS2. It saves an image given
  with `--file` in place in every sandbox. NuGet's audit warns that its
  Tmds.DBus 0.22.0 has a known vulnerability (GHSA-xrw6-gwf8-vvr9), in a
  D-Bus library Windows has no session bus for.

## Files

Iteration 21, 2026-10-15: Files 4.3 (`cbfb4ba5`), WinUI 3 with the Windows
App SDK 2.5.1, built with the .NET SDK 10.0.402.

**What Files' repository builds with.** Visual Studio's MSBuild, for the
solution: besides the C# projects, it has three C++ ones on Visual Studio's
v145 toolset, a launcher (with C++/WinRT and WIL from NuGet) used when Files
replaces Explorer, and COM servers replacing Windows' open and save dialogs
(ATL, which only Visual Studio has, and MIDL). Release builds use NativeAOT,
and CI makes MSIX packages. `dotnet build` of `Files.App.csproj` alone needs
none of that: the XAML compiler, the resource index and the compiled XAML
all work with the SDK image, and the C++ projects aren't references of it.

**Without a package.** A build of Files run as a plain program stopped at
each of these in turn; the recipe's patch deals with each:

| What failed | How it showed | What the patch does |
|---|---|---|
| The Windows App SDK's initialization of a packaged app | `REGDB_E_CLASSNOTREG` in a static constructor, at once | builds Files unpackaged (`WindowsPackageType=None`), with the SDK in its directory |
| `Package.Current`, `ApplicationData.Current` (about 80 uses) | they throw in a program without a package | classes of the same names in Files' namespace |
| A launch's arguments start with `Files.exe`'s own path | Files exits with 0 at once: it takes the path for a program to start | treats that as a launch from the command line, as `MainWindow` already did |
| `FileSystemWatcher` on the Libraries folder | the splash screen forever; nothing in the log | no watcher when there's no Libraries folder, as in a zigsaw run's profile |
| The UWP `ResourceLoader` in a XAML markup extension | the splash screen forever (`XamlParseException` in `MainPage`) | the Windows App SDK's `ResourceLoader` |
| `dotnet publish` leaves out `Assets` | a crash 2 s in, `0xC000027B` (only Windows Error Reporting's `Report.wer` names the error, `0x80070003`) | the recipe copies `Assets` |

Files starts its window with `_ = ActivateAsync()`, so an exception there
goes nowhere: two of the hangs above were found in a dump, with
`dotnet-dump` run with the SDK image's `dnx` (`dumpasync` for what's still
awaited, `dumpheap -type Exception` and `pe` for the exceptions). In an
AppContainer, `dotnet-stack` and `dotnet-dump collect` hang: the process's
diagnostics pipe can't be reached. A dump written from outside with
`MiniDumpWriteDump` (full memory) can be read by `dotnet-dump analyze`.

**WinRT's storage refuses an app without a package that isn't at medium
integrity.** `StorageFolder.GetFolderFromPathAsync`, from PowerShell started
at low integrity by `zigsaw-acprobe --low`:

| Path | medium | low | .NET's `Directory.EnumerateFileSystemEntries` at low |
|---|---|---|---|
| `C:\` | ok | `E_ACCESSDENIED` | ok |
| `C:\Windows` | ok | `E_ACCESSDENIED` | ok |
| the app's data directory (labelled low) | ok | `E_ACCESSDENIED` | ok |

The error says the item "is not in a location that the application has
access to (including application data folders, folders that are accessible
via capabilities, and persisted items in the StorageApplicationPermissions
lists)": the rules for a packaged app in a sandbox, with no package to grant
anything. In an AppContainer it's the same; Files' first patch, which made
its data folders `StorageFolder`s at startup, hung there.

| Files | soft | low | appcontainer |
|---|---|---|---|
| starts | ok | ok | ok |
| the drives | ok | none, and a "Welcome to Files!" dialog asking to grant a permission in Settings | the same |
| a folder given on its command line (`C:\Windows`) | ok | ok | ok |
| its data | `home\AppData\Local\Files Community` in its data directory | the same | the container's Local AppData (`...\Packages\zigsaw.<id>\AC`) |

Files lists folders with Win32, but makes each drive's entry from a
`StorageFolder`, and shows the dialog when the system drive is missing.

- **The XAML compiler crashes on an implicit conversion to a WinRT class.**
  An `implicit operator StorageFolder` on a class of Files' made it stop with
  `WMC9999: Object reference not set to an instance of an object`, followed
  by `WMC0001: Unknown type` for most of Files' XAML types.
- **Two generators aren't deterministic.** Two builds' `Files.dll` and
  `Files.App.Controls.dll` had the same types and methods, but CsWinRT's AOT
  optimizer wrote its `WinRT.*GenericHelpers` types in a different order,
  which ReadyToRun's code followed; `Files.App.Server.winmd`, written by
  CsWinRT for an authored component, had a new module ID and timestamp each
  time. The vendor step reproduced.
- **CsWinRT needs an installed Windows SDK unless it's given metadata**
  (2026-10-19). Files built here, where Visual Studio installed the Windows
  SDK 10.0.26100, but not on a machine without it. Four of Files' projects
  run `cswinrt.exe` with `-input 10.0.26100.0` (their
  `CsWinRTWindowsMetadata`, or CsWinRT's default, `TargetPlatformVersion`),
  and CsWinRT's source generator does the same for the components Files
  authors. cswinrt then reads the SDK's directory from the registry
  (`KitsRoot10`, under `Windows Kits\Installed Roots` in HKLM) and the 33
  contracts its `Platform.xml` lists; without the key it stops with "Could
  not find the Windows SDK in the registry". So the build also depended on
  which release of the SDK was installed. Microsoft.Windows.SDK.Contracts on
  NuGet has the same `.winmd` files (10.0.26100.8249's 93 match this
  machine's SDK byte for byte), and cswinrt takes a directory as `-input`. The only other use of the SDK in
  MSBuild's log is the XAML compiler's `WindowsSdkPath`, which is empty
  without the SDK; with both changed, the build made the same layer as
  before. Everything else it runs comes from NuGet packages:
  `makepri.exe`, `mt.exe` and `signtool.exe` from
  Microsoft.Windows.SDK.BuildTools, `XamlCompiler.exe` from WinUI's.
- **MSBuild's environment properties lose to a project's.** `env` set
  `RuntimeIdentifiers`, `SelfContained` and `PublishAot` in vain: Files'
  projects and publish profiles set them.
- **Files keeps running when its window closes** (`LeaveAppRunning`, on by
  default), and hands a new launch to the parked instance, which it finds by
  a semaphore named for its flavour, `Files-Dev-Instance`, in the session.
  Its open tabs are saved in its settings as they load
  (`ContinueLastSessionOnStartUp`, also on).
- **Ending `zigsaw run` rather than the app leaves the app's keys in
  HKCU,** as designed (the next run settles them): a test that killed
  `zigsaw.exe` with `timeout` left `HKCU\Software\Files Community` there.
  `tests/files.sh` ends Files instead.
- Its window was up 1.8-2.0 s after `zigsaw run`, ReadyToRun and on .NET's
  runtime image; the self-contained Debug builds of the probes took 1.0-1.4
  s. Not looked into.

## PHP extensions without MSVC

Iteration 23, 2026-10-16, Windows 11 26300, with php.net's PHP 8.5.11 x64
builds (NTS and TS, "vs17": MSVC 14.44) and their devel packs, zig 0.16.0
(clang 21.1), Visual Studio 18 Insiders (MSVC 14.44 and 14.51 side by side)
and MSYS2's GCC 16.1 with binutils 2.46. The question was whether an
extension for PHP's official Windows build can be built without MSVC.

**With zig, yes**, with what [the recipes guide](recipes.md#php) lists:
`-fms-extensions`, a header included first, one object, `-Wno-date-time`.
Each was found by a build failing, or by a test, as follows:

| Without | What happens |
|---|---|
| `-fms-extensions` | `zend_atomic.h` calls `_InterlockedExchange8`, undeclared; and `__declspec(thread)` (`TSRM_TLS`, thread-safe builds) isn't thread-local |
| `_PID_T_` | `php.h`'s `typedef int pid_t` clashes with MinGW's 64-bit one |
| `ZEND_FASTCALL` as `__vectorcall` | 340 of `php8.dll`'s exports are `__vectorcall` (`_emalloc@@8`); the link fails on all of them |
| no `HAVE_BUILTIN_CONSTANT_P` | the link fails on `_emalloc_40@@0`: the size-class allocators exist only where PHP was built with `__builtin_constant_p` |
| `_TIMEZONE_DEFINED` | `struct timezone` is defined twice (PHP's `win32/time.h`, MinGW's `time.h`); Xdebug doesn't compile |
| `zig-php.c` | Xdebug's link fails on `zend_string_equal_val@@16`, which MSVC builds inline |
| no `P_tmpdir` | Xdebug's default output directory is `\`, the current drive's root, not `C:\Windows\Temp` as in its MSVC build: 52 of its tests fail when run from `C:` (a user may write to `D:\`'s root here, so they passed there) |

**Compared with MSVC 14.44**, building the same sources with the same flags
as PHP's configure:

| | zig | MSVC 14.44 |
|---|---|---|
| A test extension: classes and custom objects, callbacks, exceptions, streams, ini, `phpinfo()`, a fatal error unwinding through its `zend_try`; NTS and TS | all 24 checks pass | the same |
| Sizes and offsets of 123 structs and fields (`zval`, `zend_class_entry`, executor globals, `php_stream`...) | | the same, but `long double`: 16 bytes, MSVC's 8, which only `zend_max_align_t` uses, to size a buffer the caller allocates |
| APCu 5.1.28's tests | 56 pass | the same |
| Xdebug 3.5.3's tests, with its own runner | 745 pass, 148 skipped | the same |
| The extension's imports | UCRT (`api-ms-win-crt-*`), as `php8.dll`'s | UCRT and `VCRUNTIME140.dll` |

Xdebug's `remote_log-win` test passes only when
`C:\Windows\Temp\remote-log-win.txt` isn't there yet: it deletes its log
while Xdebug has it open, so the file stays, and the next run finds it.

**PHP checks the linker.** It refuses an extension whose PE header says a
newer linker than its own: "Can't load module ... as it's linked with 14.51,
but the core is linked with 14.44". MSVC builds of extensions need the
Visual Studio PHP was built with, or an older one; Visual Studio 18's
default toolset makes extensions PHP 8.5 refuses. lld writes 14.0, which
passes.

**GCC and GNU ld don't fit.** GCC has no `__vectorcall`; for PHP's
`ZEND_FASTCALL` functions on x64 it's the plain Microsoft ABI with another
name, so an import library mapping each name to `name@@bytes` links. Two more
MSVC intrinsics need stand-ins (`__assume`, the 8-bit `_Interlocked*`). GNU
ld writes linker version 2.46, which PHP refuses, and has no option to
change it; with the two bytes patched to 14.0 the test extension passes.
But GCC takes `__declspec(thread)` for an attribute it doesn't know, with a
warning, so a thread-safe extension's `TSRMLS_CACHE` would be one variable
for all threads.

**Running PHP.** php.net's build reads the `php.ini` that `PHPRC` names,
which PHP's documentation puts before those that keys under
`HKLM\SOFTWARE\PHP` name, its own directory's and Windows' directory's (the
keys weren't tried: writing them takes an administrator). Its default
`extension_dir` is `C:\php\ext`. `${VAR}` in a
`php.ini` value, quoted or not, is the environment variable, and
`PHP_INI_SCAN_DIR` takes several directories, separated by `;`. HTTPS through
streams checks with Windows' certificate stores; curl's OpenSSL has no
certificates unless told (`curl.cainfo`), or per request
(`CURLSSLOPT_NATIVE_CA`). PHP runs under the three sandboxes, finding the
Visual C++ runtime in System32, and loads extensions from other images'
directories. Xdebug's step debugger reaches a client on `127.0.0.1` under
`soft` and `low`, not in an AppContainer.

`run-tests.php` reads `TEST_PHP_ARGS` as options of its own as well as
passing them on, so an extension given in both loads twice ("Module is
already loaded"); and for a test path that doesn't exist it runs nothing,
and passes.

### With the libraries PHP ships

Iteration 24, 2026-10-16, the same PHP, zig and Visual Studio. The question
was how extensions that need PHP's third-party libraries can build.

- **PHP ships its libraries two ways.** `php8.dll` has zlib, libxml2 and
  libiconv linked in, and exports their functions (44 of zlib's, about
  1440 `xml*`/`html*`, `libiconv*`), as PHP has zlib, libxml and iconv
  built in. OpenSSL 3.5.8, libssh2 1.11.1, SQLite, libsodium 1.0.22,
  nghttp2 1.70, libpq 16.15, ICU 77.1, brotli, GLib 2.88.3, enchant and
  Cyrus SASL are DLLs beside `php.exe`.
- **Their headers and import libraries are php.net's deps packages**
  (`downloads.php.net/~windows/php-sdk/deps/vs17/x64/`), versioned zips
  that stay up once replaced; the series file for 8.5 names exactly the
  versions PHP 8.5.11 has. Every DLL in those packages that PHP's zip has
  is the same file, byte for byte. Their static libraries are plain COFF
  (no `/GL`). libxml2's headers include `iconv.h`.
- **zig links with MSVC's import libraries** (`libssh2.lib`,
  `libcrypto.lib`) as with its own, and with `php8.lib` for what
  `php8.dll` exports, so `zlib_a.lib`, which PHP's build links into
  extensions, isn't needed.
- **Extensions built that way pass what their MSVC 14.44 builds pass**,
  built from the same sources, run the same way:

| | zig | MSVC 14.44 |
|---|---|---|
| Xdebug 3.5.3 with compression (zlib), its tests | 744 pass | the same |
| igbinary 3.2.17RC1's tests | 134 pass, 17 skipped | the same |
| ssh2 1.5.0's tests, against an SSH server in Go (`tests/php/servers`) | 14 of 15 (not `ssh2_send_signal`: bash and `SIGINT`) | the same |
| PhpRedis 6.3.0 with igbinary, each of `Redis_Test`'s tests against miniredis | 108 pass, 46 fail, 98 skipped | the same, test by test |

- **What `config.w32`s needed** beyond iteration 23's stand-ins:
  `get_define("PHPDLL")` (igbinary picks its sources by it); configure's
  `PHP_PHP_BUILD` search; the official `SETUP_OPENSSL`; and calls to
  undeclared functions, which MSVC warns of (C4013) and clang makes an
  error: redis calls PHP's `usleep` and `gettimeofday` without
  `win32/time.h`. igbinary 3.2.16 includes `php_smart_string.h`, which PHP
  8.5 removed; 3.2.17RC1, which PECL marks stable, is the one for 8.5. It
  also tests `_MSC_VER` to mean Windows (its `stdint.h` branch and
  byte swapping), which clang doesn't define; its recipe patches the two
  tests.
- **An extension that links with another extension's DLL** (redis with
  igbinary's serializer imports `igbinary_serialize` from
  `php_igbinary.dll`, as PHP's in-tree builds make it) loads only if PHP
  loaded the other first: Windows matches the import to the loaded
  module by name. Loaded the other way round, or without it, PHP says only
  "The specified module could not be found".
- **PHP's extension build id** is "API20250925,NTS,VS17" (`php -i`, "PHP
  Extension Build"), which PHP checks extensions against, and which PHP's
  extension point takes as its version.

### With libraries PHP doesn't ship

Iteration 25, 2026-10-16. The question was whether an extension's recipe
can build the library it needs with zig, and get what php.net's own builds
get.

- **PhpRedis can't have zstd, lz4 or lzf on Windows**: its `config.w32`
  has no option for them, only `config.m4`. So the proofs were PECL's yaml
  2.3.0 (libyaml) and zstd 0.18.0 (libzstd, which it can also take from a
  copy it bundles), which php.net builds for Windows too.
- **libyaml 0.2.5's release tarball can't be built with CMake**: it has
  the `CMakeLists.txt` but not the templates it reads
  (`cmake/config.h.in`, `yamlConfig.cmake.in`). GitHub's archive of the tag
  has them. CMake 4 also needs `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`, as the
  project asks for 3.0.
- **configure's `CHECK_LIB` returns where it found the library**, not
  true: yaml's `config.w32` reads the name to know whether it's static
  (`_a.lib`), and so whether to define `YAML_DECLARE_STATIC`.
- **Built with zig and linked in statically, they pass what php.net's DLLs
  pass**, the same tests, run the same way with the SDK's PHP:

| | zig, with the recipe's library | php.net's build |
|---|---|---|
| yaml 2.3.0, its tests | 76 pass | the same |
| zstd 0.18.0, its tests | 61 pass, 5 skipped | the same |

### PHP's `is_writable()` at low integrity

At low integrity, `is_writable()` and `is_writeable()` are false for every
file and directory, even those the process can write: those labelled low,
as zigsaw labels a run's data and writable grants, and its `TEMP`. Writing
to them works. PHP's Windows access check (`tsrm_win32_access` in
`TSRM/tsrm_win32.c`) asks `GetFileSecurityW` for the owner, group and DACL,
but not the integrity label (`LABEL_SECURITY_INFORMATION`), and
`AccessCheck`, given a security descriptor without one, takes the object as
medium integrity, which a low-integrity token may not write to. Asking for
the label too would fix it. Code that checks before writing refuses:
Kanboard won't start ("The directory ... must be writeable by your web
server user"), and checks its files and plugins directories the same way.
Composer, which doesn't, installs at low.

### Composer and Kanboard

- **Kanboard's release tarball leaves out `composer.json` and
  `composer.lock`** (`export-ignore`), and has the dependencies installed in
  `vendor\` instead. The recipe takes the two files from the tag's commit,
  and its vendor step installs from the lock file: 18 packages in 30 s, 16 s
  from Composer's cache, the same files both ways, and the same again in a
  store that had none of it.
- **Composer's install is the same code as Kanboard's own `vendor\`**: every
  file both have is the same, byte for byte, but Composer's own (`autoload.php`
  and `composer\`: the class name it gives the autoloader, and the class map,
  which lists Kanboard's tests, which upstream installed from its full tree).
  It keeps 41 files upstream's leaves out: each package's `composer.json`,
  `README.md` and `.gitignore`, and a few tests.
- **PHP's built-in web server ignores `.htaccess` and `web.config`**, which
  keep Kanboard's `app\` and `data\` from the web; its recipe adds a router
  that refuses `app\`, `libs\`, `vendor\` and `cli`. Its data isn't under
  the served directory.
- **A browser started from a run would be in the run's job**, and end with
  the server: Explorer, given the address, has the shell's own process open
  it, outside the run.
- **Composer finds what's on the run's PATH**: `diagnose` reports "7-Zip
  present (7z)" in a store where 7-Zip's image is installed, through its
  export.

## Projects with their own recipe

- **zigsaw builds itself to the same bytes.** `zigsaw build` in this
  checkout runs `zig build -Dstrip` in `B:\src\zigsaw`, with zig's image,
  and its three programs are the same bytes as a `zig build -Dstrip` of the
  checkout where it is, as `-Dstrip` leaves out the debug information that
  would name the directory. So are the programs of the release package
  that scripts/package.sh makes, when that package's own zigsaw builds the
  checkout.
- **It takes about 2.5 minutes in a fresh store, a minute after that**:
  157 s for the build, plus 30 s to pull zig's image the first time; 67 s
  once zig's `${cache}` has what zig builds once for the target, the rest
  being zig compiling zigsaw, whose own cache (`.zig-cache`) is fresh in
  each build. With nothing changed, `zigsaw build` takes the image built
  before, in under a second.
- **Kept, `.zig-cache` saves zigsaw's build little** (iteration 35): after
  a change to one of zigsaw's messages, 51 s in the work directory the last
  build left, against 60 s for the same files in a new one (zig's
  `${cache}` warm both times). zig compiles `zigsaw.exe` as one unit, so
  any change to it is compiled whole; what's kept is the build runner and
  the two shims. A project of many objects (C, with make, ninja or cargo)
  keeps more. The incremental build's three programs are the bytes of a
  `--clean` build and of a plain `zig build -Dstrip`.
- **Taking the files is quick**: zigsaw's 52 files in 10 to 35 ms, read
  and hashed, which every `zigsaw build` does, even when it then takes the
  image built before.
- **git agrees.** A fixture with nested `.gitignore` files, `!`, an
  anchored pattern, `**`, an upper-case `X.LOG` that `*.log` ignores, a
  file name with a space and an empty directory gives the same files as
  `git ls-files -co --exclude-standard` in it, git ignoring case too, as a
  repository it makes on Windows has `core.ignorecase`.
- **Windows reports junctions and symbolic links alike**, as reparse
  points, which Zig's directory iterator gives as links before it looks at
  whether they're directories, so a walk doesn't enter a junction by
  mistake.

## Zig's packages, and ZLS

- **zig 0.16 unpacks a project's packages into `zig-pkg`**, beside its
  `build.zig.zon`, one directory per package hash, and keeps a compressed
  copy of each (`p\<hash>.tar.gz`) in its global cache. Only the unpacked
  ones serve `--system <pkgdir>`: pointed at a global cache's `p`, it
  reports every package "not found". In a build, the global cache is zig's
  tool cache (`${cache}`), which builds keep, so a vendor step must pin
  `zig-pkg`, or a warm store would build what a fresh one can't.
- **ZLS 0.16.1 builds offline from it.** Its vendor step (three packages)
  took under 40 s, zig's image pulled first; the build 1.5 minutes. It made
  the same image built again, and in a new store, where the step fetched
  the packages again.
- **zig as ZLS's runtime is enough.** A runtime is on the build's PATH too,
  so zig needn't be listed in the SDK as well (zigsaw refuses one alias for
  both). With `${zig}` on its PATH, ZLS found `zig.exe` and zig's library,
  and ran the project's `build.zig` with it to learn the modules it
  declares, in about 10 s with zig's caches cold, in soft, low and
  AppContainer runs alike.
- **The session is interactive through zigsaw.** ZLS's replies arrive as
  it writes them (under 0.1 s for a hover) through `zigsaw run` and through
  its shim, both passing stdin and stdout straight through, so an editor
  can hold a session with it.
- **ZLS publishes diagnostics only to clients that say they take them**
  (`textDocument.publishDiagnostics` in `initialize`'s capabilities).
- **On Windows Server 2025, ZLS in an AppContainer finds neither zig's
  library nor a project's modules** (iteration 34's Reproduce run). There,
  Windows still denies an AppContainer the Mount Manager, and so
  `GetFinalPathNameByHandle` with drive letters (the probe's
  `self-path-dos`), and `zig env` fails, as the matrix's zig gap does: ZLS
  asks zig for its library, and runs `build.zig` with it. Hover answers
  `null`; syntax errors are still reported, as ZLS parses files itself.
  [`tests/zls.sh`](../tests/zls.sh) counts those two checks as a known gap
  where the probe finds that cause, as the matrix does.

## GTK 3 and Gnumeric

- **GTK 3 needs nothing GTK 4's SDK doesn't have, but ATK.** GTK 3.24.52
  and ATK (at-spi2-core 2.60.7 with `-Datk_only=true`) build with Meson
  and zig against GTK 4's SDK in about 3 minutes; GTK 3's runtime is 18 MB
  compressed, besides GTK 4's 52 MB, which every GTK app shares.
- **GTK 3 took a missing Desktop for a folder at the path NULL.** Windows
  gives no Desktop to a run that isn't granted it, and
  `g_get_user_special_dir()` returns NULL then; GTK 3's file chooser, places
  sidebar and file button compared that with the home directory, found it
  different, and went on to `g_file_new_for_path (NULL)`: critical warnings,
  in the widget factory among others. GTK 4 checks.
- **zig's `cc` ignores `-mwindows`** (it warns that the argument is
  unused), so Gnumeric, which links with it, was a console program;
  `-Wl,--subsystem,windows` works. It takes `-Wl,--export-all-symbols` and
  ignores it too: a DLL exports what's marked `dllexport`, or everything
  when nothing is, as with GNU ld's default, but not everything when
  something is, as GNU ld does with the option.
- **Autoconf's `configure` under BusyBox finds no program by name.** It
  chose `:` to separate PATH, as BusyBox's sh doesn't show it `;` where it
  looks, and split `D:\...` at the drive's colon; and it looks for
  `pkg-config`, not `pkg-config.exe`, as `ac_executable_extensions` is
  empty. enchant and gettext had been given every program by name
  (`PKG_CONFIG` and the rest), which hid it. `PATH_SEPARATOR=;` and
  `ac_executable_extensions=.exe` fix both.
- **BusyBox's make (pdpmake)** expands GNU make's `$(shell ...)` to nothing
  (POSIX 2024's `VAR != command` works, with `\#` in it), has no pattern
  rules, and sets `$<` in a rule that isn't an inference rule to a
  prerequisite that's out of date, which can be `Makefile`, where GNU make
  gives the first. intltool's `po` Makefile lists its catalogs with
  `$(shell ...)`: Gnumeric built and installed no translation at first, and
  said nothing.
- **BusyBox's sh runs `#!/usr/bin/perl` scripts** with the `perl` on PATH,
  but not ones whose `#!` line names a drive (`Exec format error`), which
  is what intltool's `configure` writes.
- **Strawberry Perl reads files as text** unless a script says otherwise:
  goffice's script that embeds images in its library dropped the carriage
  returns from a PNG, which GdkPixbuf then couldn't load (a critical warning
  in every run). `PERLIO=perlio` makes it read as Perl on Unix does.
- **Perl's image couldn't load XML::Parser**, nor 39 other DLLs Strawberry
  Perl's XS modules need (`c\bin\*__.dll`): its cleanup left out the whole
  of `c`, Strawberry's GCC, where they are. They're now beside `perl.exe`
  (29 MB more).
- **Gnumeric 1.12.62's own build for Windows doesn't link as released.**
  Its library exports what a script reads from a list of its headers,
  which misses the analysis tools' new headers that `ssconvert` uses,
  `complex.h`, and functions with an array parameter of a given size, which
  the script's pattern doesn't read (`sheet_style_apply_border`, which the
  Excel plugin calls): MSYS2's package leaves the Excel plugin out. Its
  Applix plugin calls an exporter whose code isn't in the release, which
  Linux's dynamic linking lets pass. It calls
  `g_option_context_set_delocalize`, which GLib doesn't have. Without the
  list, lld exports everything, which links everything.
- **An SDK's headers can put the store's path into what's built.** GTK 3
  built in a second store differed in one file, `libgtk-3-0.dll`: it holds
  the path of a GLib header, `gobjectnotifyqueue.c`, which GTK includes and
  whose `g_return_if_fail` names its own file with `__FILE__`, and GTK 4's
  SDK, where the header is, is deployed under the store's path. GTK 4's SDK
  didn't have it, as its own GLib was in `B:\prefix` while it built. GTK 3's
  recipe maps the SDK's directory to a fixed name
  (`-fmacro-prefix-map`); builds don't otherwise see their SDKs at fixed
  paths, as they do their own sources and prefix.
- **Building Gnumeric takes 16 to 24 minutes**, of which libtool's links
  under BusyBox are much: its 37 plugins link one directory at a time.
  Its image is 15 MB compressed, 8.6 MB of it translations.

## Introspection, PyGObject and Meld

- **gobject-introspection's scanner assumes MSVC or MSYS2 on Windows.**
  With zig's `cc` it took distutils' default compiler, `msvc`; with
  `MSYSTEM` set it chose MinGW, but linked its dumper through a temporary
  shell script it runs with `which($SHELL or sh.exe)`, and a build's PATH
  has no `sh.exe`. It looked for import libraries only where the compiler
  searches by itself, which isn't the SDK's `lib` for zig, and linked them
  as `-lfoo`, which zig's `cc` doesn't take for `libfoo.dll.a`. A patch to
  `giscanner/ccompiler.py` fixes the four
  ([`gobject-introspection.patch`](../recipes/gtk4-sdk/gobject-introspection.patch)).
- **With LLVM's `dlltool`, the scanner finds the DLL behind an import
  library with `nm`**, the archive's member names. zig has no `nm`;
  [`nm.c`](../recipes/gtk4-sdk/nm.c) prints what GNU nm does for COFF
  objects, archives and short import members (60 of 60 comparisons the same
  under `LC_ALL=C`, besides the symbols bfd makes up when it turns short
  import members into long ones). Within GTK's SDK's own build, Rust's
  `dlltool` alias (GNU's) is on PATH, and the scanner uses
  `dlltool --identify` there; both give the same names.
- **On a subst drive, the scanner left out what generated headers
  declare.** Its Python side resolves the files it scans with
  `os.path.realpath`, which on Windows follows subst drives (`B:` to the
  build directory); its lexer resolves the preprocessor's line markers with
  `GetFullPathName`, which doesn't. A generated header the preprocessor
  named relatively (`./gdk-pixbuf/gdk-pixbuf-enum-types.h`) then wasn't one
  of the scanned files, and its declarations were dropped without a word:
  no enum in Pango's, GdkPixbuf's, GDK's or GTK's GIRs had its GType, and
  `Gtk.get_major_version` was missing. The lexer now resolves as `realpath`
  does (`GetFinalPathNameByHandle`). The first GTK SDK of this iteration
  was built without that, and showed it only in the GIRs' contents.
- **GI's build needs flex and bison.** winflexbison's sources build with
  MSVC only (its CMake refuses others, and its m4 and gnulib code assumes
  MSVC's headers), so its release's programs are a pinned download, on
  PATH for GI's build only.
- **CPython extensions build with zig against python.org's Python**:
  NuGet's `python` package is the embeddable zip's build with `include`
  and `libs\python314.lib`, and `pyconfig.h` defines `MS_WIN64` for
  `__MINGW32__`, which zig defines. pycairo and PyGObject build with Meson
  given `-Dpython=` the NuGet `python.exe` (Meson's own Python, the
  embeddable one, has no headers).
- **Python since 3.8 doesn't load DLLs from PATH for extensions or ctypes**:
  PyGObject adds the directories in `PYGI_DLL_PATH` with
  `os.add_dll_directory()` when `gi` is imported. GLib still loads a
  typelib's DLL with `LoadLibrary`, which searches PATH: Meld's own
  GtkSourceView wasn't found until its `bin` was on its PATH.
- **`ctypes.cdll[name]` raises `AttributeError`, not `OSError`, for a DLL
  it can't load**, and passes a Python `str` as a `wchar_t *`. Meld's
  Windows code expects `FileNotFoundError` from it and passes `str` to
  libintl's `bindtextdomain`: its UI files weren't translated (libintl took
  the path for `D`) though its Python strings were.
- **In an AppContainer, Python's multiprocessing can't make its pipes**:
  named pipes there must be under `\\.\pipe\LOCAL\`, and multiprocessing
  names them `\\.\pipe\pyc-...` (`PermissionError`, and Meld compared
  nothing). Under `LOCAL\` they work in every sandbox.
- **Meld forces `PANGOCAIRO_BACKEND=fontconfig` on Windows**: GTK's Pango has
  only its Win32 font map, logs a critical warning for the unknown backend
  and gives no font map, and Meld never draws. Its image sets `win32`.
- **gnome.post_install runs `update-desktop-database`**, which a Windows
  build doesn't have, and fails the install.
- **Times and sizes.** GTK's SDK takes 31 minutes with introspection (26
  before): gobject-introspection, GLib's second build and each library's
  scanner. Its layer is 94 MB compressed (73 before), with Python and the
  GIRs; the typelibs add 1.2 MB to GTK's runtime (53.6 MB) and 0.3 MB to
  GTK 3's (18.7 MB). PyGObject's runtime is 15 MB compressed, nearly all
  Python's; Meld's own layer is 2.2 MB, GtkSourceView included, and builds
  in about a minute.

## GTK's extension point and Gaphor

- **GLib reads `XDG_DATA_DIRS` on Windows too, and it replaces the
  defaults.** Unset, a run's system data directories were `C:\ProgramData`,
  `C:\Users\Public\Documents`, the program's `share` and GLib's (the
  runtime's), and the `share` next to whichever DLL asks (GLib on Windows
  passes the caller's address). Set to the runtime's `share` and an
  extension's, they were exactly those two: GTK's icon theme searched both
  (an SVG in the extension's `share\icons\hicolor` was found, Adwaita's
  icons still were), the runtime's schemas were still found, and enchant's
  hunspell provider found the extension's `share\hunspell` dictionaries,
  with the runtime's en_US still from beside enchant (its relocatable
  prefix). That's what the extension point joins.
- **enchant takes a language-only dictionary for a region's tag**:
  LibreOffice's French is `fr.aff`/`fr.dic`, and a request for `fr_FR`
  gets it ("default fr: hunspell").
- **Gaphor looks its settings schema up non-recursively** (`lookup(id,
  False)`), in the first schema source only: GLib makes that
  `GSETTINGS_SCHEMA_DIR`'s, else the user data directory's, else the first
  system data directory's. With its `share` joined last, its settings
  weren't saved, though its self-test, which looks recursively, passed.
- **Under AppContainer, Python 3.13+ can't write in the directories
  `tempfile` makes.** `os.mkdir(path, 0o700)` gives the directory a
  protected ACL (SYSTEM, Administrators, OWNER RIGHTS), with no entry for
  the container's capability SID, so the container makes it and then is
  refused in it. pydot's vendored `tempfile` retries the name 10,000 times
  on `PermissionError`, so Gaphor's auto layout hung rather than failing.
  At low integrity it works (the owner has access, and the label is
  inherited).
- **pip in a vendor step**: PyGObject's SDK's Python (NuGet's package) has
  pip 26.2.1. `pip download --only-binary=:all: --platform win_amd64
  --python-version 3.14 --implementation cp --require-hashes` with every
  package listed fetched the same 16 wheels again in a new store, to the
  same hash. The first `python` on a build's PATH is Meson's, without pip;
  the SDK's `python3.exe` is PyGObject's. `pip install --target` makes
  launchers (`gaphor.exe`, `pybabel.exe`, dulwich's scripts) naming that
  Python's path in the store, and lists their hashes in each package's
  `RECORD`: removing the launchers wasn't enough for the image to be the
  same in two stores; removing their `RECORD` lines was.
- **`gi.events`, PyGObject's asyncio loop, works on Windows** (3.58.1), as
  Gaphor's own Windows builds need: `GLibEventLoopPolicy` and asyncio's
  `socketpair` work in every sandbox.
- **Graphviz 16.1.0 builds with CMake and zig as it is**, statically
  (`BUILD_SHARED_LIBS=OFF`, which links its plugins into `dot`, with no
  plugin configuration file), in 261 steps, with flex and bison from
  winflexbison. `dot.exe` imports only KERNEL32 and the UCRT; without git,
  its build date is "0". Its release tarball has no CMake files; GitLab's
  tarball of the tag has a link to a file that isn't in it.

## One build of each runtime, and git for Meld

- **A green Reproduce run doesn't mean every pin is published.** Iteration
  29's run passed, but the PyGObject SDK it pinned (`3498644a`) had never
  been pushed: ghcr.io still had iteration 28's. Gaphor, Meld and
  PyGObject's runtime pin it, and CI skips all three. `scripts/check-pins.sh`
  now looks every pin in the published recipes up on the registry.
- **Python's embeddable distribution has the same AppContainer gaps as
  PyGObject's Python**: `tempfile`'s directories (Permission denied on the
  first file) and multiprocessing's pipes (`WinError 5` making a Queue).
  Soft and low runs were fine.
- **Embeddable Python runs `site`, and so `sitecustomize.py`, only with
  `import site` in its `._pth`.** Turned on, `sys.path` stayed the same;
  `site` also enables the user site directory (`%APPDATA%\Python\...`, in a
  run the app's data), which is added only if it exists.
- **One loader loads every module of a zipped standard library.** The pipe
  fix replaced `exec_module` on `multiprocessing.connection`'s loader. With
  the standard library as files (PyGObject's runtime) each module has its
  own; with `python314.zip` it's the zip's one `zipimporter`, so every
  module loaded after it ran the fix's code too and failed
  (`multiprocessing.util` has no `arbitrary_address`): multiprocessing broke
  in every sandbox. The fix now wraps the loader in an object of its own.
- **A module without build commands may replace a file an earlier module
  placed**: Python's `site` module puts its `python314._pth` over the zip's,
  and the layer has the second.
- **Meld starts git with its window hidden** (`STARTF_USESHOWWINDOW`, for
  every version control call), so no console shows from `pythonw.exe`. With
  MinGit's image as a runtime, Meld's git support found a repository and
  its changed and new files in every sandbox, including git refreshing its
  index in a repository labelled low.

## Java

Iteration 31, 2026-10-19, Windows 11 26300, with Eclipse Temurin's builds
of OpenJDK 25: 25.0.4.1+1 (the latest release that day) and 25.0.5+7, an
early-access build of the update due on 2026-10-20.

**Where Java's programs look**, from a probe (`java Probe.java` with the
JDK's image, and compiled on the JRE's):

| | soft | low | appcontainer |
|---|---|---|---|
| `user.home`, without settings | your real profile (`SHGetKnownFolderPath(FOLDERID_Profile)`, `java_props_md.c`) | the same, read-only | the same, unreadable |
| `user.home`, with `JAVA_TOOL_OPTIONS="-Duser.home=..."` (quoted: the store's path may have spaces) | the app's data's `home` | the same | the same |
| `java.io.tmpdir` | the data's TEMP | the same | the container's Temp in data |
| `java.util.prefs` (`HKCU\Software\JavaSoft\Prefs`) | the real registry | "Could not create windows registry node", `BackingStoreException` | `SecurityException`: the root key is denied |
| `hsperfdata` (what `jps` and `jcmd` find JVMs by) | in TEMP | in TEMP | not made |
| A Swing window that draws, closed by itself | ok, Direct3D | ok, Direct3D | ok, Direct3D |

- **Temurin's JDK and JRE carry their C runtime** (`vcruntime140.dll`,
  `vcruntime140_1.dll`, `msvcp140.dll`, `ucrtbase.dll` and the
  `api-ms-win-*` forwarders), so nothing needs installing, unlike PHP's
  build. The JRE has 42 modules (`java.desktop`, `jdk.unsupported`,
  `jdk.localedata`...), the JDK 62 (with `jdk.compiler`).
- **`Path.toRealPath()` fails for every path in an AppContainer.** On
  Windows it calls `FindFirstFile` on each directory from the drive root
  down, which needs the root listed, and no drive root here lets
  application packages list it (`C:\Windows` fails as well as the store).
  JDK 25 used it in two places a program meets early:
  - Loading `conf\security\java.security`, since security properties files
    may include others (JDK 24): any hash, signature or TLS, and
    `Files.createTempFile` (its `SecureRandom`), failed with "Error
    loading java.security file". This is JDK-8352728, fixed in 25.0.5;
    25.0.4.1 has it.
  - Its HarfBuzz binding through the foreign function interface: the
    lookup of the C runtime (`ucrtbase.dll`) resolves its path with
    `toRealPath`, finds nothing, and laying out text fails
    (`ExceptionInInitializerError` in `HBShaper`): PlantUML's class
    diagrams in 25.0.5 too. `-Dsun.font.layout.ffm=false` uses the JNI
    binding, which works; both images set it.
- **`File.getCanonicalPath()` resolves a `subst` drive** (and so the build
  drive `B:`) to its target, while `toRealPath` and `getAbsolutePath` keep
  it. Maven's `-pl app` compares canonical paths with the reactor's own,
  which aren't: "Could not find the selected project in the reactor"
  (`-pl :pdfbox-app` works). Gradle's reports name the build directory's real
  path. Neither changed what the builds made: every image was the same in
  two stores.
- **The launchers.** Maven 3.10 refuses to start without
  `maven.multiModuleProjectDirectory`, which `mvn.cmd` sets from the nearest
  `.mvn`; Gradle 9.8.1's `gradle.bat` starts its `gradle-cli-main` jar with
  an instrumentation agent. Both images start `java.exe` themselves, as
  aliases must (they can't be batch files).
- **Vendoring Maven**: running the build with the local repository in the
  module, then deleting `_remote.repositories`, `*.lastUpdated`,
  `resolver-status.properties` and `maven-metadata-*.xml`, made the same
  files in runs in two stores, and the offline build took them as installed.
  PDFBox's vendor step takes 90 s, the build 40 s. Not over time, though
  (iteration 32): Maven 3.10 also writes the prefix list it fetches from
  each repository into `.meta/prefixes-<repository>.txt`, which Central
  regenerates; two local runs agreed, CI's run hours later didn't (it also
  got one for apache.snapshots). Vendor steps now delete `.meta`
  too; that was the only difference between the old and new vendor trees.
- **Logisim-evolution's Gradle build offline** (iteration 32): a Kotlin
  build script with the configuration cache on, three plugin-portal plugins
  (Shadow 9.6.1, SonarQube 7.5, Versions 0.61), Checkstyle resolved while
  configuring, and a second source set run during the build: 350 files
  vendored, built offline the first time, the same image in two stores
  (the second vendored from the network again). Its `genBuildInfo` writes
  `new Date()` and that date in the JVM's time zone into the program; the
  recipe sets the tag's commit time in UTC.
- **Vendoring Gradle**: its `files-2.1` cache, copied into Maven's layout,
  served the fixture's settings plugin (from the plugin portal) and
  PlantUML's plugins (git-properties, TeaVM, and `kotlin-dsl` for its
  included build) offline, the same files in two runs. PlantUML's vendor step
  takes 3 minutes, the build 2.
- **PlantUML carries Graphviz**: its jar has `graphviz.dat`, a small
  Windows build of `dot` 2.44.1, which it unpacks into `%TEMP%\_graphviz`
  and uses when no other `dot` is set (`GRAPHVIZ_DOT`, or on PATH). Its
  local builds keep `$version$` in place of their version until
  `patchCompilationInfo`, which upstream's CI runs, fills it.
- **Two zigsaw bugs in keeping registry keys**, found by Java's deep
  preferences keys, both fixed in 0.31.0:
  - Taking a key back deleted every empty key above it, up to `Software`,
    as if zigsaw had made them all. PDFBox keeps
    `Software\JavaSoft\Prefs\org\apache\pdfbox`; after its run, this
    machine's own (empty) `HKCU\Software\JavaSoft\Prefs`, there since
    February, and then `JavaSoft` were gone. zigsaw now records the
    outermost key it made above the kept one, and deletes no further.
  - In an AppContainer, Java opens `Software\JavaSoft\Prefs` and each key
    below it before the app's own, read-only when it may not create keys
    there; the container could open none, so Preferences threw and PDFBox's
    debugger and PlantUML's window never appeared. AppContainer runs now get
    read access to the keys above an app's kept keys (each key itself, not
    those in it), taken back with the keys.

  With both, the debugger kept its window and the files it opened in its
  hive, from soft, low and AppContainer runs alike, and `Prefs` was left as
  it was.
- **archive.apache.org, downloads.apache.org and repository.apache.org
  didn't answer here** (connections timed out), while dlcdn.apache.org and
  Maven Central did. Maven's and PDFBox's recipes download from Maven
  Central, which keeps every release; Apache's parent POM names
  repository.apache.org's snapshots, which costs Maven builds a timeout
  warning.
- **JavaFX, in Scene Builder** (iteration 33):
  - Temurin's JRE has no `jdk.unsupported.desktop`, which `javafx.swing`
    requires, so a JavaFX app with Swing interop can't start on it
    (`FindException` before `main`). The JDK's image has it; it pulls
    about 33 MB more than the JRE's (88 MB against 55).
  - `maven-compiler-plugin` 3.13.0 fails on a project compiled for Java 24
    or newer that has a `module-info.java`: after compiling, it rewrites
    `module-info.class` with ASM 9.7, which reads class files up to Java 23
    (`Unsupported class file major version 68`). 3.14.1 has ASM 9.8.
  - JavaFX's native libraries load from the `bin` folder beside its jars
    (`../bin` on Windows) before it unpacks them from the jars into
    `user.home\.openjfx\cache`; with Gluon's SDK nothing is unpacked.
    Direct3D 9Ex worked in soft, low and AppContainer runs alike.
- **A Maven build that depends on the time zone** (iteration 34): Scene
  Builder made the same image twice here (UTC+7) but another on CI's
  runner (UTC), the files differing only in its jar with dependencies.
  maven-shade-plugin 3.2.4 copies each dependency's entries with their own
  times; for jars that also store them in UTC (an extended timestamp:
  Woodstox, stax2, MSV, a JAXB jar), it writes them in the JVM's time zone,
  so 1,224 of 6,237 entries came out 7 hours apart. With the build's JVM on
  UTC (`JDK_JAVA_OPTIONS=-Duser.timezone=UTC`), this machine makes the
  runner's image. `project.build.outputTimestamp` doesn't reach them:
  shade only honours it from 3.3.0. PDFBox, PlantUML and Logisim-evolution
  made the same images on both. A second store on the same machine can't
  catch this; only another time zone can.

## Other findings

- **Microsoft Defender quarantines zigsaw 0.19.0.** During a build of
  Files, it reported `Trojan:Win32/Bearfoos.A!ml` for the running
  `zigsaw.exe` (a copy in a scratch directory), ended it and quarantined the
  file; five minutes later it quarantined two copies of the same build, the
  one in `zig-out\bin` among them. `!ml` is its machine-learning detection,
  not a signature. The same build had run on this machine all day,
  including the .NET builds; what set it off isn't known. Restoring the file from quarantine
  allowed it again.

  Looked into in iteration 22. The flagged build was a development one, with
  debug information (`b9b5923c…`, 2.7 MB), not a release: the programs of
  every release from 0.18.0 to 0.21.0 scan clean (`MpCmdRun -Scan -ScanType
  3 -File <exe> -DisableRemediation`, which works without admin rights), and
  0.19.0's release was never flagged. Defender flagged the running process
  first (`DidThreatExecute`), and then identical copies as they were opened,
  so it judged what the program did and then spread that verdict to its
  bytes. Restoring the file had also set `Bearfoos.A!ml` to "allow" on this
  machine (`Get-MpPreference`, `ThreatIDDefaultAction_Ids`), so a local
  scan can no longer say whether any build would be flagged: it reports
  clean for that detection whatever the file. Undoing that needs admin
  rights.

  zigsaw's programs had neither version information nor an application
  manifest, which machine-learning detectors weigh against unknown,
  unsigned programs. From 0.22.0 they have both (`src/windows/`): the
  version, the author and the licence, as Explorer's Properties show them,
  and a manifest that runs them as the user who starts them. Task Manager
  names a process by its description, so the descriptions are short:
  "zigsaw", "zigsaw command shim". The programs stay the same bytes from any
  checkout. Whether this keeps Defender quiet can't be shown from here.
  Reporting the false positive to Microsoft, with the flagged file, is a
  form only its author can send.

- **v0.18.0's programs are built for the CPU of GitHub's runner.**
  `build.zig` set only the target's OS, so Zig compiled for the CPU of the
  machine that built them: the released `zigsaw.exe` has 18,697 AVX2
  instructions, the SHA extensions' (`sha256rnds2`) and BMI2's. A build of
  the tag here is deterministic, but differs (2,354,688 bytes released,
  2,263,552 here), and no CPU model Zig names (`znver2`-`4`,
  `skylake_avx512`, `icelake_server`, `sapphirerapids`, `x86_64_v3`) gives
  the release's bytes: the runner's CPU, in a virtual machine, has some
  features hidden. On a CPU without the SHA extensions, such as Intel's 6th
  to 10th generation Core, it would stop at its first hash. From 0.19.0,
  `build.zig` targets the x86-64 baseline: pulling zig takes about 3% longer
  than with a build for this machine's CPU (32.4 and 33.5 s against 31.2 and
  32.9 s).
- **VLC sometimes starts playing 30 s late.** In one run of
  `tests/guiapps.sh`, VLC's window was up at once, but named the clip only
  30.7 s later, when it started playing it; the next 13 runs by hand and 5
  suite runs took 0.7-1.2 s. Not found why. The suite waits for it.

- **Fixed: `soft` runs could modify installed apps.** Python wrote a file into
  its shared app folder, so the files no longer matched the image digest.
  Each deployment now gets a "deny write and delete" entry for the current
  user. That blocks every process running as the user, inside or outside
  zigsaw. zigsaw lifts it when an app is removed.
- **Apps don't expect the network to be denied.** Busybox `wget` crashes with
  an access violation (`0xC0000005`) instead of reporting an error.
- **Folder redirection held.** zig, Node, npm, Python and git all took their
  cache and config locations from the redirected environment variables. No
  tool in this set bypassed them with `SHGetKnownFolderPath`.
- **Grants are fast.** Granting read access to zig's 19,546 files took 2.7 s,
  once per app. Grants on project folders took milliseconds.
- **Big builds are slow because of Defender.** Building zig (19.5k files,
  378 MB) takes 60–175 s. zigsaw unpacks the zip to disk and then reads every
  file back to write the layer. Defender scans each new file, so reading them
  right after creation waits on the scans. By comparison, hashing the whole
  layer takes 0.4 s in an optimized build. Streaming zip entries straight
  into the layer would create each file only once.
  *Fixed afterwards:* builds now stream sources into the layer, and
  deployment extracts the layer with 4 parallel workers. zig installs in
  about 16 s and rebuilds in 4 s, with byte-identical layers.
- **All six recipes rebuild to identical digests**, including the 378 MB zig
  layer.

## GTK's first run in CI (iteration 36)

- **GTK's family reproduces on a runner**: GTK's SDK and runtime, GTK 3's,
  PyGObject's, the dictionaries, Text Editor's and Rnote's files, Meld,
  Gaphor, Gnumeric and GTK 3's demos all built to the published layers in
  iteration 35's run, the first since iteration 10.
- **Recipe files need fixed line endings.** Rnote's and Text Editor's
  configs differed there, their layers didn't: an image records the hash of
  each file its recipe carries, and the runner's git (`core.autocrlf=true`)
  checked out `recipes/rnote/*` and `recipes/gnome-text-editor/*` with CRLF,
  which `.gitattributes` didn't cover. One rule now covers every file under
  `recipes/`.
- **zig's cache made cargo-c build two images.** The runner built cargo-c
  0.10.25 as `5c3ab826`, the image GTK's SDK pins, but the version's tag
  was `c17e0473`, built here: the same config, and programs with 17 KB more
  code, BLAKE3's AVX-512 code. BLAKE3's build script asks cc-rs whether `cc`
  takes `-mavx512f -mavx512vl`, which cc-rs answers yes only if the test
  compile prints nothing. The recipe's `-D__MSVCRT_VERSION__=0x700`
  redefines zig's own, and clang warns; but when zig takes the object from
  its cache, it prints none of the warnings clang gave. So a fresh store
  builds `5c3ab826` twice, and `c17e0473` from the third build on, once
  both probes are cached; this machine's long-used stores had built
  `c17e0473` since 2026-10-14. A fresh `ZIG_LOCAL_CACHE_DIR` makes zig
  compile again, warnings and all, while its global cache keeps the C
  runtime (a link took 1.2 s, against 124 s with nothing cached). So from
  0.36.0 each module's zig local cache is its own directory's `.zig-cache`,
  fresh for each build, and `5c3ab826` comes out of the store that had
  built `c17e0473`. A report for zig's issue tracker is drafted, not yet
  filed.
- On Windows Server 2025, in an AppContainer, CPython's getpath can't find
  its own executable's real path (the probe's `self-path-dos`), warns, and
  goes on.
- On a runner's four CPUs, GTK's SDK takes 55 minutes to build, gettext
  39, Gnumeric 27 and Rnote 15; here,
  with sixteen, GTK's SDK is 15.

## gettext's build time (iteration 38)

- **BusyBox's make runs one command at a time.** Its help says
  `-j NUM   Jobs to run in parallel (not implemented)`, so every
  `make -j"$(nproc)"` in the recipes compiled one file at a time. Iteration
  37 took gettext's build being slower here, with sixteen CPUs, than on a
  runner's four for the cost of libtool's shell scripts; it was a serial
  build, slower here per process. OpenSSL's recipe had worked around it
  already.
- **automake's objects in subdirectories depend on a `.dirstamp` file**
  there, which make creates as it first needs the directory. Objects
  compiled ahead of make were older than it, and make compiled them again:
  380 of gettext's 1,400 compiles, until the recipe's wrapper made the
  `.dirstamp` files first.
- **configure under BusyBox finds no `install`**, as it finds no other
  program by name, and installs with automake's `install-sh`, a shell
  script that starts several programs for each file. gettext installs about
  2,200 files one call at a time: 8½ minutes here, and about 4½ with
  BusyBox's own `install`, given as `INSTALL`.
- Compiling ahead and installing with another program leave gettext's
  files as they were, byte for byte, so its image keeps its digest.

## Qt 6 with zig (iteration 39)

- **zig's libc++ works across DLLs.** zig links libc++, libc++abi and
  libunwind into each DLL and program, so each has its own copy. A probe of
  two DLLs and a program, linked as recipes link, passed all 18 checks: an
  exception thrown in one DLL caught by type in the other and in the
  program (a header-only exception type too), unwinding through a frame of
  the other DLL; `dynamic_cast` and `typeid` on a class whose vtable is in
  one DLL, and on a header-only class, which every DLL has its own type
  information for (libc++ compares type names on Windows; the DLLs export
  only what's marked `dllexport`, no type information); `std::string` and
  `std::vector` made in one and grown and freed in another (one CRT heap);
  `std::function` both ways; `thread_local`; static initialisers. So Qt
  builds as DLLs, with one runtime image for its apps.
- **zig's MinGW has no `synchronization` or `runtimeobject` import
  library**, which QtCore links by name (`-l`): it found neither. Each can
  be the import library of a stub DLL that zig links, named after the
  system DLL with the functions, as zig names an import library's DLL by
  the output's name. zig names the import library after the first source
  file unless `-Wl,--out-implib` says otherwise.
- **zig's `cc` ignores `-mwindows`**, which CMake gives a
  `WIN32_EXECUTABLE`: Qt's GUI programs linked as console programs (seen
  before for Meson's GTK apps, which pass the linker's flag themselves).
- **zig's `rc` reads an unquoted file name only up to a `-`**:
  `1 24 lrelease-pro_internal_qt.manifest` named the file `lrelease`.
- **Qt takes a program beside `Qt6Core.dll` for one deployed with
  windeployqt**, with the program's directory as the prefix, unless
  `lib\libQt6Core.a` is there too. A runtime without `lib` sent Designer
  and qtdiag looking for plugins in `bin\plugins`; qtdiag then hung on
  Qt's message box for a missing platform plugin, and Designer, behind the
  same box, looked as if it ran. Apps, whose programs are elsewhere, find
  the prefix from `Qt6Core.dll`'s directory.
- **In an AppContainer, `CreateNamedPipe` is denied outside
  `\\.\pipe\LOCAL\`**, the container's own namespace for pipes, as
  Python's multiprocessing found ([above](#introspection-pygobject-and-meld)): QLocalServer
  couldn't listen, and KDSingleApplication, which Flameshot checks for a
  running copy with, gave up and quit the app. With the name under
  `LOCAL\`, a first copy listens and a second one finds it.
- **download.qt.io redirects to a mirror chosen by where you are**
  (ftp.jaist.ac.jp here), and zigsaw's fetch failed with
  `TlsInitializationFailed` on the way. GitHub's mirror of each module has
  the release's tag, and its archives have the same files as the release's,
  without git submodules (qttools' qlitehtml).
- **Qt 6.12's Linguist needs Qt Quick** (its CMake skips it without
  `Qt::Quick`); its command-line tools don't.
- **Qt's build records its time and paths:** its SBOM's creation time,
  `qt-cmake.bat` and the like naming CMake by its path in the store, and
  `prefix=B:/prefix` in its pkg-config files. Without those, the SDK, the
  runtime and Flameshot were the same, byte for byte, in two fresh stores.
- **Flameshot's `flameshot-cli.exe`** runs `flameshot.exe` through
  `_wpopen` with a command line it sizes as `32 + sizeof(std::wstring) +
  sizeof(std::wstring)` characters: about 80, so a path longer than that
  is cut off. It also links only with MinGW's `-municode` (it has
  `wmain`), which its CMake gives MSVC's spelling of a console program
  instead.
- **Building:** qtbase's 1,900 build steps took 17½ minutes here, on 16
  CPUs, and the SDK 26½ minutes from scratch. Twice early on, a build's
  configure failed when CMake couldn't start Ninja
  (`0xc0000142`, `STATUS_DLL_INIT_FAILED`) right after I had stopped
  another build; it didn't happen again.

## CMake's search paths, and Qt Quick (iteration 40)

- **CMake searched Program Files in every build.** Kitware's
  `Modules/Platform/WindowsPaths.cmake` adds `ProgramW6432`, `ProgramFiles`
  and `ProgramFiles(x86)` to `CMAKE_SYSTEM_PREFIX_PATH`, and then
  `%SystemDrive%\Program Files` and `Program Files (x86)` if they exist.
  zigsaw's builds have no `ProgramFiles` but do have `SystemDrive`, so
  every `find_*` looked there. Iteration 39's run built Qt's SDK on a runner
  that has PostgreSQL 17 there: FindPostgreSQL (which adds
  `PostgreSQL/<version>/lib` to each prefix) found its `libpq.a`, Qt built
  a `qsqlpsql` plugin, and its link failed on the MSVC libraries `libpq.a`
  asks for. Here, Flameshot's configure found and ran
  `C:\Program Files\Git\cmd\git.exe` (FindGit tries `Git/cmd` under each
  prefix). Flameshot came out the same, since its sources aren't a git
  checkout, but a store inside a git checkout would have put that commit's
  hash in its version.
- **FindPython took the machine's Python from the registry**
  (`HKCU\Software\Python\PythonCore` here) before any on PATH: its
  `Python_FIND_REGISTRY` is `FIRST` on Windows.
- **The published Qt SDK didn't depend on this machine.** Configuring
  qtbase, qttools and Flameshot with the old and the new CMake image: the
  old found nothing under Program Files but Flameshot's Git, and qtbase's
  configuration summary was the same with both.
- **qtdeclarative needs Python to build**: its `RegExpJitTables.h` comes
  from a Python script (yarr's `create_regex_tables`, which imports only
  `os` and `sys`), and its configure stops without one. The SDK's module
  unpacks Python's embeddable zip for it and names it with
  `-DPython_EXECUTABLE`.
- **qtshadertools and qtdeclarative build with zig unchanged**: no patch,
  no flag beyond Qt's other modules'. qtdeclarative's 4,410 build steps
  took 34 minutes here, qtshadertools' 3. Every one of its 2,052 warnings
  is `_LIBCPP_HARDENING_MODE` redefined: Qt's CMake asks libc++ for its
  "fast" checks, after zig's "none", and Qt's wins.
- **qtdeclarative's build races its own type information.** qmlcachegen
  compiles a module's QML bindings to C++ where it knows the types, from the
  other modules' `plugins.qmltypes`; its Ninja rule waits for their autogen
  and copy steps but not for the type registration that writes those
  files. So which bindings became C++ depended on Ninja's order: two fresh
  builds of the SDK differed in one DLL, the FluentWinUI3 style's
  (455,168 and 462,336 bytes; a third build, 457,216), whose QML had 67 of
  its 130 functions compiled in one and 71 in another (CheckIndicator's
  bindings to Qt Quick Shapes). Generated again with every type known, it
  came out the same each time. Building `all_qmltyperegistrations` first
  didn't help: it runs qmlcachegen for some modules itself. The SDK's
  module deletes the 1,190 generated qmlcache sources after its build and
  builds again (7½ minutes here), so every one is generated with all the
  type information.
- **The base half changed nothing in Qt's other modules**: its 4,306 files
  that iteration 39's SDK has too are the same, byte for byte, with the new
  CMake image and the SQL drivers turned off by name.
- **Qt Quick draws with Direct3D 11 in all three sandboxes**, in an
  AppContainer too: a window of Quick Controls read back after its first
  frame has its own colour. Its shaders are HLSL that the system's
  `d3dcompiler_47.dll` compiles when the app runs. The Controls style on
  Windows 11 is "Windows".
- **Linguist links `Qt6UiTools.dll` and `Qt6QuickWidgets.dll`**: the
  runtime, which dropped UiTools as a library for builds, keeps it.
- **Notes 2.3.1 links Qt's private modules without asking for them**, which
  Qt 6.10 stopped allowing (`Qt6::CorePrivate` not found); its master adds
  them to `find_package`. Its `#pragma comment(lib, "Dwmapi.lib")` works
  with zig's linker. Under every sandbox it logs DirectWrite failing on
  "MS Sans Serif", a bitmap font its style sheets name, which DirectWrite
  can't load.
- **Built in two halves, like GTK's, the SDK takes 73 minutes here**: the
  base 25, the SDK on it 48 (41½ before the second qmlcache pass). In one
  build it would be as long, and one job on a runner over 90 minutes.

## zig hanging on a console (2026-10-23)

- **OpenSSL's module, in GTK's SDK, hung at its third command when the
  build's output went to a terminal**, and built when it went to a file.
  That command compiles about 700 files with `xargs -P "$(nproc)"`; one
  `zig cc` had written its object and never exited, so xargs and the build
  waited for it.
- **It's zig 0.16's stderr lock.** With stderr on a console, each zig
  process draws a progress line from a worker thread, the first time 200 ms
  in. That draw takes the stderr lock, then finds out what the terminal
  supports, which can fail as canceled; `tryLockStderr` returns the error
  without giving the lock back. A `zig cc` that finishes then (OpenSSL's
  small files take about that long) cancels the thread just as it does
  that, and its exit, `std.process.cleanExit`, waits for the lock forever.
  The hung process's memory showed it: the lock taken once, by a worker
  thread back in the pool, and the main thread waiting for it. With stderr
  in a file or a pipe, zig draws nothing, so compilers that ninja or cargo
  run, taking their output, can't hit it; those that make or xargs run
  straight on the console can.
- **A program with nothing but std.Progress hangs the same way**: started,
  ended 198 to 214 ms in, and exited, it hung in 26 of 3,201 runs on a
  console. With `NO_COLOR` set it never did, since zig then skips the
  terminal check that the cancel interrupts; the PowerShell it was first
  tried from had it set, and hid the hang. A task canceled before it first
  locks stderr hangs the next lock every time.
- zig's master branch has the same code, and the zig image is upstream's
  build, so the image can't patch it. Build commands now get
  `ZIG_PROGRESS=off`: a value zig can't parse as a handle, so no zig in a
  build starts the progress line. OpenSSL's module then built in a console
  in 3 minutes, and zstd rebuilt with it kept its digest. A report for zig's
  issue tracker is drafted, not yet filed.

## TeX Live and Ghostscript (iteration 43)

- **install-tl works offline and hermetically** from a local repository
  (`-repository B:/.../repo` with `tlpkg/texlive.tlpdb` and `archive/`),
  run with the Perl in `install-tl.zip`, in 1m48s for the small scheme, with
  `instopt_portable 1`: nothing in the registry. Its disk check calls
  `powershell` (not on a build's PATH; `TEXLIVE_INSTALL_NO_DISKCHECK=1`). On
  Windows it always adds tlperl, tlgs and `collection-wintools`, unless the
  profile names the collections itself (`collection-wintools 0`).
- **Formats aren't reproducible**, with `SOURCE_DATE_EPOCH` and
  `FORCE_SOURCE_DATE=1` (which do fix the log's date): in two builds ten
  minutes apart, pdfTeX's formats differ in a byte or two (`\pdfrandomseed`
  comes from the clock: 533745103 and 701745105 in two runs a second
  apart), Knuth's TeX's in `\time` (0x39D and 0x3A7, 15:25 and 15:35), and
  LuaTeX's by megabytes; LuaTeX's `\time` with `FORCE_SOURCE_DATE` is local
  time. The rest of what the installer writes differs only in dated
  header lines and in `ls-R` (a temporary directory of fmtutil's was listed).
- **TeX Live's Windows `mktexfmt.exe` makes a format but doesn't print its
  path** (it's W32TeX's: it runs `fmtutil-user --byfmt` with stdout sent to
  stderr), so kpathsea reports `I can't find the format file` and the run
  that wanted it stops; the next one finds it. fmtutil.pl run as `mktexfmt`
  (by its file name) prints the path, as on Unix. In that mode it puts
  formats in `TEXMFSYSVAR` if `-w` says it's writable, and Perl's `-w` on
  Windows reads only the read-only attribute, so it chose the read-only
  deployment; TeX Live's own `dir_writable` writes a file.
- **Strawberry Perl 5.42 has no `Win32::Shortcut`**, which TeX Live's
  `TLWinGoo.pm` requires on load (for Start menu shortcuts only), so
  fmtutil, updmap and tlmgr fail on it; latexmk doesn't load TLWinGoo.
- **XeTeX's fontconfig configuration names absolute paths**: the
  installer's post-install code writes `TEXDIR` and `%SystemRoot%` into
  `fonts.conf` (`B:/prefix/...`, wrong once deployed: XeTeX found no font by
  name); `<dir prefix="relative">` and `WINDOWSFONTDIR` work with TeX Live's
  fontconfig. `XE_FC_CACHEDIR` moves its cache.
- **In an AppContainer, `GetLongPathNameW` of a program's own path is
  denied** on this Windows (26300.9711), from a D: store and from one under
  `%LOCALAPPDATA%`: it lists each directory from the drive root, which
  AppContainers can't. `GetFinalPathNameByHandleW` of the same path works.
  kpathsea calls it at startup, so no TeX Live program starts in one.
- **Ghostscript 10.08 builds with zig cc and BusyBox's make** from its
  release tarball, with its configure script's MinGW support and three
  changes (see [recipes](recipes.md#ghostscript)): it decides BusyBox's make
  isn't GNU make, yet writes GNU's order-only `|` into its makefile; zig
  rejects `-Wp,-w`; and `mkromfs.c`'s stand-in for the Windows `gp_stat_impl`
  clashes with the Unix one MinGW builds use. It reproduces (two stores).
- **Builds take turns on `B:`**: a build in another store waits ("waiting
  for another zigsaw build to finish with B:"), so builds in parallel stores
  run one after another.

## PostgreSQL (iteration 45)

- **zig's linker ignores `--export-all-symbols`.** `zig cc -Wl,--export-all-symbols`
  links without a word, and the program exports only what's marked
  `__declspec(dllexport)`. Linking a `.def` file, given to zig's cc as an
  input, exports what it lists. zig's linker refuses
  `--allow-multiple-definition` and `--disable-auto-import`, which MinGW
  builds of PostgreSQL pass.
- **clang's `__builtin_setjmp`/`__builtin_longjmp` crash PostgreSQL**, which
  uses them for MinGW-64 (mingw's setjmp had problems with GCC): a `DO` block
  in a language that doesn't exist, or the statement after a failed
  `CREATE EXTENSION`, ended the backend with 0xC0000005, in
  `MarkPortalFailed()` calling a bad portal's cleanup after longjmp had come
  back to `PortalRun()`. Division by zero didn't. With mingw's setjmp and
  longjmp (SEH unwinding, which clang emits unwind data for) all of these
  raise their errors, as do errors raised through PL/Perl and PL/Python.
  Neither crash dumps (`PGDATA\crashdumps`) nor WER caught it. A debugger
  made with Python's ctypes did: attached to the backend of a psql session,
  it named the stack's return addresses from `postgres.exe`'s exports.
- **Meson reads `RC` before `WINDRES`** for its windres, and zig's image sets
  `RC` to zig's rc, which doesn't take windres's `-o`/`-i`.
- **Meson makes its static libraries thin archives**, whose members are
  only names, which a tool reading archives (GTK's SDK's `nm`) has to follow.
  `-Dprefer_static=true` made Meson's `find_library('ws2_32')` fail.
- **zigsaw takes `.tar.gz`, `.tgz`, `.tar.xz` and `.zip`, not `.tar.bz2`**:
  PostgreSQL's `.tar.gz` is used.
- **In an AppContainer, a program can't stat the store's parents**
  (`D:\zs`, here): initdb's `pg_mkdir_p` stats each parent and `mkdir`s what
  it can't stat, which fails with EEXIST, and cmd.exe answers "Access is
  denied" to running a program by its path in the store, or a batch file in
  the app's data. initdb's test of `max_connections` and `shared_buffers`
  runs postgres through `system()`, and falls back to 20 and 400kB.
  CreateProcess of the same path works.
- **Everything else of PostgreSQL works in an AppContainer**: its named
  shared memory (`Global/PostgreSQL:<path>`, which with `/`s is a name in
  the session's namespace, not `Global\`), its signal pipes once under
  `\\.\pipe\LOCAL\`, its child processes, PL/Perl and PL/Python, and
  connections on `127.0.0.1` between runs of the same app, whose runs share
  its container. A client outside the container can't connect (no loopback
  exemption). At low integrity and under soft, nothing needed changing.
- **pgxs's `Makefile.global` names the build's Perl by its path in the
  store** (`D:/zs/i45/p/deploy/<layer>/perl/bin\perl.exe`), so three stores
  built three layers, the same but for that file. The image leaves pgxs out,
  as it has no headers to build extensions with.
- **pg_basebackup waits for a spread checkpoint** by default: after a few
  writes, longer than a test's two minutes. `--checkpoint=fast` doesn't wait.

## The OCI tools (iteration 57)

ORAS 1.3.6, skopeo 1.24.1 and cosign 3.1.4, built with Go 1.27.1 and cgo
off, probed against tests/zot.sh's registries on Windows 11 26300:

- **All three build for Windows as they are.** skopeo's module is
  `go.podman.io/skopeo` now; its Makefile's tags without cgo
  (`exclude_graphdriver_btrfs containers_image_openpgp`) are enough. cosign
  needs Go 1.27 (`go 1.27` in its go.mod), and is 106 MB stripped.
- **`go mod vendor`**: ORAS 12 MB (772 files), skopeo 46 MB, cosign 130 MB
  (10,554 files). Keeping only what `go list -deps` names, as zot's recipe
  does, leaves skopeo 32 MB and cosign 103 MB: cosign's command imports the
  AWS, Azure, Google Cloud and Vault key services.
- **skopeo looks for its policy in `%APPDATA%\containers\policy.json`, then
  `C:\ProgramData\containers\policy.json`**, and refuses to copy without
  one. `CONTAINERS_POLICY_JSON` comes before both (go.podman.io/storage's
  `configfile`), `--policy` before it. Its logins go to
  `%USERPROFILE%\.config\containers\auth.json`.
- **skopeo calls zigsaw's images artifacts**: their config's media type is
  `application/vnd.zigsaw.app.config.v2+json`, so `inspect` says
  "unsupported image-specific operation on artifact"; `inspect --raw`,
  `list-tags` and `copy` work.
- **skopeo's `oci:` transport on Windows splits off a tag only after
  `X:\`** (`^([a-zA-Z]:\\.+?):(.*)$`): `oci:layout:1` is taken as a path
  with a colon, and fails; `oci:layout` and `oci:D:\...\layout:1` work.
- **cosign 3 refuses `--tlog-upload=false`** unless signing configs are
  off (`--use-signing-config=false`, deprecated); by default it fetches
  Sigstore's signing config through TUF. A signing config with no services
  (`cosign signing-config create --out x.json`, no flags) signs with the key
  and nothing else, with the internet cut off by a proxy that goes nowhere.
  `verify --key ... --insecure-ignore-tlog` works offline too. The
  signatures are OCI referrers (zot answers the referrers API), with no
  `sha256-....sig` tag, and `zigsaw pull` of the signed image works.
- **In an AppContainer, a path to write is resolved through the folders
  above it.** ORAS's file store (oras-go's `checkSymlinkEscape`, new against
  symlinks out of the output folder) and skopeo's `oci:` and `dir:` call
  `filepath.EvalSymlinks`, which on Windows opens each folder from the
  drive's root: "CreateFile D:\zs: Access is denied". The same restriction
  as Node's realpath and initdb's `pg_mkdir_p`. Pushing a file, registries,
  the loopback (the exemption) and cosign's key files work there.

## Zig 0.17 (iteration 58)

Zig 0.17.0 (LLVM and Clang 22.1.8) against 0.16.0, on Windows 11 26300,
before moving zigsaw and the zig image to it (scratch `D:\zs\i58`):

- **Its deflate makes 0.16.0's bytes.** A program compressing as
  `writeLayerFile` does (layer.zig's level 6, 64 KiB buffers), built with
  each, gave the same gzip for four published layers, plain: zig's
  (378 MB), MinGit's, GTK's SDK's and TeX Live's (532 MB), and each was the
  published layer's digest. zigsaw 0.58.0, built with 0.17, then rebuilt zig
  0.16.0's image as published, manifest and all (`f8310e4e`). A unit test
  now pins the bytes of a small layer and of a MiB of mixed words.
- **`zig rc` stays, and makes 0.16's bytes**, but it's no longer in the
  compiler: the first `zig rc` builds resinator from zig's library into the
  global cache, offline, which took 41 s here; later ones are instant. A
  build's tool cache keeps it, so that's once a store.
- **`zig cc -O2 -s -Wl,-Brepro` still makes the same bytes from two
  folders**; setjmp and longjmp work; `ar`, `ranlib`, `cc -c -x assembler`
  (the `as` alias) and `dlltool` work as before. `zig cc -###` still exits 1,
  so cgo builds still need `-buildid=`.
- **What zigsaw's code needed**: `a ** n` is gone (31 places, all tests; a
  `repeat` helper, as std's `@splat` of arrays is long-winded),
  `Allocator.dupeZ` is `dupeSentinel(T, x, 0)`, `std.meta.fields` and an
  enum's `.fields` are `field_names` with `field_types` or `field_values`,
  `std.ascii.indexOfIgnoreCase` is `findIgnoreCase`, `std.builtin.OptimizeMode`
  is `std.lang.Optimize` (`.debug`, `.safe`, `.small`), and `b.args` is
  `run_cmd.addPassthruArgs()`. `std.fmt.allocPrint` is deprecated, not gone.
  All 17 `@bitCast`s are between integers of one size, which 0.17's new
  meaning doesn't change. `-Doptimize=` takes the old names and the new.
- **zigsaw builds itself the same in the zig 0.17.0 image as outside it**,
  and the same from another folder with a cold cache.
- **ZLS 0.17.0 needs zig 0.17.0**, and builds as 0.16.1 did:
  `zig build --fetch` puts the same three packages in `zig-pkg` (tracy is
  lazy), and `zig build --system zig-pkg` builds offline, in about 3 minutes.
- **build.sh's fixtures build with zig 0.17.0's image as with 0.16's**: C
  and C++ with `rc`, SQLite, CMake, Meson and make, Rust with GNU dlltool and
  zig's `as`, and cgo; 0 failed in the zig, cmake-meson, langs and base groups.

## The small chains on Zig 0.17 (iteration 60)

Moving the recipes that build with zig 0.16's image onto 0.17.0's (scratch
`D:\zs\i60`), on Windows 11 26300 with 16 logical processors and 16 GB:

- **A link with zig 0.17's `cc` commits about twice the memory**: 906 MB
  against 0.16's 425 MB, for a hello-world (`zig cc -s -Wl,-Brepro hi.o`),
  the same on every run, with `-fuse-ld=lld` too, and whether the process
  may use 1, 4 or 16 processors. A compile costs the same with both (a C++
  file with the standard library's headers: 184 MB for zig, 230 MB for the
  clang it starts). Ninja runs 18 jobs here, so when GDAL's SDK and
  PostgreSQL's reach their links, which start many at once, they need about
  16 GB: on this machine, whose commit limit is 18.5 GB with a 2.8 GB paging
  file and some 8 GB in use by everything else, they failed three times
  ("The paging file is too small", `LLVM ERROR: out of memory`). A runner's
  4 processors give 6 jobs. So GDAL's and PostgreSQL's chains stay on zig
  0.16 for now.
- **zig 0.17's compiler-rt still has no `__cpu_model`**:
  `__builtin_cpu_supports("avx2")` doesn't link, so GDAL's CPUID patch
  stays.
- **Clang 22 makes `-Wincompatible-pointer-types` an error**: Xdebug 3.5.3
  passes an `int *` for a `DWORD *` (`GetOverlappedResult`, `ReadFile`).
  MSVC only warns (C4133), as it does for an undeclared function, which
  php-ext already let through, so php-ext now lets this through too.
- **Meson, make, cargo-c, Ghostscript, PHP's SDK and every PHP extension
  build with 0.17 as they did with 0.16**, the extensions with nothing but
  that flag.
- **PHP's image is the same layer from the new SDK** (`a48cecfd`): its
  files are the official build's. Its config names the SDK it was taken
  from, so its digest, and Composer's and Kanboard's, which pin it, change.

## GDAL and PostgreSQL on llvm-mingw (iteration 61)

GDAL's and PostgreSQL's chains moved from zig 0.16's `cc` to
[llvm-mingw](https://github.com/mstorsjo/llvm-mingw) 20261020 (LLVM 23.1.4,
UCRT), as the image `com.github.mstorsjo.llvm-mingw` (scratch `D:\zs\i61`,
the same machine as iteration 60):

| | with zig 0.16 | with llvm-mingw |
|---|---|---|
| GDAL's SDK, here | 16 to 21 min | 11.7 min |
| PostgreSQL's SDK, here | 15 min | 7 min |
| a hello-world link, peak private memory | 425 MB (0.17: 906) | about 10 MB |
| least free commit during GDAL's SDK, 18 jobs | ran out with 0.17 | 6.9 GB |
| GDAL's SDK layer / GDAL's | 39 / 25 MB | 42.8 / 29 MB |
| PostgreSQL's regress / isolation / PL suites | 231 / 122 / 50 | 231 / 122 / 50 |

- **The toolchain's own image is 108 MB** (417 MB deployed) once the other
  targets' sysroots and wrappers, lldb and its Python, clangd and
  clang-tidy are left out: 736 MB as released.
- **Clang and lld write the time** into each object's COFF header and each
  program's, where zig's `cc` wrote none. A program linked twice showed it,
  but the first image's builds differed between two stores only in their
  static libraries (two bytes an object): lld doesn't copy an object's
  time into what it links. `-mno-incremental-linker-compatible` and
  `-Wl,--no-insert-timestamp` (lld's MinGW driver refuses `-Brepro`) in
  Clang's configuration file leave both out, `CFLAGS` and `LDFLAGS` or
  not, and say nothing under `-Werror`; the image's build checks an object
  and a program compiled 2 s apart.
- **llvm-mingw's `x86_64-w64-mingw32-as` links** what it's given rather
  than assembling it, so the image has no `as` alias.
- **Without libc++'s, libunwind's and winpthreads' import libraries**
  (`.dll.a`), a C++ program with threads and exceptions links them in and
  imports only Windows' DLLs; Clang itself still needs `bin\libc++.dll`.
- **What zig's linker made recipes work around, lld does**: GNU ld's
  `--export-all-symbols` (leaving the CRT's `atexit` and `_CRT_INIT` out, so
  no `crt-noexport` object), `--allow-multiple-definition`, `-lX` finding
  `libX.dll.a`, and compiler-rt's `__cpu_model`. PostgreSQL builds with
  upstream's own MinGW path (`export_dynamic`, an import library), with no
  `postgres.def`, nm or windres of our own; GDAL without its CPUID patch.
- **LLVM 23's libc++ includes less**: GEOS 3.15.0 uses `std::add_const` and
  `std::lower_bound` without `<type_traits>` and `<algorithm>`, GDAL 3.13.3
  `std::strtoull` and `std::atomic` without `<cstdlib>` and `<atomic>`.
  PROJ 9.9.0 needed nothing.
- **Clang 23 warns of more**: json-c's own `-Werror` fails on the new
  `-Wunused-but-set-global` (`-DDISABLE_WERROR=ON`), and pgvector's
  `evex512` target feature, which Clang 21 needed, is gone.
- **mingw-w64's newer `wchar.h` includes `sys/stat.h`, which includes
  `<io.h>`**: libopencad, inside GDAL, puts its `dwg` folder, which has an
  `io.h`, on the include path, and that one was found instead.
- **Clang for MinGW lays a struct with an under-aligned `__int128` out on 16
  bytes**: PostgreSQL's `int128` is `__int128 __attribute__((aligned(8)))`,
  `_Alignof(int128)` is 8, but a struct of it is 16-aligned, so copying
  palloc'd aggregate state uses `movaps` on 8-byte boundaries.
  PostgreSQL's configure finds `__int128` with llvm-mingw (with zig it
  didn't), and parallel `avg()` and `variance()` of `int8` crashed the
  backend (0xC0000005 in `int8_avg_combine`, from a minidump PostgreSQL
  writes into `<PGDATA>\crashdumps` and llvm-mingw's lldb read), 31 of 231
  regression tests. The recipe turns `__int128` off for Clang on Windows,
  as zig's build was.
- **A configure script finds no tool on PATH under B:** unless
  `PATH_SEPARATOR=;`: libiconv's `WINDRES` was empty until set.

## Qt on llvm-mingw (iteration 62)

Qt's SDK halves, its runtime, Flameshot and Notes moved from zig 0.16 to
the llvm-mingw image iteration 61 published (`1fd5d6d8`), which the SDK
now carries as a runtime in zig's place (scratch `D:\zs\i62`, the same
machine):

| | with zig 0.16 | with llvm-mingw |
|---|---|---|
| Qt's SDK base, here | 25 min (qtbase 17.5) | 16.5 min (qtbase 12.3) |
| Qt's SDK on it, here | 26 min (qtdeclarative 14, its second pass 2.5) | 18.6 to 19.3 min (9.9, 1.6; qttools 4) |
| least free commit, base / SDK, 18 jobs | | 6.2 / 4.6 GB |
| base / SDK / runtime layer | 35.3 / 87.5 / 55.6 MB | 37.2 / 91.3 / 57.4 MB |
| runtime deployed | 153 MB | 160 MB |
| the toolchain an SDK pull brings | zig, 88 MB | llvm-mingw, 108 MB |

- **C++ works across DLLs that each link libc++ in**, with llvm-mingw's
  static libc++, libc++abi and libunwind as with zig's: 19 checks of two
  DLLs and a program ([`tests/build/xdll`](../tests/build/xdll)) passed in
  all three sandboxes before Qt was rebuilt: exceptions of a DLL's class
  and of a header-only one, caught in the other DLL and in the program,
  thrown through another DLL's frame, and rethrown from an
  `exception_ptr`; `dynamic_cast`, `typeid` and virtual calls on a class
  whose vtable is in the other DLL, and on a header-only one; strings and
  vectors grown and freed across them; `std::function` both ways;
  `thread_local`; static initialisers. The DLLs export only what's marked
  `dllexport`: none of the C runtime's symbols, which zig's needed an
  object to keep out.
- **What zig needed and llvm-mingw doesn't:** the `synchronization` and
  `runtimeobject` import libraries (llvm-mingw's mingw-w64 has both),
  QtCore asking for `-Wl,--subsystem,windows` (Clang honours `-mwindows`;
  the SDK's build checks Designer's subsystem), the object that kept the
  C runtime's symbols out of the exports, `-s` in `CFLAGS` and
  `-Wl,-Brepro`, and `rc`'s options. llvm-windres reads the manifest's
  unquoted file name too; the quoting edit stays, as every resource
  compiler reads a quoted one.
- **llvm-windres unquotes `-D` values once**, as GNU windres does by
  running its preprocessor through a shell: CMake passes
  `-DFLAMESHOT_VERSION_STRING=\"14.0.0\"`, the program gets
  `-DFLAMESHOT_VERSION_STRING="14.0.0"`, and the resource script saw
  `14.0.0`, which isn't a string (`expected BLOCK or VALUE, got .0.0`).
  `--use-temp-file` keeps the quotes. CMake reads `RCFLAGS` for
  `CMAKE_RC_FLAGS`, so Qt's SDK sets `RCFLAGS=--use-temp-file` for the
  builds on it; Qt's own modules pass no quoted values to windres, and
  GDAL's and PostgreSQL's chains don't either.
- **LLVM 23's libc++ again needs an include** its older headers brought
  in: Flameshot's `strfparse.cpp` uses `std::back_inserter` without
  `<iterator>`. Qt itself and Notes built as they were.
- **The SDK's layer is the same whatever its config says**: setting
  `RCFLAGS` made a new SDK manifest with the layer of the build before it
  (`fead0ba1`), so the runtime's layer, made from it, stayed too.

## Not yet tested

- Ctrl+C during a run. It needs an interactive console.
- Tools with fixed install paths, or installers.

## Options for enforcement

The `soft` sandbox covers the reproducibility goal. The open question is
whether zigsaw also needs an enforcing sandbox that general toolchains can
use:

1. **Keep `appcontainer` opt-in for self-contained tools.** Document which
   tools work. This needs no further work.
2. **Try a low-integrity sandbox.** Running at low integrity blocks writes to
   anything not labelled low, and zigsaw can label its data folder and granted
   paths without admin rights. Reads and network access stay open.
   Drive-letter conversion and `lstat("C:\\")` work at low integrity, and so
   does every tool tested ([iteration 8](#a-low-integrity-sandbox)), as long
   as the deployments' ACLs name no AppContainer. *Built in iteration 9 as
   `--sandbox=low`* ([above](#the-low-sandbox)), *and the default since
   iteration 54*: the matrix's low column had had no gap on Windows 11 and
   Server 2025 since iteration 13, and a working directory low won't label
   (your profile, a drive's root) became read-only for the run instead of
   refused.
3. **A one-time admin setup step.** Granting `ALL APPLICATION PACKAGES` read
   access to `C:\`'s attributes would fix the Node failures (restriction 2).
   Drive-letter conversion (restriction 1) would still fail, so this alone
   doesn't make `appcontainer` general.
