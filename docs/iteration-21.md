# Iteration 21: Files App

Concluded 2026-10-15.

## Outcome

- **Files 4.3**, a file manager written in C# with WinUI 3, built from its
  release tarball with .NET's SDK image and run on .NET's runtime image:
  [`recipes/no-publish/files.json`](../recipes/no-publish/files.json),
  `community.files.Files`, named "Files - Zigsaw build". It starts, shows
  the drives, opens a folder given on its command line, and keeps its
  settings with its data, its registry values in a hive; it has a shortcut
  with its icon and the windowless shim.
- **Without its package.** Files' code asks its MSIX package for its name,
  version and data folders, which fails in a plain program. A
  patch adds classes of the same names in Files' namespace, which Files'
  code then uses, and fixes the five other things that stopped it, one by
  one.
- **The same image in two stores**, after turning off a CsWinRT generator
  that isn't deterministic and leaving out a `.winmd` that isn't either.
- **`soft` only.** At low integrity and in an AppContainer, Windows' storage
  APIs refuse a program without a package: Files starts and lists folders,
  but shows no drives.
- **A suite of its own**, [`tests/files.sh`](../tests/files.sh): 8 checks,
  46 s with the images in the store.

## Starting decisions

Made in the session, from "check what we need to build
files-community/Files". There was no plan file.

- What Files' repository needs (Visual Studio's MSBuild, C++ projects on
  the v145 toolset with ATL, NativeAOT, an MSIX package) was looked at
  first; **you chose to try the C# projects alone**, with the SDK image. They
  built; the program stopped at once without its package.
- Of three ways to give Files what its package gives it (installing it as
  an MSIX, a package with an external location, a patch), **you chose the
  patch**.
- After low and AppContainer were tried, **you chose `soft` only**, over
  making Files' drives work without WinRT's storage, or only hiding its
  permission dialog.
- **The Dev flavour, named "Files - Zigsaw build"**: you chose it over the
  stable flavour with its updater turned off, and over the stable name on
  the Dev flavour.
- **Reproducibility and tests**, then the docs.
- Mine: version 4.3, the release tag, over `main`; the id
  `community.files.Files`, from its domain, as Files isn't on Flathub; x64
  only; framework-dependent on .NET's runtime image and ReadyToRun; two
  patches, one to run without a package and one for the name.

## What was built

### The recipe

- [`recipes/no-publish/files.json`](../recipes/no-publish/files.json): the
  tarball of the `v4.3` tag; a vendor step that restores `Files.App` and
  `Files.App.Server` for x64 (3.3 GB, 4.5 minutes); `dotnet publish` with
  the build's properties as `-p:` options (the projects set some of them
  themselves, which beats the environment), from a `nuget.config` whose one
  source is `vendor`; `Assets` copied in; the `.winmd` and PDBs left out.
  It keeps `HKCU\Software\Files Community`, and has the network, the working
  directory and the six user folders. In `recipes/no-publish/`, as it runs
  on .NET's runtime image, which can't be published.
- [`files/unpackaged.patch`](../recipes/no-publish/files/unpackaged.patch),
  14 files: `Unpackaged.cs` (`Package`, `ApplicationData` with folders that
  are paths and a `StorageFolder` only when asked, `ApplicationDataContainer`
  over a registry key, `ApplicationLanguages`), the project built unpackaged
  with the Windows App SDK in its directory and its manifest copied next to
  it, a launch from the command line recognised by Files' own path, the
  Windows App SDK's resource loader, and no Libraries watcher without a
  Libraries folder.
- [`files/name.patch`](../recipes/no-publish/files/name.patch): the
  manifest's three names and the splash screen's label.
- No change to zigsaw.

### Tests

- [`tests/files.sh`](../tests/files.sh): Files builds; it's laid out as an
  app without a package; it's on .NET's runtime image; the shim and the
  shortcut, with the icon in its executable; it starts up and finds the
  drives (from its log, as Files carries on past what goes wrong at
  startup); it opens a folder given on its command line (in the tabs it
  saves); its settings in its data directory and its registry values in its
  hive, none in the real registry. It ends Files rather than zigsaw after
  each run, and builds .NET's images and Files into its store if they're not
  there. Not in CI, as .NET's images aren't published.

### Code map

| File | Change |
|---|---|
| `recipes/no-publish/files.json`, `recipes/no-publish/files/` (new) | Files and its two patches |
| `tests/files.sh` (new) | its suite |
| `README.md`, `docs/recipes.md`, `docs/findings.md`, `docs/gaps.md` | Files, the .NET notes it added, findings, gaps |

## Results

### Tests

- `tests/files.sh`: 8 pass (46 s; `FILES_HOME` a store with .NET's images
  and Files, and the zigsaw 0.19.0 that built them).
- No other suite was run: zigsaw's code and the published recipes didn't
  change.
- By hand: Files in each sandbox, with pictures; `C:\Windows` opened from
  its command line in each; its shortcut; at low integrity, WinRT's storage
  against .NET's file APIs on three paths.

### Reproducibility

| Image | Manifest | Layer |
|---|---|---|
| `community.files.Files` 4.3 | `7d322a26` | 61 MB, for 168 MB of files (745) |

The same in two stores (`D:\zs\i20\p` and `q`), the NuGet packages vendored
afresh in each (`c594e0af`). With the vendor step cached, a build takes 4
minutes.

## Decisions made along the way

- **Classes named after the APIs, rather than changing their 80 uses.** The
  patch touches 14 files; most of Files' code is unchanged, which should
  keep the patch applying to later versions.
- **Settings in the registry**, under the key where Files keeps its other
  registry values already, so that zigsaw keeps them with them, and Files'
  processes see each other's changes at once, as with a package's settings.
- **Data folders as paths.** The first patch made them `StorageFolder`s at
  startup, which hung Files in an AppContainer; the six places that need a
  `StorageFolder` make one when they run.
- **Turning off CsWinRT's AOT optimizer** for reproducible builds, as Files
  runs with the JIT; its helpers are made at run time instead.
- **`Assets` copied by the recipe**, rather than a change to Files' project.

## Findings

See [findings.md](findings.md#files). Besides:

- Microsoft Defender quarantined zigsaw 0.19.0 as `Trojan:Win32/Bearfoos.A!ml`
  during a Files build, ending it, and then the other copies of the same
  build, `zig-out\bin\zigsaw.exe` among them
  ([other findings](findings.md#other-findings)). You restored one.
- `tests/files.sh` first killed `zigsaw.exe` to end a run, which left
  Files' key in the real HKCU, until the next run settled it.

## Known gaps

- Files in `soft` only (above).
- What Files' package would give it: starting with Windows, its protocol
  and alias, its update task; its C++ parts (the Explorer replacement's
  launcher, the open and save dialogs), which need Visual Studio. Changing
  its language wasn't tried.
- The Dev flavour; no NativeAOT.
- 3.3 GB of vendored packages.
- `zig-out\bin\zigsaw.exe` and `D:\zs\i19\bin\zigsaw.exe` are still in
  quarantine.

## Suggested for iteration 22

- Defender: whether the released v0.19.0 is flagged too, reporting the
  false positive to Microsoft, and what in zigsaw sets it off.
- Files' drives at low integrity and in an AppContainer, made without
  WinRT's storage (the shell's names and icons), and its permission dialog
  for those sandboxes.
- Clicking through Files: its settings, changing its language, copying and
  deleting files, archives, the tray icon.
- Flatpak's "extra data", the iteration 19 leftovers and the rest
  suggested in [iteration 20](iteration-20.md#suggested-for-iteration-21).
