# Iteration 39: Qt 6

Built 2026-10-21. Temurin's OpenJDK 25.0.5 still isn't released (Adoptium's
latest is 25.0.4.1), so the Java images stay on 25.0.5 early access.

## Outcome

- **Iteration 38's run** (d795c26) took 36 minutes, as expected, and
  reproduced every group. gettext's job took 27 minutes (39 before), and
  GTK's base half (36) is now the longest. v0.36.0 is released.
- **Qt 6.12.0 builds with zig**, as two images like GTK's: an SDK with
  Qt's Widgets set and a runtime made from it. Flameshot 14.0.0, a
  screenshot tool, builds against the SDK and runs on the runtime in every
  sandbox.
- **All three images reproduce**, byte for byte, in two fresh stores:

  | image | digest | build here | compressed |
  |---|---|---|---|
  | `io.qt.Qt6.Sdk` 6.12.0 | `c4501703` | 26m 28s / 28m 24s | 46.5 MB |
  | `io.qt.Qt6` 6.12.0 | `9eae290f` | 12 s | 28.8 MB (75 MB deployed) |
  | `org.flameshot.Flameshot` 14.0.0 | `96e08b89` | 1m 56s | 1.5 MB |

- **`tests/qt.sh`**: 24 checks, 0 failed, in 72 seconds on a store that
  has the images.
- **Not published yet:** the three images are yours to publish.

## Starting decisions

Made with you at planning (plan:
`C:\Users\Test\.claude\plans\ancient-roaming-starfish.md`):

- **Qt 6.** I had offered other themes: revoking stale grants plus consent
  at install, low as the default sandbox, jlink runtimes, or more CI time.
- **From source with zig**, not Qt's prebuilt binaries.
- **The Widgets set**: qtbase, qtsvg, qtimageformats, qttools and
  qttranslations. QML and Qt Quick wait.
- **Flameshot** as the app that proves the runtime, with Designer exported
  from the runtime as GTK's runtime exports its demos.
- **First, a probe of zig's libc++ across DLLs**, with a stop-and-ask if it
  failed. It passed.

## What was built

### zig's libc++ across DLLs

zig links its libc++ into each DLL. A probe of two DLLs and a program
passed all 18 checks: exceptions caught by type across DLLs,
`dynamic_cast` and `typeid` (header-only classes too), std containers made
in one DLL and freed in another, `std::function`, `thread_local` and static
initialisers ([findings](findings.md#qt-6-with-zig-iteration-39)).

### The SDK and runtime

- [`recipes/qt6-sdk.json`](../recipes/qt6-sdk.json) (`io.qt.Qt6.Sdk`):
  - **Runtimes:** zig, CMake and BusyBox. CMake moved there from `sdk`, so
    apps get CMake and Ninja through the SDK.
  - **Exports:** the compilers, `cmake`, `ninja`, `qmake`, `lupdate`,
    `lrelease` and `designer`.
  - **`CMAKE_PREFIX_PATH`** points at the SDK itself, so its `cmake` finds
    Qt without a recipe.
  - qtbase uses its bundled third-party libraries, and Schannel for TLS.
  - [`qt6-sdk/winlibs.sh`](../recipes/qt6-sdk/winlibs.sh) makes the
    `synchronization` and `runtimeobject` import libraries that zig's
    MinGW lacks.
  - [`qt6-sdk/qtbase.sh`](../recipes/qt6-sdk/qtbase.sh) edits qtbase's
    sources:
    - an include that `qthread_win.cpp` was missing;
    - `runtimeobject` taken out of QtCore's public link libraries;
    - the manifest's `.rc` file name quoted;
    - `-Wl,--subsystem,windows` for every `WIN32_EXECUTABLE` that links
      QtCore;
    - [a patch](../recipes/qt6-sdk/qlocalserver-appcontainer.patch) that
      puts QLocalServer's named pipes under `\\.\pipe\LOCAL\` in an
      AppContainer.
  - **Left out for reproducibility:** the SBOM, the `.bat` helpers, and
    `B:/prefix` in the pkg-config files.
- [`recipes/qt6.json`](../recipes/qt6.json) (`io.qt.Qt6`):
  - the SDK minus headers, libraries and build tools;
  - a `bin\qt.conf` with `Prefix = ..`, so Qt's own programs there find
    the runtime's plugins;
  - Designer's registry key kept with its data;
  - exports for `designer`, `pixeltool` and `qtdiag`, and a shortcut for
    Designer.

### Flameshot

[`recipes/flameshot.json`](../recipes/flameshot.json):

- Qt-Color-Widgets and KDSingleApplication are pinned where Flameshot's
  CMake looks before it fetches them.
- QHotkey, which it fetched from `master`, is pinned at that branch's
  commit and passed with `FETCHCONTENT_SOURCE_DIR_QHOTKEY`.
- The update check and Imgur are off, and windeployqt too, since the
  runtime has Qt.
- `flameshot-cli` links with `-municode`, and the image leaves it out.
- Translations go to `bin\translations`.
- It may use your Pictures folder.

### Tests and CI

- [`tests/qt.sh`](../tests/qt.sh) and [`tests/qt/`](../tests/qt) (a
  Widgets app, built with CMake):
  - painting a window in each sandbox;
  - Qt's plugins found in the runtime's deployment;
  - image formats, Schannel, French translations, and app data in the
    app's data directory;
  - the SDK's `cmake` without a recipe;
  - Designer's window in each sandbox, its shims and shortcut, and qtdiag;
  - Flameshot in each sandbox, and its `full` command saving a PNG in
    Pictures.
- `scripts/published-groups.txt`: a `qt` group with all three recipes.
- `scripts/ci-groups.sh` now handles two families, GTK's and Qt's. Each is
  checked only when something it's built or tested from changed (and
  weekly), and it prints `qt=` as well as `gtk=`.
- `.github/workflows/reproduce.yml`:
  - the `qt` job's timeout is 120 minutes;
  - a `qt-suites` job seeds its store by pulling and runs `tests/qt.sh`.
- `tests/published.sh`: Qt's runtime (Designer) is in `stays_up_ids`.

### Docs

- [docs/recipes.md](recipes.md#qt): Qt, building without a recipe, and
  Flameshot.
- [docs/findings.md](findings.md#qt-6-with-zig-iteration-39) and
  [docs/gaps.md](gaps.md).
- [docs/published-apps.md](published-apps.md) and the README's test list.

## Results

| check | result | time |
|---|---|---|
| libc++ probe (two DLLs and a program) | 18 passed | under a minute |
| SDK, fresh store k | `c4501703` | 26m 28s |
| SDK, fresh store k2 | `c4501703` | 28m 24s |
| runtime and Flameshot, k and k2 | `9eae290f`, `96e08b89` in both | 12 s, about 2 min |
| `tests/qt.sh` on store k | 24, 0 failed | 72 s |
| `GROUP=qt tests/published.sh` (store k) | 0 failed; 3 not published yet | seconds |
| `scripts/check-pins.sh` | only the 3 new images missing | |
| `scripts/ci-groups.sh` on HEAD, d795c26, cb9df8e | both families left out on the first two; everything on the third | |

zigsaw itself didn't change, so its unit tests and other suites weren't
rerun.

## Decisions made along the way

All my calls:

- **Sources from GitHub's mirror** of Qt's modules. download.qt.io sends
  each machine to a mirror chosen by where it is, and zigsaw's fetch failed
  TLS on the way here.
- **Assistant and Linguist left out.**
  - Assistant's HTML viewer is a git submodule, empty in the archives, and
    no documentation is built for it to show.
  - Linguist's interface needs Qt Quick. `lupdate` and `lrelease` are in.
- **No `flameshot-cli.exe`.** It cuts off commands longer than about 80
  characters, and `zigsaw run` passes `flameshot.exe`'s output on anyway.
- **The AppContainer fix is in Qt, not in Flameshot.** Any Qt app's
  QLocalServer failed in an AppContainer, so it's fixed for all of them.
- **One SDK, not two halves.** qtbase alone is 18 of its 26 minutes, so a
  base half would hardly shorten the job.
- **Designer's check looks for its window.** It ran behind Qt's
  missing-plugin box at first, and a running process doesn't show that.
- **No version and no zigsaw change.** Runtime `registry` keys already
  work when the runtime runs as an app (Designer).

## Known gaps

- The `qt` job's time on a runner is unknown. qtbase took 17½ minutes on 16
  CPUs here; on a runner's 4 that may be 60 to 80 minutes, against a
  120-minute timeout.
- No QML or Qt Quick (and so no Linguist), and no Assistant.
- Flameshot's "Launch at startup" writes your real `HKCU\...\Run` under
  `soft`.
- Still on OpenJDK 25.0.5 early access.

## For you

1. Publish the three new images, in this order, with `scripts/publish.sh
   recipes/qt6-sdk.json recipes/qt6.json recipes/flameshot.json` (it
   rebuilds the SDK, about half an hour). Then make the three ghcr.io
   packages (`io.qt.qt6.sdk`, `io.qt.qt6`, `org.flameshot.flameshot`)
   public.
2. Commit and push. The run checks every group, since the groups file
   changed. I'll then read the `qt` job's time and the qt-suites results.

## Suggested for iteration 40

- If the `qt` job runs long on a runner: split qtbase's build, or move the
  SDK's other modules into a second half.
- QML and Qt Quick (qtdeclarative, qtshadertools), which would bring
  Linguist and apps such as CopyQ.
- The same parallel-make wrapper for Gnumeric and goffice; GTK's base
  half, now the longest GTK job.
- The Temurin 25.0.5 re-pin, once it's released.
