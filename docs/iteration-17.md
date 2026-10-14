# Iteration 17: apps zigsaw didn't build, and zigsaw without Zig

Concluded 2026-10-14.

## Outcome

- **Four prebuilt GUI apps**: 7-Zip 26.04, Notepad++ 8.9.8.1, SumatraPDF 3.6.1
  and VLC 3.0.24, packaged from the archives their projects publish, with
  Start menu shortcuts and the kinds of file they open. Each opens a file
  given with `--file` in all three sandboxes, 7-Zip's file manager in an
  AppContainer aside, and keeps its settings in its data directory, 7-Zip
  aside, whose settings are in the registry.
- **Where Windows sends a program that asks it for its folders**: AppData
  follows the profile zigsaw points `USERPROFILE` at, so programs that don't
  read `APPDATA` still keep their settings in the app's data directory. The
  registry, `LocalLow` and the profile folder don't follow it, and the
  user's Documents and Desktop vanish from file dialogs.
- **7-Zip unpacks what recipes can't**: its image is made from its own
  installer, and a recipe with it in its `sdk` unpacks a `.7z` or an
  installer in a build command.
- **zigsaw installs without Zig**: `install.ps1`, from a release, puts it in
  `%LOCALAPPDATA%\zigsaw\bin` and on PATH, upgrades it while it runs apps,
  and removes it. A tag `v<version>` has the Release workflow publish the
  release. The programs build to the same bytes from any checkout.
- **`zigsaw version`, `zigsaw repair`**, version 0.17.0, and a licence
  (BSD 3-Clause).

## Starting decisions

From the planning session (plan file
`let-s-plan-iteration-17-sprightly-widget.md`). Iteration 16's images were on
ghcr.io with its digests, and its Reproduce run green (44.6 minutes).

- Scope, the user's picks of four: **prebuilt GUI apps**, findings first, as
  iteration 1 did for command-line tools, and **installing zigsaw itself**.
  Not this time: GTK in CI, a file dialog portal.
- Apps: **7-Zip, Notepad++, SumatraPDF and VLC** (not an Electron or a GPU
  app); **publish those that work**.
- **A workflow publishes zigsaw's releases on a tag**, over the other
  choice, the user publishing and CI checking. Licence: **BSD 3-Clause**.
- Mine, approved with the plan: version 0.17.0; the ids; zigsaw in the
  store's own `bin`; upgrading by running the installer again, with
  `zigsaw repair`, rather than a `self-update`.

Decided along the way, with the user:

- **The user's folders are documented, and planned next**, as a permission
  like Flatpak's `xdg-documents`, over linking them into soft runs now or
  creating empty ones in each app's home.

## What was built

### Installing zigsaw

- [`build.zig`](../build.zig), [`build.zig.zon`](../build.zig.zon): version
  0.17.0, handed to zigsaw as a build option; `-Dstrip` builds zigsaw.exe
  without debug information.
- [`src/main.zig`](../src/main.zig): `zigsaw version` (and `--version`),
  `zigsaw repair`.
- [`src/exports.zig`](../src/exports.zig): `repair` syncs every installed
  app's shims, shortcuts and file associations as installing it would, with
  this zigsaw's shims and path; an app whose shim is running is reported and
  skipped, and the exit code says so.
- [`scripts/package.sh`](../scripts/package.sh) (new): builds with
  `-Dstrip` into a prefix of its own, and lays out
  `zigsaw-x86_64-windows.zip` (the three programs, `LICENSE`, and Zig's
  licence, since its standard library is in them), `install.ps1`,
  `SHA256SUMS` and the release notes, which list the programs' hashes.
- [`scripts/install.ps1`](../scripts/install.ps1) (new), for Windows
  PowerShell 5.1: checks the zip against `SHA256SUMS` before changing
  anything; moves programs that are running aside, and deletes them on the
  next install; runs `zigsaw repair` when apps are installed; adds the
  directory to PATH by reading and writing the registry value as stored,
  so that `%USERPROFILE%` in it stays a variable and the value keeps its
  type; `-Uninstall` refuses while apps are installed. Parameters, or
  variables for `irm | iex`.
- [`.github/workflows/release.yml`](../.github/workflows/release.yml) (new):
  on a `v*` tag, checks the tag against `build.zig.zon`, runs the unit tests,
  packages, runs `tests/install.sh` on the package, and creates the release
  with `gh` and the job's token (`contents: write`); no new actions.
- [`LICENSE`](../LICENSE) (new): BSD 3-Clause.

### The apps

- [`recipes/7zip.json`](../recipes/7zip.json): `7zr.exe` and the x64
  installer, both from 7-Zip's GitHub releases (versioned, unlike
  7-zip.org's `7zr.exe`), and a build command in which `7zr` unpacks the
  installer. Exports `7z`, `7zfm`, `7zg`; the shell extension and
  uninstaller are left out.
- [`recipes/notepad-plus-plus.json`](../recipes/notepad-plus-plus.json): the
  portable zip without its portable marker and updater.
- [`recipes/sumatrapdf.json`](../recipes/sumatrapdf.json): the portable zip,
  one executable.
- [`recipes/vlc.json`](../recipes/vlc.json): the zip, without the MSI's
  sources, the ActiveX control and `vlc-cache-gen`; arguments that skip the
  first-run privacy question and the update check.

### Tests

- [`tests/hostprobe.zig`](../tests/hostprobe.zig) (new,
  `zig build hostprobe`), with [`tests/hostprobe/app.json`](../tests/hostprobe/app.json):
  the probe of [findings](findings.md#where-windows-sends-a-program).
- [`tests/winwait.zig`](../tests/winwait.zig) (new, `zig build winwait`):
  waits for a window by its title or class, and closes it as its close
  button would, waiting for its program to end.
- [`tests/guiapps.sh`](../tests/guiapps.sh) (new, local, 12 checks, about a
  minute on a store that has the apps): rows with an intended result per
  sandbox, as `tests/matrix.sh` has.
- [`tests/install.sh`](../tests/install.sh) (new, 16 checks, 28 s, also in
  the Reproduce and Release workflows), with an app made of a batch file
  ([`tests/install/`](../tests/install/)) that stays up to be installed over.
- [`tests/build.sh`](../tests/build.sh): 7-Zip's image, and a `.7z` source
  unpacked with it ([`tests/build/sevenzip/`](../tests/build/sevenzip/)).
- [`tests/published.sh`](../tests/published.sh): a run for each new app;
  Notepad++ and SumatraPDF, which have no option that exits, must still be
  running after ten seconds.

### Code map

| File | Change |
|---|---|
| `build.zig`, `build.zig.zon` | version, `-Dstrip`, `hostprobe` and `winwait` |
| `src/main.zig`, `src/exports.zig` | `version`, `repair` |
| `scripts/package.sh`, `scripts/install.ps1`, `.github/workflows/release.yml`, `LICENSE` (new) | releases and installing them |
| `.github/workflows/reproduce.yml`, `.gitattributes` | `tests/install.sh`; line endings of `.ps1` and the test's batch file |
| `recipes/7zip.json`, `notepad-plus-plus.json`, `sumatrapdf.json`, `vlc.json` (new), `scripts/published-recipes.txt` | the apps |
| `tests/hostprobe.zig`, `tests/hostprobe/`, `tests/winwait.zig`, `tests/guiapps.sh`, `tests/install.sh`, `tests/install/`, `tests/build/sevenzip/` (new) | probe, GUI matrix, installer |
| `tests/build.sh`, `tests/published.sh` | 7-Zip as an SDK; the apps' runs |
| `README.md`, `docs/findings.md` | quick start, installing zigsaw, prebuilt GUI apps, known gaps |

## Results

### Tests

- Unit tests: 80 pass (the new code is checked end to end).
- `tests/install.sh` 16, `tests/guiapps.sh` 12 (two known gaps),
  `tests/shims.sh`, `tests/sandbox.sh`, `tests/store.sh`: all pass.
- `tests/build.sh`: 109 pass (707 s), 7-Zip's three among them.
- `tests/matrix.sh` wasn't run: nothing a run does changed (the environment
  stayed as it was, see below).

### Reproducibility

| Image | Manifest | Gzip layer |
|---|---|---|
| `org.7_zip.7zip` 26.04 | `d0737f7b` | 2.6 MB |
| `org.notepad_plus_plus.NotepadPlusPlus` 8.9.8.1 | `33fb12bf` | 7.6 MB |
| `org.sumatrapdfreader.SumatraPDF` 3.6.1 | `ec440211` | 10.6 MB |
| `org.videolan.VLC` 3.0.24 | `c0b1ec03` | 82.4 MB |

The same from three stores (`D:\zs\i17\store`, `D:\zs\a`, `D:\zs\b`). No
other image changes.

zigsaw itself, built from two directories with separate caches: with debug
information, `zigsaw.exe` differed in 20 bytes, the time stamp and the
debug directory's GUID, both hashes of a PDB that names the directory; the
shims, stripped already, were the same. With `-Dstrip`, all three are the
same, from a third directory too: `zigsaw.exe` `9a33862c`, `zigsaw-shim.exe`
`190ad7a2`, `zigsaw-shimw.exe` `0e872387`, with these sources.

### By hand

- Notepad++'s Open dialog, in a soft run, in a screenshot: This PC and the
  drives, no Desktop, Documents or Downloads.
- 7-Zip's file manager in an AppContainer, in a screenshot: its root view
  (Computer, Documents, Network), with the archive not opened.

### Measurements

| | |
|---|---|
| The release zip | 1.05 MB |
| Building the four images | 7-Zip 3 s, Notepad++ 2 s, SumatraPDF 2 s, VLC 13 s |
| `tests/install.sh`, packaging included / with a package | 56 s / 28 s |
| `tests/guiapps.sh` on a store with the apps | 59 s |

## Decisions made along the way

- **Releases leave out debug information**, so that they build the same
  anywhere; the plan had a PDB as a release download of its own, and there's
  none. A crash in a released zigsaw prints no symbols.
- **`ProgramData`, `ProgramFiles` and the like stay out of runs'
  environment**: none of the four apps missed them, and builds share it.
- **No zigsaw change for the apps**: what each needed went into its recipe.
- **7-Zip from GitHub**: 7-zip.org's `7zr.exe` has no version in its URL, so
  its pin would break with the next release.

## Findings

See [findings.md](findings.md#prebuilt-gui-apps) for the probe's table and
the four apps in each sandbox. Besides:

- `@import("build.zig.zon")` works in `build.zig` with Zig 0.16, so the
  version has one place.
- A shell function run in the background in Git Bash (`z run ... &`) leaves
  zigsaw running when `kill $!` ends the subshell; started directly, zigsaw
  ends, and its job ends the app with it.
- `Compress-Archive` stores times, so the zip isn't the same twice; the
  programs in it are, and the release notes give their hashes.
- PowerShell wraps an error at the console's width, even in a pipe.

## Known gaps

- The user's Desktop, Documents, Downloads and Pictures don't show in
  apps' file dialogs, and LocalLow and the profile folder are the real ones.
- The registry isn't isolated: 7-Zip under `soft` writes the real
  `HKCU\Software\7-Zip`, which `zigsaw rm` leaves.
- 7-Zip's file manager can't open an archive in an AppContainer.
- At low integrity and in an AppContainer, apps can't add to their taskbar
  buttons.
- Releases aren't signed; the zip's hash comes from the same release.
- The release workflow hasn't run: it needs a tag.
- GTK's images, gettext and Rnote still aren't checked in CI.

## Suggested for iteration 18

- The user publishes the four images, pushes, and tags `v0.17.0`; then the
  release run, `irm | iex` from the real release, and the release's hashes
  against a local build.
- **The user's folders as a permission**, like Flatpak's `xdg-documents`:
  what soft, low and appcontainer grant, and links in the app's home that
  rm, prune and ACL changes must never follow.
- Registry isolation, which would take code inside the app.
- GTK in CI, still.
