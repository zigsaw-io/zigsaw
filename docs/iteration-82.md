# Iteration 82: Toolchain round

Started 2026-11-09. The 2026-11-09 upstream report still had Meson and Qt's SDK building with
**CPython 3.14.7**, 11 OSV advisories, one of them over a network, with no login, data at risk.
Iteration 72 left them because nothing else rebuilt them, and named this round as the place to
move them. **llvm-mingw 20261104** (LLVM 23.1.5) was out, and three different 20261020 digests
were pinned across the GTK, Qt and GDAL/PostgreSQL chains. 38 images move. zigsaw doesn't
change and stays **0.81.0**: no tag, no release. This is the first round that publishing signs
nothing by hand; CI signs after the push.

It started with what 81 left: a real upgrade from v0.80.0 to v0.81.0 in a scratch store
installed the release's own bytes (`zigsaw.exe` `c05165ee`).

## Outcome

- **Meson and Qt's SDK build with CPython 3.14.10**: the report's 11 advisories at 3.14.7 are
  gone, and no image builds with 3.14.7.
- **One llvm-mingw for everything**: 20261104 (`7af21d46`), which the 11 recipes that pin it now
  share, where 20261020 had three digests.
- **llvm-mingw has a prefetch list**, as 79 deferred to this bump: the 464 files (145.4 MB) a first
  `clang++` compile and link of a C++ hello reads. A lazy pull's first compile fetched 463 files
  one by one before; now 341 arrive ahead of use and 126 on demand
  ([findings](findings.md#llvm-mingws-prefetch-list-iteration-82)).
- **Rust 1.99.1**, which fixes a miscompilation of FFI `bool` return values on x86_64
  (rust#163911). ripgrep, bat, cargo-c and Rnote are rebuilt with it.
- **The rest of the round**: CMake 4.4.5, pkgconf 3.0.10, SQLite 3.54.1, libiconv 1.19.1,
  libspelling 0.4.11, graphviz 16.1.1, KDSingleApplication 1.2.1.
- **The 38 reproduce** in two stores on two drives, ReFS (`E:`, a Dev Drive) and NTFS (`D:`),
  each with its own downloads.
- **gtk4-msvc moves too** (new CMake and Meson, no recipe change), **but doesn't reproduce**: one
  static library keeps the time it was archived. It isn't published; the cause is written down
  ([findings](findings.md#gtk4-msvc-doesnt-reproduce-an-archives-member-dates-iteration-82)).

## Decisions

Yours (2026-11-09):

- **The toolchain round**, over a GTK or PostgreSQL round.
- **The patch bumps that rebuild nothing extra**: libiconv, libspelling, graphviz,
  KDSingleApplication.
- **Rust 1.99.1**, which adds rust, ripgrep, bat and cargo-c to the round.

Mine, say if you disagree:

- **The prefetch list recorded from the published 20261020**, not the new build: a list has to be
  in the recipe before the build, as it orders the layer. The paths carry over because LLVM's
  resource directory is `lib/clang/23` in both.
- **gtk4-msvc stays as it is.** A likely fix (`-DCMAKE_STATIC_LINKER_FLAGS=/Brepro`) is untried;
  the recipe is an experiment and never compared in CI.
- **`tests/published.sh` isn't run before publishing**: it pulls from ghcr.io, where the new
  digests aren't yet. CI runs it after the push, which is also what signs.

## What changed

| Recipe | Source | From | To | Upstream's hash |
|---|---|---|---|---|
| `llvm-mingw.json` | llvm-mingw UCRT x86_64 | 20261020 (LLVM 23.1.4) | 20261104 (23.1.5) | GitHub's asset digest |
| `meson.json`, `qt6-sdk.json` | CPython embeddable | 3.14.7 | 3.14.10 | python.org's release API |
| `meson.json` | pkgconf | 3.0.7 | 3.0.10 | none published |
| `cmake.json` | CMake | 4.4.4 | 4.4.5 | `cmake-4.4.5-SHA-256.txt` |
| `rust.json` | rustc, cargo, rust-std, rust-mingw | 1.99.0 | 1.99.1 | each `.sha256` |
| `sqlite.json`, `gdal-sdk.json`, `gtk4-sdk.json` | SQLite amalgamation | 3.53.4 | 3.54.1 | SHA3-256 on the download page |
| `gtk4-sdk.json` | wrapdb `sqlite3` | 3.53.4-1 | 3.54.1-1 | none; differs only by version |
| `gettext.json`, `gdal-sdk.json` | libiconv | 1.19 | 1.19.1 | GPG, Bruno Haible's key from GNU's keyring |
| `gnome-text-editor.json` | libspelling | 0.4.10 | 0.4.11 | GNOME's `sha256sum` |
| `gaphor.json` | graphviz | 16.1.0 | 16.1.1 | none published |
| `flameshot.json` | KDSingleApplication | 1.2.0 | 1.2.1 | none published |
| `gtk4-msvc.json` | pins: CMake, Meson | 4.4.4, `9f166093` | 4.4.5, `f0b09326` | |

The other recipes were re-pinned by `scripts/rebuild.sh`. `tests/build.sh` expects SQLite 3.54.1.

What the updates fix, from their notes:

- **LLVM 23.1.5**: a point release; llvm-mingw's own changes are to its build scripts.
- **CPython 3.14.10**: the report's 11 advisories (21 IDs) at 3.14.7, none at 3.14.10.
- **pkgconf 3.0.8** prints `pc_path`, `pc_system_libdirs` and `pc_system_includedirs` with the
  platform's separator, a Windows fix. Every Meson build of the round passed with it.
- **SQLite 3.54.0**: CLI prompts, `.diskused`, query planner work.
- **Rust 1.99.1**: the FFI `bool` miscompilation; `wcslen` on UEFI; rust-lld's rpath on macOS.
- **libiconv 1.19.1**: support for the UTF-8 environment on native Windows.
- **libspelling 0.4.11**: false positives around punctuation, rechecks after a delete or a change
  of language, an uninitialized offset.
- **KDSingleApplication 1.2.1**: a double free when the message handler spins the event loop.

## Digests

The same in `E:\zs\i82\p` and `D:\zs\i82\p2`, built with v0.81.0's release program, in build
order:

| Recipe | Version | Digest |
|---|---|---|
| `sqlite` | 3.54.1 | `59d4a10028ba` |
| `rust` | 1.99.1 | `3bd7b93d9579` |
| `ripgrep` | 15.2.0 | `5b1cf6e0d552` |
| `bat` | 0.26.1 | `edab4b949b8e` |
| `cmake` | 4.4.5 | `0d8b18ea81b0` |
| `zstd` | 1.5.7 | `91a56fddb788` |
| `meson` | 1.12.1 | `f0b0932603e2` |
| `cargo-c` | 0.10.25 | `aae140159b3f` |
| `llvm-mingw` | 20261104 | `7af21d46909f` |
| `gettext` | 1.0 | `c66da37d2503` |
| `gtk4-sdk-base` | 4.24.1 | `68eb757ec84c` |
| `gtk4-sdk` | 4.24.1 | `fcb101c71406` |
| `gtk4` | 4.24.1 | `02b9871c2415` |
| `gnome-text-editor` | 51.0 | `b4abd58bbe81` |
| `rnote` | 0.14.2 | `e1170ebca0ac` |
| `gtk3-sdk` | 3.24.52 | `de76c5d8de61` |
| `gtk3` | 3.24.52 | `a700ac8af113` |
| `gtk3demo` | 3.24.52 | `6bbeb97babe1` |
| `gnumeric` | 1.12.62 | `f5c536e8b155` |
| `pygobject-sdk` | 3.58.1 | `0820d5c5884b` |
| `pygobject` | 3.58.1 | `ff491f9fff29` |
| `meld` | 3.24.1 | `3e0d8b7df6db` |
| `gaphor` | 3.3.2 | `f8490fda373c` |
| `php-yaml` | 2.3.0 | `4dd7cf69ba5d` |
| `php-zstd` | 0.18.0 | `b89a6f30e2d1` |
| `qt6-sdk-base` | 6.12.0 | `77492dcc450f` |
| `qt6-sdk` | 6.12.0 | `b1c559007667` |
| `qt6` | 6.12.0 | `c74a07f23cad` |
| `flameshot` | 14.0.0 | `bd10a092fbe5` |
| `notes` | 2.3.1 | `610ab60b76e4` |
| `gdal-sdk` | 3.13.3 | `02e58e0b5302` |
| `gdal` | 3.13.3 | `de899baa4f0e` |
| `postgresql-sdk` | 18.6 | `4000d6e98d8e` |
| `postgresql` | 18.6 | `0198588f23b9` |
| `postgresql-pgvector` | 0.8.7 | `f511961e5dc7` |
| `postgresql-pg-cron` | 1.6.8 | `5d080db784c0` |
| `postgresql-postgis` | 3.6.4 | `e3fd1466d3d6` |
| `osm2pgsql` | 2.3.1 | `0651ad6a7794` |

`gtk4-msvc` (not published): `729f584ec96c` in `p`, `1434ee0736c6` in `p2`.

## How it was checked

| What | Result |
|---|---|
| The 38 in `p` (2 h 51 min) and `p2` (2 h 52 min) | same digests |
| `gtk4-msvc` in both | builds, no recipe change, 8.5 min each; one file differs (`tiffxx.lib`'s member dates) |
| llvm-mingw's 464 prefetch paths | all in the new layer (the build warns about any that isn't, and didn't) |
| Lazy first compile through a local zot | 3.6 s without the list, 3.2 s with it; full pull 4.2 s ([findings](findings.md#llvm-mingws-prefetch-list-iteration-82)) |
| `tests/build.sh`, sections cmake, llvm, meson, sqlite, rust | 28 ok |
| `tests/gdal.sh` | 32 ok |
| `tests/postgresql.sh` | 61 ok |
| `tests/osm2pgsql.sh` | 43 ok |
| `tests/php.sh`, with the yaml and zstd extensions | 46 ok |
| `tests/gtk.sh`, including the MSVC demos | 100 ok (on the second run, see below) |
| `tests/gtk3.sh` | 45 ok |
| `tests/qt.sh` | 39 ok |
| `scripts/check-upstream.sh` | no python 3.14.7 row; llvm-mingw, cmake, pkgconf, rust, sqlite, libiconv, libspelling, graphviz and kdsingleapplication current |
| A real upgrade v0.80.0 → v0.81.0 | the release's bytes installed |

What the local report still lists that touches this round:

- **SQLite: CVE-2026-119586**, "SQLite CLI through 3.54.1 Command Injection via .recover Output".
  It's the `sqlite3` shell's `.recover`, not the library, and no release fixes it yet; 3.54.1
  is the newest. Its network column is 0.
- **No libiconv row**, where the plan expected one for `php-sdk`'s 1.19: that copy is tracked
  against php.net's own package list (`php-deps/libiconv`), whose newest is still 1.19.
- **New since Monday's report**: zig 0.17.1 (45 rebuilds) and cargo-c 0.10.26, for cargo 0.100.

## What went wrong

- **My suites script left out BusyBox**, which `tests/gtk.sh` wants installed by id for its icon
  fixture; store `p` had BusyBox only as a pinned blob. Three icon rows failed ("isn't an app id or
  an image reference"). Iteration 75's script pulled it first, and I hadn't carried that over.
  After `zigsaw pull net.frippery.busybox:FRP-6075-g169694ebd` (the pinned digest), all 100 rows
  passed.
- **Smaller slips in the kit**: `printf` through the Bash tool turned a `\n` in a C++ string into
  a newline, so hello.cpp is written as a file; a seed with `cp -l dl/*` named downloads by file
  name instead of hash; `zigsaw upgrade --check` doesn't exist.

## Not checked

- **The prefetch list's gain from ghcr.io**, where it should show: from a local registry the full
  pull takes 3.3 s. After publishing, I'll measure 20261020 against 20261104 from ghcr.io.
- **Whether v0.80.0 warns but installs an image signed only keyless**, 81's owed check: these 38
  are the first images only CI signs, after the push.
- **Why libtiff builds `tiffxx` with `-Dcxx=OFF`**, and whether `/Brepro` for `lib` makes
  gtk4-msvc reproduce.
- **pinta** isn't published, so it stays on its old pins.

## What's left for the user, in order

1. **Publish the 38 images, before pushing**, from Git Bash at the repository's root, with the
   frozen program, whose hash the store's build cache keys on. No key is needed:

   ```bash
   ZIGSAW_HOME='E:/zs/i82/p' ZIGSAW='E:\zs\i82\bin\zigsaw.exe' scripts/publish.sh sqlite.json rust.json ripgrep.json bat.json cmake.json zstd.json meson.json cargo-c.json llvm-mingw.json gettext.json gtk4-sdk-base.json gtk4-sdk.json gtk4.json gnome-text-editor.json rnote.json gtk3-sdk.json gtk3.json gtk3demo.json gnumeric.json pygobject-sdk.json pygobject.json meld.json gaphor.json php-yaml.json php-zstd.json qt6-sdk-base.json qt6-sdk.json qt6.json flameshot.json notes.json gdal-sdk.json gdal.json postgresql-sdk.json postgresql.json postgresql-pgvector.json postgresql-pg-cron.json postgresql-postgis.json osm2pgsql.json
   ```

2. **Commit and push.** `docs/iteration-82.md` is the only new file.
3. **I read Reproduce**: every `published` group runs and signs, and `check-pins` shows
   `0 missing, 0 not signed yet` (the GTK and Qt groups may wait for the weekly run, or Run
   workflow by hand).
4. **I pull sqlite 3.54.1 from ghcr.io** with v0.81.0, which should verify it keyless, and with
   v0.80.0, which should warn and install. Then the llvm-mingw timings from ghcr.io.
