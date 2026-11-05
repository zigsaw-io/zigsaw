# Iteration 73: Updates reach people

Built 2026-11-05. The last rounds published fixes for PHP's critical RCEs and for GTK's and
Python's advisories, and v0.72.0 fixed a panic, and none of that reached anyone who didn't run
`zigsaw update` or `install.ps1` by hand. Now a daily check tells them, and zigsaw can upgrade
itself. Nothing installs anything by itself. zigsaw is **0.73.0**. Nothing to publish, as no
recipe changed. How it's used is in [the README](../README.md#being-told-about-updates), findings
in [findings.md](findings.md#telling-someone-something-on-windows).

## Outcome

- **A daily check tells you what's waiting**: a scheduled task of the user's own, with no
  administrator, reading manifests and one small file, and a Windows notification. Clicking it
  opens a terminal listing what's waiting and the commands that install it.
- **`zigsaw updates`** lists what the last check found, **`updates check`** looks now, and
  **`updates on|off`** starts and stops it. `zigsaw list` has a line when something's waiting.
- **`zigsaw upgrade`** replaces zigsaw with its latest release, once you agree, checked the way
  `install.ps1` checks it.
- **Seen working end to end on this machine, by you**: the real task, against a real moved tag.
  No console flashed, the notification appeared, the click opened the list, version 1 stayed
  installed, and a second run told nothing.

## Starting decisions

Yours: only ever tell, with no background installing, now or as a setting; on at install, and
saying so; zigsaw itself covered, with `zigsaw upgrade`.

Mine, in the plan: a click opens the list and installs nothing; failed checks stay silent; shims
say nothing; the check also runs on metered connections.

Changed during (mine, not in the plan, so say if you disagree):

- **What's waiting is told again every three days until you've looked**, where the plan said once.
  The first test showed why: Explorer reported the notification as shown, you were looking at my
  question, and there was nothing to find afterwards. Telling once could have hidden a security fix
  for good. Clicking, or running `zigsaw updates`, ends it. Something new is told at once.
- **A `VERSION` file in each release**, instead of reading GitHub's redirect for the latest version.
  std's `fetch` follows redirects without showing them, and a folder in a test then works exactly
  as a release does. Nobody can upgrade to a release before 0.73.0 this way, which nothing needs.
- **The check doesn't count as telling while Windows holds notifications back**, as under Do Not
  Disturb or a full-screen app: it waits for the next one.

## What was built

- `src/updates.zig`: what's waiting, kept in `updates\state.json`, and when to tell. `update.zig`'s
  check is now shared with `update --check`.
- `src/schedule.zig`: the task, through `schtasks.exe` by its full path, a name per store. `updates
  off` is remembered in `updates\off`. `grants` lists tasks; `repair` removes those of stores since
  deleted, and rewrites this store's after zigsaw moves.
- `src/notify.zig`, a sixth program, **`zigsaw-notify.exe`**: GUI subsystem, so nothing flashes. It has
  no network code: it runs zigsaw and shows what it says. A task whose store is gone removes itself.
- `src/upgrade.zig`: downloads, checks the hash, starts the new program to see it runs here and is
  the version it should be, and only then swaps. `.new-` files go in `bin`, for its permissions.
- `install.ps1`: starts the check for the default store in the default directory only, with
  `-NoUpdateCheck`; takes a zip without the new program, so `-Version 0.72.0` still works, and takes
  the task away then; removes it all on `-Uninstall`.
- `LICENSE` pinned to LF, the only file in v0.72.0's zip that differed from a build here.

## Results

| What | Result |
|---|---|
| `zig build test` | 169 passed |
| `tests/updates.sh` | 40 ok (new); 14 without a registry |
| `tests/install.sh` | 40 ok (21 new rows, upgrade and the daily check) |
| `tests/registry.sh` | 111 ok |
| `tests/self.sh` | 20 ok; its builds of all six programs are the same bytes as `zig build -Dstrip`'s |
| `tests/shims.sh`, `tests/store.sh` | 55 ok, 16 ok |
| Defender on the package | all six clean |
| v0.72.0 | its five programs match a `-Dstrip` build here, the first proof of iteration 70's pin |

The first run of `shims.sh` had 7 failures, from my empty seed folder: BusyBox's upstream refuses
downloads. Seeded, 55 of 55.

Found by testing, and fixed: std's rename can't move a running program aside (`FileBusy`), so
`upgrade` failed on exactly what it's for; and `2>$null` under `'Stop'` made PowerShell take zigsaw's
notes on stderr as failure, which broke uninstalling.

Found, and not fixed: a source on plain `http://` that redirects to `https://` panics `zigsaw build`,
from Zig's std. No published recipe has one. It's in [gaps.md](gaps.md).

## Not checked

- **A standard user's task**: only CI's `standard-user` job can show it, as `zstest` is gone from here.
  It has no desktop, so it makes and removes tasks and doesn't start one.
- **A runner's session**: the row that starts the task is skipped, with a note, where the user has
  no desktop.
- **The daily trigger firing by itself.** The task was run by hand, and its settings read back; a
  fresh task's next run showed as tomorrow, within the hour after noon.
- **A real upgrade from one release to the next**: tested from a folder, and over HTTP with redirects
  against a local server. Direct TLS to GitHub was seen only as a 404 for `VERSION`, as no release has
  one yet. The first real one is v0.73.0 to the release after it.
- **Do Not Disturb**: `SHQueryUserNotificationState` said it accepted notifications here, and the
  path for when it doesn't was only tested through `--quiet`.
- **Windows 10**, and machines whose policy refuses scheduled tasks.
- **Notes on the newer runner image**, still open: changing `reproduce.yml` makes this push re-run
  `qt-suites`, so it's read sooner than the 2026-11-09 weekly run.

## On this machine

Scratch is in `E:\zs\i73` and `D:\zs\i73tmp`. No scheduled task is left, `HKCU\Software\ZigsawTest` is
gone, your real store has no `updates` folder, and your six folders and the repository have no low
labels or capability ACEs. So **you don't have the daily check yourself** until you install 0.73.0.

## Next

- **Commit and push**: `git add --chmod=+x tests/updates.sh`, and the new `src/notify.zig`,
  `src/schedule.zig`, `src/updates.zig` and `src/upgrade.zig`. It's a long run. I'll read Reproduce,
  `standard-user` and `qt-suites` first.
- **Tag v0.73.0**, your call: this reaches nobody without it, and those on earlier versions only once
  they run `install.ps1` again. I'll read Release, its scan and hashes, and check that `VERSION` is there.
- Later: signing images and releases, which the trust in `upgrade` is waiting for; the report's blind
  spots (PHP's, PostgreSQL's, Qt's and GLib's own notices, a column for what ships); Python 3.14.10 in
  Meson and Qt's SDK; zlib when it has a release.
