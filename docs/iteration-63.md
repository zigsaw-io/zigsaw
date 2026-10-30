# Iteration 63: GTK on upstream Clang

Built 2026-10-30. zigsaw unchanged (**0.60.0**). Fifteen images to publish:
llvm-mingw's (a new config, the same layer), then gettext, GTK's SDK base
and SDK, GTK's runtime, Text Editor, Rnote, GTK 3's SDK, runtime and demos,
Gnumeric, PyGObject's SDK and runtime, Meld and Gaphor, now built with
llvm-mingw's Clang instead of zig 0.16.

## Outcome

- **GTK's whole family builds with LLVM's own Clang and lld**, as GDAL,
  PostgreSQL and Qt have since iterations 61 and 62. GTK's SDK carries
  llvm-mingw's image as a runtime in zig's place, so every app built on it,
  and programs built with it without a recipe, compile with Clang too.
  **zig 0.16's image is pinned by nothing.** Builds are faster here: GTK's
  SDK base 14 minutes instead of about 20, the SDK 15 instead of 20.
- **What the recipes did for zig is gone**: the `crt-noexport` objects,
  the SDK's own `windres` and `nm` programs, libtool's `ld` and `windres`
  scripts, the `foo.lib` copies of import libraries, the WinRT headers,
  `-s` for static libraries, `-Wl,-Brepro`, `rc`'s options everywhere,
  gettext's export edits, Gnumeric's export header and three of its
  edits, GTK 3's `-luuid` edit, two hunks of gobject-introspection's patch.
  Six helper files are deleted.
- **Rust builds with llvm-mingw**, checked first: GNU `dlltool` gets its
  assembler from a new `as` alias in llvm-mingw's image (your pick), and
  cargo links with Rust's own GNU ld, which a recipe names, since
  llvm-mingw puts another `x86_64-w64-mingw32-gcc` on PATH. A recipe lists
  Rust's image before the SDK that brings llvm-mingw, so that Rust's
  `dlltool` wins.
- **Four things llvm-mingw needed instead**: OpenSSL's Windows libraries
  in `libcrypto.pc`'s `Libs`; libtool's `-nostdlib` still dropped for C++
  (hunspell, enchant); Gnumeric's libspreadsheet linked with
  `--export-all-symbols`; and Rnote's cargo capped (8 jobs, no debug info
  for its fat LTO), as this machine ran out of memory (your pick).

## Starting decisions

From the planning session (plan file `let-s-plan-iteration-63-peaceful-metcalfe.md`):

- **GTK's chain onto llvm-mingw** (your pick, over zig 0.17, or a feature).
- **The whole chain** (your pick, over the SDKs and runtimes only, or the
  SDKs only): every image re-pinned and rebuilt, so that nothing pins zig
  0.16.
- Mine: Meson re-pinned to its 1.12.1 tag (`7448a74d`, which ended the
  two check-pins warnings); llvm-mingw unchanged if possible; a gate before
  rebuilding: Rust with llvm-mingw, as GTK's SDK (librsvg) and Rnote need,
  stop and ask if it failed.

Decided during:

- **The `as` alias in llvm-mingw's image** (your pick, over a C wrapper in
  GTK's SDK, or the SDK's base listed as an SDK too): a recipe's own
  aliases don't apply to its own build, so GTK's SDK couldn't declare one
  for librsvg. llvm-mingw's config changes (`115b5e48`), its layer doesn't;
  GDAL's, PostgreSQL's and Qt's recipes keep `1fd5d6d8`.
- **Rust's linker named per recipe** (mine): `export
  CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=...` in librsvg's and Rnote's
  commands, as `RUSTFLAGS` doesn't reach build scripts under `--target`,
  and an image can't name another image's files.
- **Rnote's cargo capped in its recipe** (your pick of the job cap, over
  freeing memory here): `CARGO_BUILD_JOBS=8`; the fat LTO then still took
  8.2 GB, so (mine) `CARGO_PROFILE_RELEASE_DEBUG=0` too.
- **libspreadsheet with `--export-all-symbols`** (mine), in place of the
  header that stripped `G_MODULE_EXPORT`.

## What was built

### Slice 0: probes

Scratch `D:\zs\i63\probe`, a throwaway store `D:\zs\i63\s`:

- **Rust with llvm-mingw** (`tests/build/rust`'s program, windows-sys and
  a cc-crate C file): without an `as`, GNU `dlltool` fails; with a probe
  image's `as` alias, rustc linked with llvm-mingw's
  `x86_64-w64-mingw32-gcc` (no `libgcc_eh`); with
  `-Clink-self-contained=yes`, or the linker variable under `--target`, it
  builds, runs, binds 193 of 193 imports and builds again to the same
  image.
- **lld and llvm-windres**: `-lfoo` finds `foo.lib`; `-licu` links
  (`libicu.a`), but there are no ICU headers; the WinRT headers are there;
  `--export-all-symbols` exports everything even with a `dllexport`;
  `--enable-runtime-pseudo-reloc` is taken; `-mwindows` makes a GUI
  program; llvm-windres takes `--include-dir`, and `tests/gtk.sh`'s
  command line.

### Slice 1: llvm-mingw, gettext, GTK's SDK

- [`recipes/llvm-mingw.json`](../recipes/llvm-mingw.json): the `as` alias.
- [`recipes/gettext.json`](../recipes/gettext.json): SDK `llvm`; the
  `pmake` module alone; `WINDRES=windres`; no `LD`, `-Brepro`, implibs,
  export edits or `-nostdlib` seds (it builds no C++).
- [`recipes/gtk4-sdk-base.json`](../recipes/gtk4-sdk-base.json) and
  [`recipes/gtk4-sdk.json`](../recipes/gtk4-sdk.json): runtime `llvm` and
  Meson's tag; no `crt-noexport`, `windres`, `nm`, `mingw-w64-winrt` or
  `implibs` modules, no `RC`, toolchain `LDFLAGS`, `CFLAGS=-s` or
  `CMAKE_RC_FLAGS`; the base checks that no DLL imports llvm-mingw's C++
  runtime. The SDK sets `RCFLAGS=--use-temp-file` (as Qt's), exports `cc`,
  `c++`, `ar`, `windres` and `nm` from `${llvm}` (no `rc`), moves
  OpenSSL's libraries into `libcrypto.pc`'s `Libs`, and names Rust's linker
  for librsvg.
- [`recipes/gtk4-sdk/gobject-introspection.patch`](../recipes/gtk4-sdk/gobject-introspection.patch):
  the no-`dlltool` fallback and the `.dll.a` path hunks are gone.
- Deleted: `gtk4-sdk/windres.c`, `nm.c`, `implibs.sh`,
  `autotools-windres.sh`, `gettext/exports.sh`, `gnumeric/export-all.h`.
  `autotools-ld.sh` stays, for Ghostscript.

### Slice 2: the runtimes and apps

- Re-pinned in order: [`gtk4.json`](../recipes/gtk4.json) (its cleanup no
  longer names `nm.exe` and `windres.exe`), Text Editor, Rnote, GTK 3's
  three, Gnumeric, PyGObject's two, Meld, Gaphor, and
  [`no-publish/pinta.json`](../recipes/no-publish/pinta.json).
- Each drops `crt-noexport`, `LDFLAGS`/`RC` env and `CMAKE_RC_FLAGS`.
  [`gnumeric.json`](../recipes/gnumeric.json) drops its `ld.sh`s, implibs,
  `-nostdlib`, pseudo-reloc, `--include-dir` and `-mwindows` edits and the
  export header, and links libspreadsheet with `--export-all-symbols`.
  [`rnote.json`](../recipes/rnote.json) lists `rust` first, names Rust's
  linker, and caps cargo.
- [`tests/build.sh`](../tests/build.sh), section `rust` (group `langs`):
  the Rust program again with llvm-mingw's image, built, run and its
  imports checked.

### Slice 3: CI and docs

- CI: gtk-suites seeds llvm-mingw's image instead of zig's;
  [`scripts/ci-groups.sh`](../scripts/ci-groups.sh) checks GTK's family
  when llvm-mingw's recipe changes (no longer zig's), and GDAL's no longer
  names the deleted scripts;
  [`scripts/published-recipes.txt`](../scripts/published-recipes.txt)
  lists llvm-mingw before gettext.
- Docs: [recipes.md](recipes.md#gtk) (GTK's SDK, building without a
  recipe, what zig needed, Rnote, Gnumeric, introspection; the
  [Clang section](recipes.md#clang-llvm-mingw): `as`, Rust, libtool),
  [findings](findings.md#gtk-on-llvm-mingw-iteration-63),
  [gaps](gaps.md), [published apps](published-apps.md), and the timings in
  [scripts/published-groups.txt](../scripts/published-groups.txt).

## Results

| check | result | time |
|---|---|---|
| the 15 in store `p`, then fresh `p2` | the same manifests in both: llvm-mingw `115b5e48` (layer `21eb1e1d`, as before), gettext `92b9c82b`, GTK SDK base `4b45ce5d`, GTK SDK `cb3f94b1`, GTK `ce922465`, Text Editor `7fe73597`, Rnote `ea372c40`, GTK 3 SDK `6b4223ff`, GTK 3 `c9d1b761`, GTK 3 demos `21027629`, Gnumeric `174ee709`, PyGObject SDK `e24980b8`, PyGObject `ff7ea152`, Meld `8cc18f20`, Gaphor `e187e157` | in `p2`: gettext 29 min, base 14, SDK 14, Rnote 13.5, Gnumeric 21.5, the rest under 3 each |
| tests/gtk.sh (store `p`) | 93 ok, 1 failed: Rnote didn't stay up under `--sandbox=soft`; alone it did, three times out of three (a single-instance app, it hands over to a run still ending); GTK with MSVC skipped (not in the store) | 9 min |
| tests/gtk3.sh (store `p`) | 0 failed, 45 ok | 2.7 min |
| build.sh's `rust` section (group `langs`) | 0 failed, 8 ok, the 2 new llvm-mingw rows among them | 2.7 min |
| Rnote's and `rsvg-convert`'s imports | all bound: `rnote.exe` 1,051, `rnote-cli.exe` 358, `rsvg-convert.exe` 1,891 | |
| layers: gettext / base / SDK / runtime | 7.0 / 66.2 / 89.7 / 52.2 MB (zig: 7.8 / 69.9 / 93.9 / 53.6) | |
| Defender scan of store `p`'s deployments | no threats | 3 min |
| `grep -l 0379659d recipes` (zig 0.16's image) | nothing | |
| scripts/check-pins.sh | 31 missing, all pins of the new images; 0 older runtimes (Meson's two warnings gone) | |

## Next

- Publish **before pushing** (CI's GTK groups compare their builds with
  ghcr.io and pull llvm-mingw's new image; `gdal` builds llvm-mingw's
  recipe and compares it; `gtk-suites` pulls them all), from store
  `D:\zs\i63\p` with `ZIGSAW=D:\zs\i60\bin\zigsaw.exe`, in this order:
  `scripts/publish.sh llvm-mingw.json gettext.json gtk4-sdk-base.json gtk4-sdk.json gtk4.json gnome-text-editor.json rnote.json gtk3-sdk.json gtk3.json gtk3demo.json gnumeric.json pygobject-sdk.json pygobject.json meld.json gaphor.json`.
- Then commit and push, and I read the run: all GTK groups and
  gtk-suites, `gdal` (llvm-mingw's recipe changed), and build.sh's `langs`
  group with the new Rust rows.
- No zigsaw change, so no tag.
- Later: zig 0.16's image could leave the registry's catalog; an upstream
  note for OpenSSL's `.pc` and Flameshot's include.
