# Iteration 61: GDAL and PostgreSQL on upstream Clang

Built 2026-10-30. zigsaw unchanged (**0.60.0**). Nine images to publish:
the new toolchain image `com.github.mstorsjo.llvm-mingw`, and GDAL's and
PostgreSQL's chains, built with it: GDAL's SDK and GDAL, PostgreSQL's SDK
and PostgreSQL, pgvector, pg_cron, PostGIS and osm2pgsql.

## Outcome

- **GDAL's and PostgreSQL's chains build with LLVM's own Clang and lld**
  (23.1.4, from llvm-mingw), and no longer with zig. Their builds are faster
  (GDAL's SDK 12 minutes here instead of 16 to 21, PostgreSQL's 7 instead of
  15), and a link takes a few MB instead of zig 0.17's 906, which ran this
  machine out of memory in iteration 60.
- **Most of what the recipes did for zig is gone**: PostgreSQL's
  `postgres.def` with its own `nm`, its windres, its getopt changes and
  `--allow-multiple-definition` removal; GDAL's CPUID patch; the
  `crt-noexport` objects; the autotools ld and windres wrappers; `CFLAGS=-s`;
  pgvector's `evex512`. lld does what GNU ld does.
- **What Clang 23 and newer mingw-w64 needed instead is small**: five
  missing `#include`s in GEOS and GDAL, json-c's `-Werror` off, a header
  clash in GDAL's libopencad, `WINDRES` for libiconv. One was a real bug:
  PostgreSQL's configure found `__int128` with llvm-mingw, which it didn't
  with zig, and Clang's struct layout then crashed parallel aggregates; the
  recipe turns it off, as zig's build had it.
- **The nine reproduce** in two fresh stores, after one fix: Clang writes
  the time into each object, which static libraries keep.

## Starting decisions

From the planning session (plan file `let-s-plan-iteration-61-snoopy-key.md`):

- **GDAL and PostgreSQL with upstream Clang** (your ask), as **llvm-mingw's
  prebuilt release** 20261020 (your pick, over LLVM's MSVC-only release with
  mingw-w64 and the runtimes built from source, or LLVM built from source).
- **Replace, if it works** (your pick, over an experiment beside the
  published images): all eight recipes move, since GDAL's SDK's static
  GEOS and PROJ need the libc++ of whatever links them.
- Mine: the same variables and alias names as zig's image, so recipes change
  little; libc++, libunwind and winpthreads linked in statically; keep the
  `.dll.a` → `.a` renames, which zig's linker needs if someone builds an
  extension with it.

Decided during (mine):

- **`__int128` off for Clang on Windows**, rather than letting PostgreSQL
  use it with a layout fix: the images then compute as they did.
- **No `as` alias**: llvm-mingw's `x86_64-w64-mingw32-as` links what it's
  given, and nothing in the chain needs one.

## What was built

### Slice 0: probes

Against the unzipped release (scratch `D:\zs\i61\probe`), then through a
throwaway recipe in a store:

- **Runs under a build**: the aliases' shims start llvm-mingw's target
  wrappers, which find Clang beside them; C, C++ with threads and
  exceptions, and windres work.
- **Reproducible**: lld puts the link time in by default and refuses
  `-Brepro`; `-Wl,--no-insert-timestamp` in Clang's configuration file
  leaves it out of every link and says nothing under `-Werror`. (The
  objects' own time showed only later, in slice 2.)
- **Memory**: a link's peak is about 10 MB (lld 7, the driver 3).
- **lld**: `--export-all-symbols` leaves the CRT's symbols out; `-lX` finds
  `libX.dll.a`; compiler-rt has `__cpu_model`.
- **Static C++ runtime**: with libc++'s, libunwind's and winpthreads'
  `.dll.a` removed, a C++ program imports only Windows' DLLs.

### Slice 1: the toolchain image

[recipes/llvm-mingw.json](../recipes/llvm-mingw.json): the release's zip
without the i686, ARM and UWP sysroots and wrappers, lldb and its Python,
clangd, clang-tidy, gendef, widl and make (736 MB to 417 MB deployed, a
108 MB layer). `CC=cc`, `CXX=c++`, `RC=windres`, `LDFLAGS=-s`; aliases for
`cc`, `c++`, `ar`, `ranlib`, `nm`, `strip`, `objdump`, `windres` and
`dlltool`; its `bin` on PATH for configure's `x86_64-w64-mingw32-*`. Its
build adds `-mno-incremental-linker-compatible` and
`-Wl,--no-insert-timestamp` to `bin/mingw32-common.cfg`, removes the five
import libraries, and checks an object and a program compiled 2 s apart, and
a C++ program's imports.

### Slice 2: GDAL's chain

[recipes/gdal-sdk.json](../recipes/gdal-sdk.json): llvm-mingw instead of
zig; `cpu-model.patch`, `crt-noexport` and libiconv's wrappers gone, a check
that `libgdal` exports nothing of the CRT's instead. New: `WINDRES=windres`
for libiconv, json-c's `-DDISABLE_WERROR=ON`, `<type_traits>` and
`<algorithm>` in two GEOS headers, `<cstdlib>` and `<atomic>` in three GDAL
files, and libopencad's include path without its `dwg` folder (each a `sed`
with a check). Found with Ninja's `-k 0` in the kept build: one pass listed
every file LLVM 23's libc++ breaks.

### Slice 3: PostgreSQL's chain

[recipes/postgresql-sdk.json](../recipes/postgresql-sdk.json): llvm-mingw;
[`clang-mingw.patch`](../recipes/postgresql/clang-mingw.patch) in place of
`zig-mingw.patch`: the setjmp change, and no `__int128` (with a check on
`pg_config.h`); no `mingw_gendef.pl`, nm or windres module; pgxs names
`strip` by name (Meson noted the alias's path). pgvector without its
`evex512` `sed`; PostGIS and osm2pgsql without their `-Brepro` and ld
wrapper.

The `__int128` crash: PostgreSQL's regression suite failed 31 of 231 tests
after a backend died (0xC0000005) in a parallel `variance()`. A server from
the kept build with a `crashdumps` folder in its data directory wrote a
minidump, and llvm-mingw's lldb showed `int8_avg_combine` doing `movaps` on
an 8-byte boundary. Clang for MinGW lays a struct with PostgreSQL's
`int128` (`__int128 __attribute__((aligned(8)))`) out on 16 bytes; palloc
gives 8.

### Slice 4: tests, CI, docs

- [tests/build.sh](../tests/build.sh): section `llvm` in the `cmake-meson`
  group: llvm-mingw's image, then the CMake fixture (C, C++, resources)
  built with it, run, checked for llvm-mingw's DLLs, and built again to the
  same image, its static library kept in it.
- [scripts/published-groups.txt](../scripts/published-groups.txt) and
  [published-recipes.txt](../scripts/published-recipes.txt): llvm-mingw in
  the `gdal` group, first; the `postgresql` group pulls it.
- Docs: [recipes.md](recipes.md#clang-llvm-mingw) (a section for the
  toolchain, PostgreSQL's, GDAL's and osm2pgsql's sections),
  [findings](findings.md#gdal-and-postgresql-on-llvm-mingw-iteration-61),
  [published apps](published-apps.md).

## Results

| check | result | time |
|---|---|---|
| the 9 in store `p`, then fresh `p3` | the same manifests in both: llvm-mingw `1fd5d6d8`, GDAL SDK `1aa20e94`, GDAL `6455e6e0`, PostgreSQL SDK `36d028ea`, PostgreSQL `68a21584`, pgvector `2bb37848`, pg_cron `5c6b00d4`, PostGIS `9c2fdbab`, osm2pgsql `d14fa5e2` | 40 s, 11.6, 0.1, 7.2, 0.1 min; extensions under 2.5 min, osm2pgsql 1.6 |
| PostgreSQL's suites, kept SDK build | regress 231, isolation 122, plpgsql 13, plperl 14, plpython 23: all pass (PostgreSQL's layer is the one published here) | 4 min |
| tests/gdal.sh (store `p`) | 0 failed, 32 ok | |
| tests/postgresql.sh (store `p`) | 0 failed, 49 ok, 0 gaps | 59 s |
| tests/osm2pgsql.sh (store `p`) | 0 failed, 43 ok, 0 gaps | 32 s |
| `GROUP=cmake-meson tests/build.sh` | 0 failed, 19 ok, the `llvm` section's 4 among them | 6.5 min |
| least free commit, GDAL's SDK at 18 jobs | 6.9 GB | |
| Defender scan of the nine deployments | no threats | |
| scripts/check-pins.sh | 15 missing, all pins of the new nine | |

## Next

- Publish **before pushing** (the `postgresql` group pulls llvm-mingw's
  image and GDAL's SDK; the suites pull the apps), from store `D:\zs\i61\p`
  with `ZIGSAW=D:\zs\i60\bin\zigsaw.exe`, in this order:
  `scripts/publish.sh llvm-mingw.json gdal-sdk.json gdal.json postgresql-sdk.json postgresql.json postgresql-pgvector.json postgresql-pg-cron.json postgresql-postgis.json osm2pgsql.json`,
  and make `com.github.mstorsjo.llvm-mingw` public on GitHub.
- Then commit and push, and I read the run: the `gdal` and `postgresql`
  groups reproducing on Server 2025, build.sh's `llvm` section, and the
  suites' AC rows.
- No zigsaw change, so no tag.
- Later: GTK's, Qt's and gettext's chains on llvm-mingw too, or on zig 0.17;
  upstream reports for the GEOS and GDAL includes and PostgreSQL's
  `__int128` check, which tests a variable but not a struct of one.
