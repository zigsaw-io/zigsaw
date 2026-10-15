# Iteration 20: .NET

Concluded 2026-10-15.

## Outcome

- **Building .NET apps**: an image of Microsoft's .NET SDK 10.0.402
  (`com.microsoft.dotnet.Sdk`), and of the runtime 10.0.13
  (`com.microsoft.dotnet`, with ASP.NET Core and Windows Desktop) made from
  the SDK image's own files, which apps built with it run on.
- **NuGet packages through a vendor step**, as Go's modules and Rust's
  crates are: `dotnet restore --packages vendor`, pinned by hash, then a
  build that restores from that folder without the network. Builds
  reproduce, WPF and Windows Forms included, and run in all three
  sandboxes.
- **Pinta 3.1.2**, an image editor written in C# with GTK 4 and libadwaita,
  built from its release tarball, running on GTK's runtime and .NET's: it
  starts, opens an image given with `--file` and saves it in place, in every
  sandbox, with a shortcut and file associations.
- **Recipes that mustn't be published**, in `recipes/no-publish/`: .NET's
  are the first. Microsoft's licence for its Windows binaries doesn't allow
  publishing them, so each machine builds these images from Microsoft's
  download, and `scripts/publish.sh` refuses them.

## Starting decisions

From the planning session (plan file
`plan-to-support-building-elegant-pinwheel.md`). v0.19.0 was released,
with Release and Reproduce green.

- Your picks: **a shared runtime image** made from the SDK's files (as
  GTK's runtime is made from its SDK), over two runtime images (base and
  desktop) or self-contained apps; **Pinta** as the app that proves it, over
  PowerShell and ILSpy; the ids **`com.microsoft.dotnet.Sdk`** and
  **`com.microsoft.dotnet`**; .NET only, iteration 19's leftovers waiting.
- Mine, approved with the plan: .NET 10, the current long-term release
  (10.0.13, SDK 10.0.402, out 2026-10-13); apps for an older .NET rebuilt
  for it; Pinta's id from Flathub, `com.github.PintaProject.Pinta`, with
  `msgfmt` from gettext's image rather than GTK's SDK; Pinta out of CI, as
  the other GTK apps are.
- **Decided during, with you**: the licence (below) came up as the work
  started. You chose to **keep .NET's images local**, never pushed, over
  publishing anyway or adding Flatpak's "extra data" (layers each machine
  fetches from the vendor) now, and to put such recipes in
  **`recipes/no-publish/`**, as the place for any recipe like them later.

## What was built

### The SDK and the runtime

- [`recipes/no-publish/dotnet-sdk.json`](../recipes/no-publish/dotnet-sdk.json):
  Microsoft's zip (300 MB; 5,577 files, 808 MB), checked against the
  SHA-512 Microsoft publishes. It exports `dotnet` and `dnx` (.NET 10's
  tool runner, as Node's `npx`). Its variables keep it to itself, each for
  a reason a probe showed (see [findings](findings.md#net)):
  `DOTNET_CLI_HOME` and `ProgramFiles(x86)` for NuGet and the CLI,
  `DOTNET_ROOT` for programs it starts, no developer certificate, no edit
  of your PATH, no telemetry or update checks, no workload check, and no
  MSBuild workers or compiler server outliving a build.
- [`recipes/no-publish/dotnet.json`](../recipes/no-publish/dotnet.json):
  the SDK image's files without the SDK, its packs and templates:
  `dotnet.exe`, its host, and the three shared frameworks; `DOTNET_ROOT` is
  its own directory, so apps' apphosts find it. Built in seconds.
- No change to zigsaw: runtimes, image sources and vendor steps did it, and
  a runtime's variables already see `${app}` as the runtime's directory.

### Pinta

- [`recipes/no-publish/pinta.json`](../recipes/no-publish/pinta.json): the
  release tarball, its NuGet packages vendored (148 MB, Roslyn among them),
  built for .NET 10 (`TargetFramework` from the module's `env`, which its
  project allows), its translations compiled with gettext's `msgfmt`,
  without the import of the MSYS2 bundling its tarball lacks, and laid out
  as its own Windows build is: the program in `bin`, its icons and
  translations in `share`, where it looks for them. No PDBs.
- On two runtimes, GTK's (pinned at the digest Rnote uses) and .NET's;
  GirCore loads GTK's DLLs by the names GTK's runtime has.
- A Start menu shortcut with the icon in its executable; offered for
  `.ora`, `.png`, `.jpg`, `.jpeg`, `.bmp`, `.tif` and `.tiff`; your Desktop,
  Documents, Downloads and Pictures, as Rnote has.

### Not published

- [`scripts/publish.sh`](../scripts/publish.sh) refuses a recipe in
  `recipes/no-publish/`, named or listed, before it builds or pushes
  anything.
- The README has [Apps you build yourself](../README.md#apps-you-build-yourself),
  and [recipes.md](recipes.md#net) the order to build them in.

### Tests

- [`tests/build.sh`](../tests/build.sh): 11 checks in a new .NET section,
  with two fixtures, [`tests/build/dotnet`](../tests/build/dotnet) (a
  console program with a NuGet package, vendored) and
  [`tests/build/dotnetdesktop`](../tests/build/dotnetdesktop) (a Windows
  Forms form and a WPF window that close themselves): the SDK and the
  runtime build, the runtime has only what it needs, the SDK as an app
  builds a project in the working directory with NuGet's files in its data,
  and each fixture builds, runs on the runtime under soft, low and
  appcontainer, and builds again to the same image. CI runs it.
- [`tests/gtk.sh`](../tests/gtk.sh): 12 checks for Pinta: its version, the
  windowless shim, its shortcut's icon, its icons and translations, that it
  runs in each sandbox, its file associations, and opening an image given
  with `--file` in each sandbox. It builds .NET's images into the store if
  they aren't there, and removes them again.

### Code map

| File | Change |
|---|---|
| `recipes/no-publish/dotnet-sdk.json`, `dotnet.json`, `pinta.json` (new) | the SDK, the runtime, Pinta |
| `tests/build/dotnet/`, `tests/build/dotnetdesktop/` (new), `tests/build.sh` | the .NET section |
| `tests/gtk.sh` | Pinta |
| `scripts/publish.sh` | refuses `recipes/no-publish/` |
| `README.md`, `docs/recipes.md`, `docs/findings.md`, `docs/gaps.md` | .NET, Pinta, apps you build yourself, findings, gaps |

## Results

### Tests

- `tests/build.sh`: 120 pass, 11 of them new (12.4 min, with its stores
  seeded from one that had the downloads; its .NET section alone, 98 s).
- `tests/gtk.sh`: 84 pass, 12 of them new (Pinta), with `GTK_HOME`
  `D:\zs\a`, which had no .NET images: it built them and removed them
  again.
- Unit tests and the other suites weren't run: zigsaw's code didn't
  change, nor did any published recipe.
- By hand, in three sandboxes: Pinta's window (pictures of it), an image
  given with `--file` changed and saved in place, its settings in its data
  directory, and Pinta started from its Start menu shortcut, through the
  windowless shim. Afterwards, as before the iteration: no `.nuget` in the
  profile, its `.dotnet`, the user's PATH and certificate store unchanged.

### Reproducibility

| Image | Manifest | Layer |
|---|---|---|
| `com.microsoft.dotnet.Sdk` 10.0.402 | `af8d05f1` | 283 MB, for 808 MB of files |
| `com.microsoft.dotnet` 10.0.13 | `02a480d6` | 86 MB, for 200 MB |
| `com.github.PintaProject.Pinta` 3.1.2 | `cf8f9d69` | 9.5 MB |
| `tests/build/dotnet` | `de99798b` | 0.2 MB |
| `tests/build/dotnetdesktop` | `4243131b` | 0.1 MB |

The same in two stores (`D:\zs\i20\p` and `q`), by the same zigsaw 0.19.0,
the NuGet packages vendored afresh in each. The SDK takes about a minute to
build, once downloaded; the runtime 12 s; Pinta 36 s, or a minute with its
vendor step. Nothing is to be published.

## Decisions made along the way

- **NuGet's machine-wide settings come from the image.** NuGet on .NET
  reads their directory from `ProgramFiles(x86)`, and fails without it;
  zigsaw's runs pass only a few of the machine's variables, and not that
  one. The SDK's image sets it to its own directory, which has no settings,
  rather than zigsaw passing the machine's on to every app: builds then
  never see a package source the machine has (Visual Studio can add one),
  and recipes need no `nuget.config` of their own.
- **`DOTNET_CLI_HOME`, not `NUGET_PACKAGES`**: the plan had both, but one
  covers the CLI's files and NuGet's, which find the profile the same way.
- **Pinta's files laid out as its Windows build lays them out**, rather
  than patched to look next to its executable.
- **Pinta's PDBs left out**, as Rust's and Go's apps are stripped.

## Findings

See [findings.md](findings.md#net). Besides:

- Closing a window found by its title, with `tests/winwait.zig`'s
  `--close`, reached a browser window whose title had the app's name in it.
  Scratch scripts now close an app's window through its process.

## Known gaps

- .NET's images, and apps built with them, can't be published; each
  machine builds them, the SDK first.
- No NativeAOT, which needs Visual Studio's linker; only .NET 10.
- One runtime image with all three frameworks.
- In an AppContainer, `dotnet --info` stops at the workloads.
- Pinta has no WebP loader, and its own strings follow Windows' display
  language only.
- Paths past 260 characters were tried with Windows' long paths on only.

## Suggested for iteration 21

- Flatpak's "extra data" for images whose files mustn't be published: a
  layer described by the vendor's URL and hash, which each machine fetches
  from the vendor when it installs the image, so that .NET's runtime, and
  Pinta, could be pulled.
- The iteration 19 leftovers: the v0.19.0 release check byte for byte,
  `zigsaw search` against ghcr.io, names for the runtimes and SDKs.
- More .NET apps (PowerShell, a WPF app), or .NET 8 apps without
  rebuilding them, on a runtime of their own.
- `tests/winwait.zig` matching only windows of the processes a run
  started, as `tests/guiapps.sh` finds windows by their titles too.
