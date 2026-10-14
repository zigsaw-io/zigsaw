# Iteration 18: your folders, and the first release

Concluded 2026-10-14.

## Outcome

- **Your folders as a permission**, like Flatpak's `xdg-documents`:
  `desktop`, `documents`, `downloads`, `music`, `pictures` and `videos` in an
  app's `filesystem` permissions, on the command line and in overrides.
  Each is a directory junction in the app's home to your folder, where the
  app, and Windows' file dialogs, look for it; `low` labels it and
  `appcontainer` grants it, as any host path.
- **File dialogs show them**: an app's Open dialog goes to Documents by its
  name, and pins Downloads and Documents in Quick access, in all three
  sandboxes.
- **`--nofilesystem`**, and overrides that replace an app's own permission
  for a location (`documents:ro`), so that what an app declares can be taken
  back.
- **The six GUI apps declare the folders they open files from**: 7-Zip,
  Notepad++, SumatraPDF, Text Editor and Rnote Desktop, Documents and
  Downloads (Rnote Pictures too), VLC Desktop, Downloads, Music, Pictures and
  Videos.
- **Images' permissions from a later zigsaw are left out, with a warning**,
  rather than refused.
- **The release workflow's first run found a test bug**; fixed, and the
  first release is to be 0.18.0.

## Starting decisions

From the planning session (plan file
`let-s-plan-iteration-18-pure-lampson.md`). Iteration 17's four app images
were on ghcr.io with its digests, and its Reproduce run green (48 minutes);
`v0.17.0` wasn't tagged yet.

- Scope, your picks: **the user's folders as a permission**, and **checking
  the v0.17.0 release**. Not this time: a registry isolation probe, GTK in
  CI.
- **The published GUI apps declare the folders, writable**, over read-only
  or overrides only; six images to republish.
- **Folder names go in `filesystem`**, as Flatpak's do, over a field of
  their own that zigsaw 0.17.0 would have ignored: 0.17.0 refuses the
  republished images.
- Mine, approved with the plan: the six names, `:ro`/`:rw` as for paths;
  `--nofilesystem`; junctions; `ZIGSAW_USER_FOLDERS` for tests; your real
  folders used once, under `soft`.

Decided along the way, with you:

- **No 0.17.0 release; the first is 0.18.0.** The Release run for the
  `v0.17.0` tag failed in `tests/install.sh`, before publishing anything
  (see below). The tag stays, without a release.

## What was built

### The folders

- [`src/folders.zig`](../src/folders.zig) (new): for each of the six folders,
  where yours is (`SHGetKnownFolderPath` in zigsaw's own process, or
  `<ZIGSAW_USER_FOLDERS>\<Name>`), and where the app will look for it: the
  folder's `User Shell Folders` value, as stored (`%USERPROFILE%\Documents`),
  expanded with the run's environment, as Windows expands it in the app.
  A folder the app may use is linked there, if that's in its data
  directory; one it may not use loses its link. Only links are ever
  removed: a folder of the app's own, with files, stays, with a note. A
  folder you don't have, one on a network share, and one the app's data is
  in, aren't linked. Junctions are made with `FSCTL_SET_REPARSE_POINT` and
  read back with `FSCTL_GET_REPARSE_POINT`.
- [`src/oci.zig`](../src/oci.zig): `UserFolder`; `FsGrant` says what a
  permission is (`cwd`, a path, a folder, or a name this zigsaw doesn't
  know); configs may name unknown lowercase names.
- [`src/run.zig`](../src/run.zig): the permissions a run gets are the app's,
  then its overrides', then the command line's; folders are resolved once
  the run's environment is known, and granted as host paths; every run's
  profile has `AppData\Roaming\Microsoft\Windows\Recent\AutomaticDestinations`,
  where file dialogs keep Quick access.
- [`src/override.zig`](../src/override.zig), [`src/main.zig`](../src/main.zig):
  `--nofilesystem`; a location's setting in a layer replaces the layers
  below for it.
- [`src/win32.zig`](../src/win32.zig): junction and file attribute bindings.

### Tests

- Unit tests: folder names and unknown names, the layers' merge with
  `--nofilesystem`, expanding `User Shell Folders` values, and junctions
  made, read, replaced and removed without their target.
- [`tests/sandbox.sh`](../tests/sandbox.sh): 22 checks with fake folders,
  one holding a junction that denies listing, as Windows' `My Music` in
  Documents: links in each sandbox, labels and grants, `--nofilesystem`,
  an app's own Documents, and that `rm --delete-data`, `prune --data` and
  `--ephemeral` leave the folder's files.
- [`tests/guiapps.sh`](../tests/guiapps.sh): where a desktop program finds
  Documents (and doesn't find Downloads) in each sandbox, with
  [`tests/hostprobe.zig`](../tests/hostprobe.zig) as an app that declares
  `documents`; the apps' links.
- `tests/gtk.sh`, `tests/published.sh`, `tests/build.sh`: fake folders, or
  none, so that no test run labels or grants yours.
- [`tests/install.sh`](../tests/install.sh): the scratch directory's long
  name (below).

### Code map

| File | Change |
|---|---|
| `src/folders.zig` (new) | your folders, junctions |
| `src/oci.zig`, `src/run.zig`, `src/override.zig`, `src/main.zig`, `src/win32.zig` | folder permissions, `--nofilesystem`, Quick access |
| `recipes/7zip.json`, `notepad-plus-plus.json`, `sumatrapdf.json`, `vlc.json`, `gnome-text-editor.json`, `rnote.json` | the folders they declare |
| `tests/sandbox.sh`, `tests/guiapps.sh`, `tests/hostprobe.zig`, `tests/hostprobe/app.json` | folder checks |
| `tests/gtk.sh`, `tests/published.sh`, `tests/build.sh` | fake folders |
| `tests/install.sh` | 8.3 names |
| `build.zig.zon`, `scripts/install.ps1` | version 0.18.0 |
| `README.md`, `docs/findings.md`, `docs/gaps.md` | your folders, probes, gaps |

## Results

### The v0.17.0 release run

The `Release` workflow ran for the first time on the `v0.17.0` tag: the
version check, unit tests and packaging passed, and `tests/install.sh`
failed three checks, so nothing was published. The workflow leaves `TEMP`
as the runner has it, `C:\Users\RUNNER~1\...`, an 8.3 short name, unlike
the Reproduce workflow, which moves it to `D:\a\_temp`. The test's scratch
directory then had the short name, while the installer writes the
directory to PATH as `GetFullPath` gives it, long, and zigsaw names itself
by its long path in shims: the same directory, spelled two ways. Reproduced
here with `TMPDIR` set to a short name; the test now takes the long name
(`cygpath -wl`), and passes either way. The installer and zigsaw were
right.

### Tests

- Unit tests: 84 pass (80 before).
- `tests/sandbox.sh`: 70 pass, 22 of them new (10 s).
- `tests/guiapps.sh`: 15, all as intended (two known gaps), in its last two
  runs. In three runs before, VLC's row failed once in each sandbox, not
  the same one twice: its window hadn't come up within 15 s, or VLC
  hadn't ended after closing it; the first of those runs was while Rnote
  built. By hand, the same row passed 15 times out of 15, its window up in
  1 to 3 s. Not found why; it may be older than this iteration.
- `tests/gtk.sh`: all pass (7 min), Text Editor and Rnote with fake
  folders in all three sandboxes.
- `tests/shims.sh`, `tests/store.sh`: all pass.
- `tests/install.sh`: 16 pass, also with the temporary directory under an
  8.3 name.
- `tests/matrix.sh`: as intended, three known gaps (102 s).
- `tests/build.sh` and `tests/published.sh` weren't run: nothing that
  builds changed, and the configs' format is the same. CI runs both.

### Reproducibility

| Image | Manifest | Was |
|---|---|---|
| `org.7_zip.7zip` 26.04 | `9ba65a93` | `d0737f7b` |
| `org.notepad_plus_plus.NotepadPlusPlus` 8.9.8.1 | `9966f0e9` | `33fb12bf` |
| `org.sumatrapdfreader.SumatraPDF` 3.6.1 | `90f00fc5` | `ec440211` |
| `org.videolan.VLC` 3.0.24 | `c1e9cc23` | `c0b1ec03` |
| `org.gnome.TextEditor` 51.0 | `7bc27324` | `8f60f2b0` |
| `com.github.flxzt.rnote` 0.14.2 | `93391da1` | `c3332645` |

The same from `D:\zs\a` and `D:\zs\b`. Only their configs changed: each
layer is the one on ghcr.io already, so publishing them uploads a config
and a manifest each. No other image changes. Rnote took 19 minutes to
build in each store, Text Editor 2 to 3.5.

### By hand

- Notepad++'s Open dialog, with fake folders, in screenshots: typing
  `shell:Personal` goes to Documents, which the dialog names as such, with
  the fake folder's file, in all three sandboxes; Downloads and Documents
  are pinned in its navigation pane once the run's profile has the folder
  Quick access is kept in.
- Your real folders, once, under `soft`, in a scratch store: hostprobe found
  Desktop, Documents and Downloads in its home, as links to yours; after
  `zigsaw rm --delete-data`, the three held the same number of files as
  before (14, 89, 2555), and none had a label or an AppContainer entry.

## Decisions made along the way

- **`Store.deleteTree` stays as it was.** The plan had it remove links
  before deleting, in case Zig's `deleteTree` followed them; the probe
  showed it doesn't, nor does Git Bash's `rm -rf`, nor ACL inheritance. The
  sandbox suite checks the deletes instead.
- **Every run's profile has the folder file dialogs keep Quick access in**,
  so their navigation pane pins the folders the app has: found with the
  dialog's screenshots, and small enough to do now.
- **Test suites never use your folders**: `tests/gtk.sh` and
  `tests/guiapps.sh` run the apps with fake ones, `tests/published.sh` and
  `tests/build.sh` with none.

## Findings

See [findings.md](findings.md#the-users-folders). Besides:

- A Release job's `TEMP` is an 8.3 path; Git Bash's `/tmp`, and so
  `mktemp`, follow it, whatever `TMP` says once the shell runs (`TMPDIR`
  does move it).
- Killing a background build through the harness stopped the outer shell
  only; the loop's subshell went on to the next store, and an interrupted
  build leaves `B:` mapped (`subst B: /D`).

## Known gaps

- Folders are granted whole, and a writable one is labelled low until
  `zigsaw rm` under `low`.
- Only the six folders; not Saved Games, Favorites, Public folders, or a
  folder inside one.
- A folder kept at a path with a variable other than `USERPROFILE` in it,
  or on a network share, isn't linked.
- Quick access pins Downloads and Documents, not Desktop.
- zigsaw 0.17.0 refuses the republished apps.
- `tests/guiapps.sh`'s VLC row fails now and then.
- 7-Zip's registry settings, `LocalLow` and the profile folder are still
  the real ones.

## Suggested for iteration 19

- You publish the six images, push, and tag `v0.18.0`; then the release
  run, `irm | iex` from the real release, and its hashes against a local
  build.
- Why VLC's window is sometimes slow in `tests/guiapps.sh`.
- Registry isolation (7-Zip), still.
- GTK in CI, still.
