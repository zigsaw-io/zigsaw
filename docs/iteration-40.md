# Iteration 40: CMake without Program Files, and Qt Quick

Built 2026-10-22. Temurin's OpenJDK 25.0.5 still isn't released (Adoptium's
latest is 25.0.4.1), so the Java images stay on 25.0.5 early access.

## Outcome

- **Iteration 39's run** (19b40cb) was red in its two Qt jobs; everything
  else reproduced. Both causes are fixed:
  - **`published (qt)`:** qtbase found the runner's PostgreSQL in
    `C:\Program Files`, built a plugin for it and failed to link that
    plugin. CMake looked there in every build, so CMake's image no longer
    does.
  - **qt-suites:** export clashes, not Qt. The first app installed keeps a
    command's name. CI installed CMake's image before Qt's SDK, so `cmake`
    was plain CMake; and the SDK, installed before the runtime, kept
    `designer`, so the runtime got no Designer shortcut.
- **CMake's image finds nothing the machine has installed**: no Program
  Files, no package registries, no Python from the registry. Qt's SDK and
  its apps use the new image; the other CMake recipes keep theirs.
- **Qt has QML and Qt Quick.** qtshadertools and qtdeclarative build with
  zig, unchanged. Qt Quick draws with Direct3D 11 in all three sandboxes,
  and Linguist is back.
- **Qt's SDK is in two halves**, as GTK's is: 25 minutes for the base and
  48 for the SDK on it, here.
- **qtdeclarative's build raced its own type information**, so two fresh
  builds first differed in one DLL. Its module now builds a second time,
  with every type known, and the SDK reproduces.
- **Notes 2.3.1**, a note-taking app with a Qt Quick kanban board, runs in
  every sandbox.
- **All six images reproduce**, byte for byte, in two fresh stores:

  | image | digest | build here | compressed |
  |---|---|---|---|
  | `org.cmake.cmake` 4.4.4 | `fa7efc2e` | 9 s | 21 MB |
  | `io.qt.Qt6.Sdk.Base` 6.12.0 | `c3df032b` | 25 min | 35 MB |
  | `io.qt.Qt6.Sdk` 6.12.0 | `7361e491` | 48 min | 90 MB |
  | `io.qt.Qt6` 6.12.0 | `c09a8cfe` | 25 s | 59 MB (163 MB deployed) |
  | `org.flameshot.Flameshot` 14.0.0 | `ad06793e` | 2 min | 1.5 MB |
  | `io.github.nuttyartist.notes` 2.3.1 | `5fd7a5d0` | 75 s | 5.3 MB |

- **Not published yet:** the six images are yours to publish.

## Starting decisions

Made with you at planning (plan:
`C:\Users\Test\.claude\plans\plan-iteration-40-majestic-comet.md`):

- **Fix CMake's image** and re-pin Qt's SDK and its apps to it. The other
  CMake recipes keep their pins, so nothing else is republished.
- **QML and Qt Quick** as the feature, in Qt's images.
- **Notes** as the app that proves them, over CopyQ (which uses only QML's
  JavaScript engine) or Qt's demos.

## What was built

### CMake's search paths

- [`recipes/cmake/WindowsPaths.cmake`](../recipes/cmake/WindowsPaths.cmake)
  replaces Kitware's file in the image (a module without build commands, as
  the Python image's `._pth` is). Kitware's adds `%SystemDrive%\Program
  Files` and `Program Files (x86)` to the prefixes every `find_*` searches;
  this one doesn't. It also turns CMake's package registries off and keeps
  FindPython from the registry, unless a project sets those itself.
- [`tests/build/cmake/hermetic`](../tests/build/cmake/hermetic) and a check
  in `tests/build.sh`'s cmake section: no Program Files among the prefixes,
  no Git from there (this machine and runners have one), registries off, no
  Python. Built with the old image instead, the same project found
  `C:\Program Files\Git\cmd\git.exe` and the registry's Python.
- Configuring qtbase, qttools and Flameshot with both images showed the
  published Qt SDK hadn't depended on this machine: qtbase's configuration
  summary is the same, and only Flameshot's configure had found (and run)
  this machine's Git.

### Qt's SDK in two halves, with QML

- [`recipes/qt6-sdk-base.json`](../recipes/qt6-sdk-base.json)
  (`io.qt.Qt6.Sdk.Base`): qtbase, qtsvg, qtimageformats and qtshadertools.
- [`recipes/qt6-sdk.json`](../recipes/qt6-sdk.json): the base's files as
  an image source, then qtdeclarative, qttools (now with Linguist) and
  qttranslations.
  - qtdeclarative's build runs a Python script, so its module unpacks
    Python's embeddable zip and names it with `-DPython_EXECUTABLE`.
  - qtbase's SQL drivers for client libraries (PostgreSQL, MySQL, Oracle,
    DB2, InterBase, Mimer) are off by name, so they don't depend on the
    machine either.
  - The SDK no longer exports `designer`; the runtime does.
- [`recipes/qt6.json`](../recipes/qt6.json): keeps Qt's `qml` folder and
  leaves out QML's build tools (`qmlcachegen`, `qmllint`, `qsb` and the
  rest, `Qt6QmlCompiler.dll`, `Qt6QuickTest.dll`). It exports `linguist`
  and `qml` too, and adds a "Qt Linguist" shortcut. It keeps
  `Qt6UiTools.dll`, which Linguist links.
- [`recipes/flameshot.json`](../recipes/flameshot.json): re-pinned to the
  new SDK and runtime. Its configure no longer finds Git.

### Notes

[`recipes/notes.json`](../recipes/notes.json)
(`io.github.nuttyartist.notes`, Flathub's id):

- The 2.3.1 tag, with its two submodules (qautostart, qmarkdowntextedit)
  pinned at the commits the tag names.
- A `sed` adds `CorePrivate`, `GuiPrivate` and `WidgetsPrivate` to its Qt
  components, which Qt 6.10 and later want asked for by name.
- Its default `PRO_VERSION=ON` is the free build with every feature and no
  licence check; its update checker is off.
- Its notes database and settings are in AppData, so in its data
  directory. It may use your Documents folder.

### Tests and CI

- [`tests/qt.sh`](../tests/qt.sh), now 38 checks:
  - [`tests/qt/quick`](../tests/qt/quick), a Qt Quick program in the test
    app, draws a window of Controls with Direct3D 11 in each sandbox, and
    finds Qt's QML modules in the runtime's deployment;
  - the runtime's `qml` runs a QML file;
  - Linguist's window in each sandbox, and its shim and shortcut;
  - Notes' window in each sandbox, its QML loading without errors, and its
    database in its data directory;
  - building with the SDK's `cmake` uses the SDK's even when another app
    holds the name, and keeps CMake's output in `LOG_DIR` on a failure.
- `.github/workflows/reproduce.yml`:
  - qt-suites seeds only Qt's images, Flameshot and Notes; the SDK brings
    CMake, zig and BusyBox along;
  - the Qt jobs' timeout is 90 minutes.
- `scripts/published-groups.txt`: `qt-base` (the SDK's base) and `qt` (the
  SDK, the runtime, Flameshot, Notes), which `scripts/ci-groups.sh` checks
  as Qt's family.
- `tests/published.sh`: Notes stays up.

### Docs

- [docs/recipes.md](recipes.md#cmake) (CMake), [Qt](recipes.md#qt) and
  [Notes](recipes.md#notes).
- [docs/findings.md](findings.md#cmakes-search-paths-and-qt-quick-iteration-40)
  and [docs/gaps.md](gaps.md).
- [docs/published-apps.md](published-apps.md) and the README's test list.

## Results

| check | result | time |
|---|---|---|
| iteration 39's qt-suites failures, on a store seeded as CI's | the same 2 | 3 min |
| `GROUP=cmake-meson tests/build.sh`, with the final CMake image | 0 failed | 6 min |
| hermetic fixture, new and old CMake image | new finds nothing; old finds Program Files, Git, Python | seconds |
| configure qtbase, qttools, Flameshot with old and new CMake | same qtbase summary; Git only in Flameshot's, with the old | 4 + 2 min |
| Qt Quick probe (kept build, published runtime) | Direct3D 11 in soft, low, AppContainer | |
| all six images, fresh stores p and p2 | the SDK differed in one DLL (FluentWinUI3's style) | about 70 min each |
| that DLL's qmlcache, regenerated in a kept build | 67 compiled functions became 71; the same bytes on every regeneration | |
| the base's files against iteration 39's SDK | 4,306 shared files the same, byte for byte | |
| SDK, runtime, Flameshot, Notes again with the second pass, p and p2 | the same six digests in both | 52 min each |
| `tests/qt.sh` on store p | 38, 0 failed | 2 min |
| `scripts/check-pins.sh` | only the new images missing | 1½ min |
| `GROUP=qt-base tests/published.sh` (store p) | 0 failed; the base not published yet | seconds |

`GROUP=qt tests/published.sh` isn't worth running before you publish: the
SDK, runtime and Flameshot are published at 6.12.0 and 14.0.0 already, with
iteration 39's digests, so it pulls those and diffs their files.
`tests/qt.sh` runs the same apps. zigsaw itself didn't change, so its unit
tests and other suites weren't rerun.

## Decisions made along the way

All my calls:

- **The SDK in two halves.** qtdeclarative alone took 34 minutes here; the
  whole SDK, 73 with the second pass, would be over 90 on a runner.
- **A second pass over qtdeclarative's compiled QML** rather than building
  without it (`--only-bytecode`, slower QML) or patching Qt's CMake: it
  costs 7 minutes here. Building `all_qmltyperegistrations` first, which
  would have cost nothing, didn't remove the race.
- **Python for qtdeclarative from a source, not the Python image**, which
  has no `path`, so it wouldn't be on the build's PATH as an SDK.
- **FindPython's registry search off in CMake's image** as well, once it
  found this machine's Python.
- **The runtime exports Designer and Linguist; the SDK doesn't.** A runtime
  can't take back a name the SDK installed first.
- **Notes keeps `PRO_VERSION=ON`**, as the plan had it the other way: off,
  it's the paid build that checks a licence online.
- **The `cmake` check falls back to `zigsaw run --command=cmake` on the
  SDK** when another app holds `cmake`, which is all the shim does.

## Known gaps

- The CMake recipes still on the old image (zstd, PHP's yaml and zstd,
  Gaphor, GTK's SDK and its base, Text Editor, Gnumeric) would still look
  in Program Files.
- Qt's runtime doubled (163 MB deployed), and Widgets-only apps such as
  Flameshot get QML and Qt Quick with it.
- No qmlls, Qt Multimedia, WebEngine or Charts; no Assistant.
- An app with several QML modules of its own could hit qtdeclarative's race
  in its own build.

## A slip of mine

A probe ran the published Qt runtime without the test's fake user folders,
so its `documents` permission labelled your real Documents folder low
integrity and granted the runtime's AppContainer access to it. `zigsaw rm`
in that scratch store undid both, and icacls shows Documents, and the
folders in it, as they were. The probes since use fake folders, as the
suites do.

## For you

1. Publish the six images, in this order (the base and the SDK build in
   about 75 minutes): `scripts/publish.sh recipes/cmake.json
   recipes/qt6-sdk-base.json recipes/qt6-sdk.json recipes/qt6.json
   recipes/flameshot.json recipes/notes.json`. Then make the two new
   ghcr.io packages public: `io.qt.qt6.sdk.base` and
   `io.github.nuttyartist.notes`.
2. Commit and push. The run checks every group, since the groups file
   changed. I'll then read the Qt jobs' times and qt-suites.

## Suggested for iteration 41

- Re-pin the other CMake recipes to the new image when they're next
  republished.
- More of Qt: Qt Multimedia, or a QML-only app.
- The parallel-make wrapper for Gnumeric and goffice.
- The Temurin 25.0.5 re-pin, once it's released.
