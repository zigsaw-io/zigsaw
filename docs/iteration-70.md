# Iteration 70: As a real standard user

Built 2026-11-04. "Non-admin first" has been the rule since iteration 1 and had never
been tried as a non-admin: this machine's account is an administrator's with a filtered
token, and GitHub's runners are elevated. Now a suite runs in a real standard user's
account, and it holds. The same work found that Defender can flag zigsaw by its exact
bytes, and that releases only reproduce on a checkout with CRLF. Apart from that, my test
kits labelled your real folders twice in iterations 68 and 69, so a store elsewhere no
longer gets them, and `zigsaw grants` says what's been changed. zigsaw **0.70.0**. Nothing
to publish. Findings are in [findings.md](findings.md#as-a-real-standard-user).

## Outcome

- **As a standard user, it works**: `tests/standard-user.sh` in an account in `Users`
  only, 28 rows of its own and 416 of nine suites, none failed. That covers installing,
  pulling from ghcr.io, all three sandboxes, shortcuts, kinds of file, Credential
  Manager, a build, and your real folders, labelled and taken back.
- **The loopback exemption works for one too**, the question left open since iteration
  50: 2 to 7 ms, and it's taken back.
- **Defender flagged a build of this iteration by its bytes**: `Bearfoos.A!ml` for the
  working tree packaged as 0.69.0, and nothing for the same files with the version
  changed. Nothing published is affected: v0.68.0's and v0.69.0's programs scan clean
  and ran clean. The Release workflow now scans before it publishes.
- **Releases reproduced only on a CRLF checkout.** `src/windows/*` weren't pinned, so a
  runner built its manifest with CRLF. With them changed to CRLF, a build here is byte for
  byte v0.69.0's `zigsaw.exe`. They're pinned from now on.
- **A store elsewhere leaves your real folders out**, and says so, until `zigsaw override
  --global --real-folders`. A forgetful test kit is now harmless.
- **`zigsaw grants`** lists what's been changed outside the stores, including what a deleted
  store left, and low labels on your folders no record explains. `zigsaw repair` takes back
  a deleted store's. Stores now know each other's labels.
- **PHP 8.5.12 changed what a memory-limit fatal does**: it doesn't reach an extension's
  `zend_try` any more. Iteration 69's red CI run was hiding that behind a version number
  in a test ([findings](findings.md#php-8512s-memory-limit-and-an-extensions-zend_try)).

## Starting decisions

Yours: standard users and labels, over updates reaching people, a round of rebuilds, or the
Cloud Files bridge; the Upstream workflow started by hand; you make the test account, and I
touch no accounts; a store elsewhere leaves real folders out until told.

Mine: the record in `HKCU\Software\Zigsaw\Grants`; I don't push probes, so the CI job is
first seen on your push; a checkpoint before any fix that wasn't small. Nothing reached it:
each difference turned out small, or not a difference.

Decided during (mine):

- **A scan before each release, and no changing of bytes to pass one.** If a release is
  flagged, the workflow stops. What to do then is yours: Microsoft has a form for false
  positives, which only you can send. Altering a program until a scanner passes it isn't
  something I'd build.
- **Rows with real folders run only in the throwaway account**, as `ZIGSAW_USER_FOLDERS`
  bypasses the guard, and a bug there would otherwise reach your Documents. So
  `tests/reach.sh` checks a tool's real folders only there.
- **MSVC's section is left out as the standard user**, for the reason in findings.

## What was built

- `src/ledger.zig`; `src/folders.zig`, `src/override.zig` (the guard); `src/grants.zig`
  (`show`, `settleOrphans`, `takeBackLabel`); `src/Store.zig`, `src/regkey.zig`,
  `src/main.zig`; 0.70.0.
- `tests/asuser.zig`, `tests/standard-user.sh`, `scripts/defender-scan.sh`;
  `scripts/install.ps1` (`-Uninstall` runs `repair`, and the record's key goes when empty).
- 18 rows in `tests/sandbox.sh`, 2 in `tests/install.sh`, 1 in `tests/self.sh`; `SECTIONS` in
  `tests/build.sh`; `.gitattributes`; Release's scan step; Reproduce's `standard-user` job
  and the `suites` job's check that no suite labelled the runner's folders.
- `tests/build/php/test.php`, committed already as `9e97111`, with v0.69.0 on it.

## Results

As `zstest`, in `Users` only, on Windows 11 26300:

| Suite | Rows | Failed |
|---|---|---|
| its own | 28 | 0 |
| `store` | 16 | 0 |
| `shims` | 55 | 0 |
| `sandbox` | 142 | 0 |
| `batch` | 12 | 0 |
| `ctrlc` | 26 | 0 |
| `network` | 26 | 0 |
| `reach` | 33 | 0 |
| `install` | 19 | 0 |
| `build.sh` base, without MSVC | 87 | 0 |

As this machine's account, on the same build: `zig build test` passes; `store` 16,
`shims` 55, `sandbox` 142, `reach` 33, `install` 19, `network` 26, `self` 18 (zigsaw still
builds itself byte-identical), `build.sh`'s extensions section 17, and `registry` 109 against
two local registries of the published zot; none failed. PHP's section of `build.sh` passes
too, on the commit before this one.

0.70.0's package scans clean, as me: `zigsaw.exe`, `zigsaw-shim.exe`, `zigsaw-shimw.exe`,
`zigsaw-relay.exe`, `zigsaw-host.exe`. No image's digest should move, as no recipe did; CI
checks that.

**`tests/matrix.sh` wasn't run here**, against the plan: the store it would use lacks its
apps, and it would build them cold, which the change didn't seem to justify, as `sandbox`
has what changed. Reproduce's `suites` job runs it on your push.

## Not checked

- **The CI job has never run.** `CreateProcessWithLogonW` from an Actions step (its job
  object and session) can't be tried without a push. If it fails, that's one red job, and a
  scheduled task under that account is the fallback, without a desktop and maybe without
  Credential Manager.
- **Release's scan on a runner**, which may say it couldn't scan, if the runner's Defender is
  off. Then it's only as good as the scan here, which, with the line endings pinned,
  is now of the same bytes. **That's checked by comparing v0.70.0's hash with a build here,
  after the Release run.**
- **Signing in as `zstest` and using the desktop**: Explorer, the Start menu, Settings. The
  rows look at a shortcut's file and a key, and start nothing from Windows' shell.
- **A verdict that comes later**: Defender could flag a released file after the scan.
- **Two people on one machine at once**, or an account a domain's policy restricts.

## On this machine

- `icacls` shows no label on Desktop, Documents, Downloads, Music, Pictures, Videos, your
  profile or the repository after all of it, and `zigsaw grants` says nothing's changed.
  The one entry the real record had by then was a low label from my zot, on a scratch folder
  under `D:\zs\i70`, which `zigsaw grants` named; removing that app took it away.
- **Windows Security's history now lists `Bearfoos.A!ml` several times**, from today, for files
  under `C:\Users\zstest` and `E:\zs\i70`. They're this false positive, from my runs and
  scans. You may have seen notifications.
- **A stray command of mine**: while planning, `tests/build.sh --help` started a build, as it
  has no such option. It left two empty folders in `/tmp`, since deleted.
- `E:\zs\i70` holds this iteration's scratch, including flagged programs in `scan\package`
  and `v\tree-out`. Delete it when you like: it's labelled nothing of yours.
- `zstest`'s still there. Each run cleans up after itself, so nothing of zigsaw's is left in it.

## Next

- **Commit and push.** Nothing to publish, and `git add --chmod=+x scripts/defender-scan.sh
  tests/standard-user.sh`. `.gitattributes` and the workflow are on the list that re-checks
  GTK's and Qt's families, so it's a long run. I read it, with `standard-user`'s first run.
- Tag **v0.70.0** after that, and I read Release, its scan, and compare its programs' hashes
  with a build here.
- **Keep `zstest` until both have been read**, in case the CI job needs local comparison. Then, in
  an elevated prompt, `net user zstest /delete`, and remove its profile under Settings, System,
  About, Advanced system settings, User Profiles.
- If you'd like: sign in as `zstest` once, and try the Quick start by hand.
- Later: reporting `Bearfoos.A!ml` to Microsoft, if a release is ever flagged; Go 1.27.3 and
  its 5 apps; Python 3.14.10; BusyBox and Zig 0.17.1; updates that reach people who don't ask.
