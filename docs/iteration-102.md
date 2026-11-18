# Iteration 102: Doctor

Started 2026-11-18, from "plan to implement diagnostic `doctor` command". zigsaw depends
on many things about the machine, the install and the store, and mostly finds out about
one only when a command hits it, often far from the cause: `error: AccessDenied` for a
store under a folder labelled low, Rust's "linker not found" for a store path over about
100 characters, a lazy pull that quietly downloads the whole layer on a Dev Drive, a
command whose shim names a zigsaw that moved, a key a killed run left in `HKCU`. Some of
these were found already, but only by the commands that also put them right (`repair`,
`ps`, `prune`, `grants`). Now **`zigsaw doctor` looks for all of them at once, changes
nothing, and says what fixes each: this zigsaw and Windows, the store and its drive, what
runs, builds, upgrades and deleted stores left behind, each installed app, and the
network.** zigsaw is **0.102.0**. No recipe or image changes, so there's nothing to
publish. How it's used is in [the README](../README.md#finding-whats-wrong).

State at the start: 101 had landed (`28ef66b`, Reproduce 43716407153 and Release v0.101.0
43725202404 green). The weekly Reproduce of 2026-11-16 (43859927288) went red after that:
`tests/network.sh` failed in 9 s, then `tests/lazy.sh` hung until the suites job's
45 minutes ran out, and the job's logs weren't kept. You chose to run it again yourself.

## Outcome

- **`zigsaw doctor [--offline] [<app-id>]`** prints sections of findings, each `ok`, a
  `note`, a `warning` or a `problem`, with what fixes it on the line under it, and a
  summary. It exits 1 when it found a problem.
- **This zigsaw**: Windows' version and machine, the integrity level zigsaw runs at,
  whether it runs as administrator, inside a run, or in a terminal's job that keeps what
  it starts; the five programs installed beside it, which Windows Security may have taken;
  whether it's the store's own; the store's `bin` on your PATH (the one a new terminal
  gets) and on this one, programs of the same names before it, and which zigsaw `zigsaw`
  is; and every `ZIGSAW_` variable set: settings, what zigsaw sets inside runs, test
  ones, a release key from the environment, and names zigsaw doesn't read.
- **The store**: not there yet (then nothing is made), its file system and drive (lazy
  pulls need NTFS; FAT keeps no permissions), a path too long for Rust's builds or with a
  space, a sync app's folder, a low label on it or on zigsaw, folders and apps' files an
  elevated zigsaw made Administrators', your folders that hold it, a `B:` builds can't
  use, data from before 0.85 waiting to move, and runs or a prune going.
- **Left behind**: runs whose zigsaw is gone, keys runs left in `HKCU`, what runs were
  given that nothing stands behind now, what deleted stores left, low labels no record
  explains, an upgrade's old programs, an import or a rollback that stopped halfway,
  shortcuts and URL schemes that start nothing of an app any more, and daily checks for a
  deleted store or with no program to start; the updates waiting.
- **Apps**: each app's manifest and config, checked against their digests; its layers,
  unpacked, being pulled lazily, or to unpack; its commands, each a copy of the shim
  beside a zigsaw that's there, for this store; its overrides; the volumes they mount;
  the recipe it was built from. Commands of apps that aren't installed. `doctor <app-id>`
  says all of it for one app, the fine parts too.
- **Network**: the default registry, and up to three more that installed apps came from,
  each asked for its API root as `pull` asks; GitHub's latest release, or
  `ZIGSAW_UPGRADE_FROM`'s; proxies: `HTTPS_PROXY` in use, Windows' own proxy or proxy
  script that zigsaw doesn't read, `NO_PROXY` that it doesn't either; and where the
  default registry's login is. All of it in five seconds at most; `--offline` asks
  nothing.
- **Fixed on the way**: `zigsaw rm` of an app whose manifest is gone failed half-way, its
  ref already deleted; it now finishes, and leaves the files to `prune`. `zigsaw repair`
  stopped at the first app whose image couldn't be read; it now repairs the others and
  exits 1.

## Decisions

Yours, by the question dialog:

- **Report only**, over a `--fix` or fixing as it goes: doctor changes nothing, not even
  the move of a store's data from before 0.85 that every other command makes first.
- **The network by default**, with `--offline` to leave it out, over only on request.
- **Presence checks for each app**, `doctor <app-id>` for one, over hashing every blob or
  no look at the apps.
- **The weekly run's failure is yours to rerun**, not part of this.

Mine:

- **Doctor is dispatched before the store is opened**, which makes its folders, by a new
  `Store.locate`, and takes no lock. It asks whether a lock is held only as `ps` does, of
  lock files that are there; for `prune`'s, a shared lock, which no other command's
  holding stops.
- **What finds a problem became its own function, which doctor and the command that fixes
  it share**: `ps.allRecords` beside `ps.live` (which deletes what it finds),
  `hkcu.leftovers` and `orphanAsides` under `settleLeftovers`, `grants.lapsed` and
  `leftovers` (from `Survey` and `Standing`), `upgrade.leftovers`,
  `volumes.waitingToMove` and `importLeftovers`, `snapshot.interruptedSwaps`,
  `associations.staleSchemes`, `shortcuts.stale`, the program a daily check's task
  starts (`schedule.Task.command`), `updates.summary`, `credentials.savedFor`. The
  commands do as they did.
- **Each request is a thread doctor leaves at five seconds.** Zig's HTTP client can't be
  given a timeout on Windows (a connect with one panics) and can't cancel a name's
  lookup; zigsaw ends with `ExitProcess`, which ends a thread still waiting. They start
  first, and go on while the rest is looked at. They use the client as `pull` does, its
  proxies and TLS, not WinHTTP, which would test something else.
- **A finding names a command that fixes it, or says what to do by hand**: `zigsaw
  repair`, `ps`, `grants --take-back`, `updates on`, `rm` then `build` or `pull`,
  `subst B: /d`, `icacls`, a variable to set. Where nothing of zigsaw's does it (a shim of
  an app that isn't installed), it says what to delete.
- **A check that fails says so as a note, and the report goes on**: a zigsaw at low
  integrity can't take a lock to ask, for one.
- **Administrators owning the store is a problem only when this zigsaw can't use that**
  (`CheckTokenMembership`): an elevated one can, as GitHub's runners are.
- **Settings in variables are notes, test ones warnings, a misspelt one a warning, a
  `ZIGSAW_REGISTRY` that isn't a registry a problem.** Every `ZIGSAW_` name the source
  reads is in doctor's list, which `tests/doctor.sh` checks.
- **No `--json`, and no hashing of what's installed**: the text is what goes in a bug
  report, and deployed files deny writes, so what changes them is the disk.

## Probe

Slice 0, before any of doctor (`E:\zs\i102\probe\netwatch.zig`, std's client set up as
`Registry.init` does it):

- **Watchdog threads work**: ghcr.io's `/v2/` answered 401 with a Bearer challenge in
  0.4 s; GitHub's `latest/download/VERSION` a 302 to `v0.101.0/VERSION`, so the release
  needs redirects followed. A black-holed address, a loopback listener that never
  answers (plain and TLS), and `HTTPS_PROXY` pointing at one each gave no answer by the
  deadline, and `ExitProcess` ended the process at five seconds every time. An unknown
  name failed in 0.2 s; a refused port, and a dead proxy, took 2 s (Windows tries the
  connection again).
- **`NO_PROXY` is ignored**: with `HTTP_PROXY` and `HTTPS_PROXY` at a silent listener and
  `NO_PROXY=localhost,127.0.0.1` (and lower case), requests to `localhost` and
  `127.0.0.1` went to the proxy and hung. So `pull` from a registry on this machine goes
  through a proxy that's set; [gaps](gaps.md) says so, and doctor warns.
- **`GetVolumePathNameW` fails on a `subst` drive** (error 87); `GetVolumeInformationW` on
  the drive's root works. It works for paths that don't exist. C: and D: are NTFS, E: is
  ReFS (a Dev Drive); both keep permissions and reparse points.
- **Breakaway**: Git Bash, PowerShell and cmd, as Claude Code starts them here, are in a
  job that lets processes break away. A job that doesn't wasn't found on this machine; that
  check is unit-tested only.
- **`zigsaw rm` with the manifest gone** deleted the commands and the ref, then failed on
  the missing blob; with the config gone, it worked. Building again afterwards worked both
  times. Fixed as above, so that doctor's "`zigsaw rm`, then build" does what it says.

## Files

- `src/doctor.zig` (new): the report, its sections and checks, the probes; unit tests for
  the report and summary, the variables' list, the registry setting, path shape, PATH from
  an environment block, breakaway flags, integrity names.
- `src/main.zig`: `doctor` before the store opens, its usage; `rm` of an app whose
  manifest is gone.
- `src/Store.zig`: `locate`, `rootFrom`, `imageReadable`; listings of a store that isn't
  there are empty.
- `src/ps.zig` (`allRecords`, with its test), `src/hkcu.zig`, `src/grants.zig`,
  `src/upgrade.zig`, `src/volumes.zig`, `src/snapshot.zig`, `src/schedule.zig` (with a
  test), `src/shortcuts.zig`, `src/associations.zig`, `src/updates.zig`,
  `src/credentials.zig`: what finds a problem, on its own (see Decisions).
- `src/exports.zig`: `repair` goes on past an app it can't read; `onPath` public, `list`
  of a store with no `bin`. `src/drive.zig`, `src/Registry.zig`: what doctor reuses made
  public. `src/acl.zig`: `integrityRid`. `src/regkey.zig`: `getDword`. `src/win32.zig`:
  declarations.
- `tests/doctor.sh` (new), a step for it in `.github/workflows/reproduce.yml`, a row in
  `tests/standard-user.sh`; `tests/netprobe.zig`: `silent`.
- README, `docs/gaps.md`, `docs/testing.md`; 0.102.0 in `build.zig.zon` and `zigsaw.json`.

## Results

| what | result |
|---|---|
| unit tests | 291 pass, on the final source; new in `src/doctor.zig`, `src/ps.zig` (`allRecords` leaves a gone run's record) and `src/schedule.zig` (a task's program) |
| `tests/doctor.sh` | 0 failed, four times: 83 ok with the `B:` rows (59 s), then 80 and 81 ok on the final build with a build's stale `B:` left by `tests/stop.sh` (59-64 s; the suite now checks doctor's note against it rather than skipping) |
| `tests/sandbox.sh`, `volumes.sh`, `shims.sh`, `ps.sh`, `stop.sh`, `exec.sh`, `up.sh` | 142, 135, 57, 44, 48, 56 and 91 ok; 0 failed: the code that settles what doctor finds, unchanged |
| `tests/updates.sh`, `rollback.sh` (under `tests/zot.sh`) | 42 and 55 ok, 0 failed |
| `tests/install.sh`, `upgrade.sh` | 45 and 32 ok, 0 failed, on the final build |
| `tests/reach.sh` | 32 ok, 1 failed, twice: "rm takes it all out of the real registry", as `HKCU\Software\Zigsaw` has grant records of this machine's kit stores (iterations 79, 86 and 87, the last written by `tests/zot.sh`'s zot today), which tests wrote without `ZIGSAW_GRANTS_KEY`; not this change's |
| by hand | doctor on a store that isn't there leaves it so; on the kit's store (a Dev Drive) the store's files, `HKCU\Software\Zigsaw` and the test key are as they were after it; `doctor <app-id>`; the network on the real ghcr.io and GitHub |
| the package | zip `79420cce`, 0.102.0; Defender finds nothing in its six programs |

The suites before `install.sh` ran on the build before the last change to doctor (a
request that can't be started is a note instead of the end of the report); `install.sh`
and `upgrade.sh` build zigsaw themselves, and ran on the final one, as did the last
`doctor.sh` and `reach.sh`.

`doctor` takes about a second, almost all of it `schtasks /query`, which lists every
scheduled task to find the daily checks; with the network, it's as long as the slowest
answer, at most five seconds.

## Not checked

- **`tests/standard-user.sh`'s new row**, as a real standard user: only on CI.
- **A job that doesn't let processes break away**, an ARM64 machine, a FAT or network
  drive, a store owned by Administrators, Windows' own proxy and proxy scripts: unit-tested
  or read from the code, not seen.
- **Doctor on your real store**: not run here, as no zigsaw from `zig-out` runs without
  `ZIGSAW_HOME`.
- **`tests/reach.sh`'s registry row on a machine whose `HKCU\Software\Zigsaw` is clean**:
  CI's runners are.

## Not this time

- `--fix`, and `--json`.
- Hashing installed blobs and deployments.
- Checking that a saved login works, which would send it.
- Visual Studio for `"host": ["msvc"]` recipes, and the Visual C++ runtime PHP's images
  need: the builds and runs that need them say so.
- `NO_PROXY`, and Windows' proxy settings, in zigsaw's own requests: doctor says when they
  matter.
- A shorter way to list the daily checks than `schtasks /query`, which takes about a
  second, most of doctor's time.

## Yours to do

- Commit and push (`src/doctor.zig`, `tests/doctor.sh` and this file are new). I read the
  Reproduce run, `tests/doctor.sh` and the standard-user job first.
- The tag `v0.102.0` is yours; I read the Release run after it.
