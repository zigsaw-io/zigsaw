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
  `ALL APPLICATION PACKAGES`.

## Other findings

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
   as the deployments' ACLs name no AppContainer.
3. **A one-time admin setup step.** Granting `ALL APPLICATION PACKAGES` read
   access to `C:\`'s attributes would fix the Node failures (restriction 2).
   Drive-letter conversion (restriction 1) would still fail, so this alone
   doesn't make `appcontainer` general.
