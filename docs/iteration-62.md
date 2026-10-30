# Iteration 62: Qt on upstream Clang

Built 2026-10-30. zigsaw unchanged (**0.60.0**). Five images to publish:
Qt's SDK base and SDK, Qt's runtime, Flameshot and Notes, now built with
llvm-mingw's Clang instead of zig 0.16.

## Outcome

- **Qt's chain builds with LLVM's own Clang and lld**, as GDAL's and
  PostgreSQL's have since iteration 61. The SDK carries llvm-mingw's image as
  a runtime in zig's place, so the apps built on it, and programs built
  with it without a recipe, compile with Clang too. Its builds are faster:
  the base 16.5 minutes here instead of 25, the SDK on it 19 instead of 26.
- **What the recipes did for zig is gone**: the stub import libraries
  (`winlibs.sh`), QtCore's subsystem edit, the `crt-noexport` objects, every
  module's `CFLAGS`/`LDFLAGS`, and `rc`'s options in the SDK and in each
  app's `CMAKE_RC_FLAGS`. App recipes now name no toolchain flags at all.
- **C++ across Qt's DLLs, each with its own libc++, was checked first**: a
  fixture of two DLLs and a program passes 19 checks in all three sandboxes,
  so llvm-mingw's image stays as published.
- **Two things llvm-mingw needed instead**: `RCFLAGS=--use-temp-file` in
  the SDK's env, as llvm-windres takes the quotes off `-D` values the way
  GNU windres does (Flameshot's version resource failed), and one
  `#include <iterator>` in Flameshot for LLVM 23's libc++.
- **The five reproduce** in two fresh stores. Only gettext's and GTK's
  chains still pin zig 0.16.

## Starting decisions

From the planning session (plan file `let-s-plan-iteration-62-velvety-bachman.md`):

- **The Qt chain only** (your pick, over GTK's and gettext's chains, all
  three, or features), so the move is tried on one large C++ build before
  GTK's.
- **Onto llvm-mingw** (your pick, over zig 0.17, whose links ran this machine
  out of memory in iteration 60, or probing both), the image iteration 61
  published (`1fd5d6d8`), unchanged.
- Mine: the SDK exports llvm-mingw's `cc`, `c++`, `ar` and `windres` in
  place of zig's `cc`, `c++`, `ar` and `rc`; a gate before rebuilding Qt:
  if C++ across DLLs with static libc++ failed, stop and ask (the fallback,
  libc++ as a DLL, would change llvm-mingw's image and republish
  iteration 61's nine).

Decided during (mine):

- **`RCFLAGS` in the SDK's env**, not `CMAKE_RC_FLAGS` in Flameshot's
  recipe: every Qt app's resource compile gets it, as the SDK's `RC` gave
  zig's options before, and app recipes stay flag-free.
- **The manifest quoting edit stays**, though llvm-windres reads the
  unquoted name: quoted is what every resource compiler reads.

## What was built

### Slice 0: probes

Scratch `D:\zs\i62\probe`, a throwaway store `D:\zs\i62\s` with the
published llvm-mingw image:

- **C++ across DLLs** ([`tests/build/xdll`](../tests/build/xdll), a recipe
  building two DLLs and a program with llvm-mingw's `c++`): 19 checks ok
  in soft, low and AppContainer, exit 0; the three import no DLL of
  llvm-mingw's, and export only what's `dllexport`ed (no `atexit`,
  `_CRT_INIT` or `__mingw_module_is_dll`).
- **`-mwindows`** gives subsystem 2 (Windows GUI); a program calling
  `WaitOnAddress`, `WindowsCreateString` and `RoInitialize` links with
  `-lsynchronization -lruntimeobject` and runs.
- **llvm-windres** compiles Qt's manifest line quoted and unquoted.

### Slice 1: Qt's SDK

- [`recipes/qt6-sdk-base.json`](../recipes/qt6-sdk-base.json) and
  [`recipes/qt6-sdk.json`](../recipes/qt6-sdk.json): runtime `llvm` in
  place of `zig`; no `RC` in their env; no `crt-noexport` or `winlibs`
  modules, no module env, no `CMAKE_RC_FLAGS`. Their `relocate` steps
  check that no DLL imports llvm-mingw's libc++, libunwind or winpthreads,
  and the SDK's that `designer.exe` is a GUI program. The SDK sets
  `RCFLAGS=--use-temp-file` and exports `cc`, `c++`, `ar` and `windres`
  from `${llvm}`.
- [`recipes/qt6-sdk/qtbase.sh`](../recipes/qt6-sdk/qtbase.sh): the
  `runtimeobject` and subsystem edits are gone; `qspan.h`, the manifest's
  quoting and the AppContainer QLocalServer patch stay.
  `qt6-sdk/winlibs.sh` is deleted.
- Kept as they were: `CMAKE_SYSTEM_VERSION=10.0.26300`, no SBOM,
  qtdeclarative's unity build and second pass, Imagine and StyleKit off,
  the pkg-config relocation.

### Slice 2: the runtime, the apps, the tests

- [`recipes/qt6.json`](../recipes/qt6.json) re-pinned;
  [`flameshot.json`](../recipes/flameshot.json) and
  [`notes.json`](../recipes/notes.json) re-pinned, without `crt-noexport`,
  module env or `CMAKE_RC_FLAGS`; Flameshot adds `<iterator>` to
  `strfparse.cpp`, checked.
- [`tests/qt/hello.json.in`](../tests/qt/hello.json.in): no `LDFLAGS` or
  `CMAKE_RC_FLAGS`; [`tests/qt.sh`](../tests/qt.sh)'s comments name
  llvm-mingw.
- [`tests/build.sh`](../tests/build.sh), section `llvm` (group
  `cmake-meson`): the cross-DLL fixture, built and run, 19 checks.

### Slice 3: docs

[recipes.md](recipes.md#qt) (Qt's section: the toolchain, what's still
needed and what zig needed, times, sizes, `RCFLAGS`; the Clang section),
[findings](findings.md#qt-on-llvm-mingw-iteration-62),
[gaps](gaps.md), [published apps](published-apps.md), and the timings in
[scripts/published-groups.txt](../scripts/published-groups.txt).

## Results

| check | result | time |
|---|---|---|
| the 5 in store `p`, then fresh `p2` | the same manifests in both: Qt SDK base `62e471c1`, Qt SDK `6080b660`, Qt `ef6e37e2`, Flameshot `0468a10b`, Notes `01e3fc99` | base 16.5 and 17 min, SDK 19.3 and 19, the rest under 1.5 each |
| tests/qt.sh (store `p`) | 0 failed, 39 ok | 1 min 51 s |
| `GROUP=cmake-meson tests/build.sh` | 0 failed, 21 ok, the `llvm` section's 6 among them (2 new: the cross-DLL fixture builds, and its 19 checks pass) | 6.5 min |
| least free commit, 18 jobs | 3.8 GB (SDK, `p2`); base 5.8 to 6.2 GB | |
| layers: base / SDK / runtime / Flameshot / Notes | 37.2 / 91.3 / 57.4 / 1.6 / 5.4 MB (zig: 35.3 / 87.5 / 55.6 / 1.5 / 5.3) | |
| Defender scan of the five deployments | no threats | |
| scripts/check-pins.sh | 6 missing, all pins of the new five; GTK's 2 Meson warnings as before | |

## Next

- Publish **before pushing** (CI's `qt-base` and `qt` groups compare their
  builds with ghcr.io; `qt-suites` pulls the images), from store
  `D:\zs\i62\p` with `ZIGSAW=D:\zs\i60\bin\zigsaw.exe`, in this order:
  `scripts/publish.sh qt6-sdk-base.json qt6-sdk.json qt6.json flameshot.json notes.json`.
  llvm-mingw's image is on ghcr.io already, public.
- Then commit and push, and I read the run: the Qt groups run (their
  recipes changed), each pulling llvm-mingw's image, then `qt-suites` on
  Server 2025, and build.sh's `cmake-meson` group with the cross-DLL rows.
- No zigsaw change, so no tag.
- Later: gettext's and GTK's chains on llvm-mingw, after which zig 0.16's
  image is pinned by nothing; an upstream note for Flameshot's include.
