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
   paths without admin rights. Reads and network access stay open. It isn't
   known yet whether drive-letter conversion and `lstat("C:\\")` work at low
   integrity. The same probe can answer that before any sandbox code is
   written.
3. **A one-time admin setup step.** Granting `ALL APPLICATION PACKAGES` read
   access to `C:\`'s attributes would fix the Node failures (restriction 2).
   Drive-letter conversion (restriction 1) would still fail, so this alone
   doesn't make `appcontainer` general.
