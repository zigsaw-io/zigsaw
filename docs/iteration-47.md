# Iteration 47: PostgreSQL's images on any volume, PL/Perl in AppContainer, and PostGIS

Built 2026-10-25. To publish: PostgreSQL's SDK, PostgreSQL, pgvector and
pg_cron again, and PostGIS (new).

## Outcome

- **Iteration 46's red run explained and fixed.** Its run (40122820476)
  failed in two jobs; the initdb fix itself worked on Server 2025, and
  PostgreSQL reproduced.
  - **The SDK** differed from the published one in a single line of pgxs's
    `Makefile.global`: `TAR = C:/WINDOWS/System32\tar.exe` here,
    `C:/Windows/…` on the runner (Meson found the host's tar). It's named
    by name now, and the build fails on any other host path there.
  - **pgvector and pg_cron** differed because the published DLLs held
    `include\POSTGR~1\server`, an **8.3 short name**: PostgreSQL turns
    every path it works out into its short name where the volume makes
    them (`cleanup_path()` calls `GetShortPathName`), so `pg_config` printed
    them, pgxs compiled with them, and headers' `__FILE__` kept them. D:
    here makes short names, the runner's doesn't, and the `~N` depends on
    the order directories were made in (one store here had both). `pg_config`
    prints long paths now. The rebuilt DLLs are byte for byte the runner's.
  - **PL/Perl in an AppContainer on Server 2025** failed with an empty
    error: PL/Perl starts Perl with `-e`, and with `-e` Perl opens `nul` as
    its script, which an AppContainer there can't. On Windows, Perl now
    reads PL/Perl's boot code from a file in `share\postgresql`, and
    `plperl.on_init` runs after it.
- **PostGIS 3.6.4** as an extension image, `org.postgresql.PostgreSQL.PostGIS`:
  GEOS 3.15.0, PROJ 9.9.0 (with `proj.db`), json-c 0.19, SQLite and libiconv
  built with zig and linked in statically, topology and the TIGER
  geocoder, in all three sandboxes. Its layer is 12 MB.
- An audit of every deployment in the big store (`D:\zs\a`) for short names
  found nothing else: no other image holds a path with one.
- No zigsaw change (0.44.0).

## Starting decisions

From the planning session (plan file
`plan-iteration-47-steady-pebble.md`):

- **Patch PL/Perl** (your pick over a known gap).
- **`pg_config` prints long paths** (your pick over rewriting pgxs only):
  it covers anything that asks `pg_config` for a path, as PostGIS's
  configure does.
- **PostGIS** as the feature (your pick over extensions for `postgres` and
  `pg_ctl start`, low as the default sandbox, or fixes only).
- Mine: PostGIS's libraries static in its DLLs, as PostgreSQL loads
  extensions with `LoadLibrary` (no search beside the DLL); `PROJ_DATA`
  in the extension's env; no raster, protobuf or address standardizer; one
  CI group if PostGIS builds in under 15 minutes here.

## What was built

### PostgreSQL's SDK and runtime

- [`pg-config-long.patch`](../recipes/postgresql/pg-config-long.patch):
  `pg_config` gives each path to `GetLongPathNameA` and prints what it
  returns (with `/`), or the path as it was if that fails. The server and
  initdb still shorten what they use themselves.
- [`plperl-nul.patch`](../recipes/postgresql/plperl-nul.patch): on Windows,
  `perl_parse` gets `<share>/plperl_boot.pl` instead of `-e PLC_PERLBOOT`
  (the file is PL/Perl's `plc_perlboot.pl`, which Meson now installs under
  that name, so the test suites' installs have it too), with an error
  naming the file if it can't be read. `plperl.on_init`, the second `-e`
  before, runs with `eval_pv` after `perl_run`, in package `main` under the
  boot code's pragmas, its errors reported as before. My first version
  copied the file in the recipe: PostgreSQL's plperl suite then failed all
  14 tests, as its temporary install lacked the file.
- [`recipes/postgresql-sdk.json`](../recipes/postgresql-sdk.json): both
  patches; `TAR` by name in `Makefile.global`, and the build fails if a
  variable there still names a drive (`^[A-Z_]+ = X:`); a check that the
  installed boot file is PL/Perl's.
- [`recipes/postgresql.json`](../recipes/postgresql.json): the new SDK.

### pgvector and pg_cron

- Both pin the new SDK, and their builds fail if a DLL holds a short name
  after `pgsdk` (`grep -aqE 'pgsdk[^[:cntrl:]]*~[0-9]'`): that check finds
  the published DLLs and passes the runner's.

### PostGIS

[`recipes/postgresql-postgis.json`](../recipes/postgresql-postgis.json),
on PostgreSQL's SDK, GNU make, Meson's image (for its pkg-config), CMake,
Perl, zig and BusyBox:

- **libiconv 1.19** static (autotools, as gettext's image builds it, with
  its windres wrapper: a static build still compiles its `.rc`).
- **SQLite 3.53.4** from the amalgamation: a static library and the
  `sqlite3.exe` PROJ makes `proj.db` with.
- **json-c 0.19**, **GEOS 3.15.0** and **PROJ 9.9.0** with CMake, static.
  GEOS from GitHub's tag archive (its release is only a `.tar.bz2`, which
  zigsaw doesn't unpack); `geos-config --clibs` gets `-lgeos -lc++` for a
  static link. PROJ without TIFF or curl (no grids beyond `proj.db`, no
  downloads); its `proj.pc` named MSVC's `-lproj_9` and a `sqlite3.pc` there
  isn't, so the recipe writes what a static link needs.
- **PostGIS**, configured and built under BusyBox, as upstream does. What it
  needed:
  - `PATH_SEPARATOR=;` (as Ghostscript's and Gnumeric's recipes have), and
    `perl` and `pg_config` as full paths: configure looks for programs by
    their names without `.exe`.
  - PROJ through pkg-config (`--static`) rather than `--with-projdir`, which
    links its test with `-lproj` alone.
  - forward slashes in its directory options (`B:\prefix` lost its
    backslash in the Makefiles).
  - the SQL preprocessor as `cc -E -x c -traditional-cpp -P -w`.
  - FlatGeobuf's C++ with `c++ -std=c++11 -O2 -s`: configure picks
    `pg_config --cc` with `-x c++`, and zig's `cc` has no C++ headers;
    without `-O`, zig builds debug code with UBSan, which didn't link.
  - FlatGeobuf's archive named `libflatgeobuf.a` (configure names it
    `.la`, which zig's linker refuses by its extension).
  - `PGDLLEXPORT` on the functions PostGIS declares before using them:
    `PG_FUNCTION_INFO_V1` later declares them `dllexport`, which clang
    refuses for a function already used (MSVC builds don't meet it).
  - no loaders (`shp2pgsql`, `pgsql2shp`): their rules compile without
    `-o` (zig's `cc -c` writes `.obj`), and an extension exports no
    commands anyway.
  - `--disable-extension-upgrades-install`: no upgrade scripts from PostGIS
    versions this image never had. The three `…--ANY.sql` stubs it still
    makes are links, which a layer can't hold, so they're copies.
  - `INSTALL="install -c"` for `make install` (libtool misread pgxs's
    `sh …/install-sh -c`), and the SDK mapped away from `__FILE__` (none
    was there).
- `postgis-3.dll` (20 MB, GEOS and PROJ inside) and `postgis_topology-3.dll`
  import only Windows' DLLs and the server. `PROJ_DATA=${app}\share\proj`
  joins the server's runs with the extension, and `proj.db` is the same in
  every store.

### Tests, CI and docs

- [`tests/postgresql.sh`](../tests/postgresql.sh): PL/Perl and PL/Python
  are a row each in low and AppContainer, so CI shows them apart, and
  `plperl.on_init` (set on the server's command line) is checked from
  PL/PerlU. PostGIS in every sandbox: its versions (3.6.4, GEOS 3.15.0, PROJ
  9.9.0), a point from 4326 to 3857 (proj.db), `ST_Intersects` of a buffer,
  GeoJSON both ways, GML, a GiST index in the plan; under soft, a topology
  with an edge.
- PostGIS joins the `postgresql` group (9 minutes here), after pg_cron in
  `published-recipes.txt`; the suites job seeds it.
- docs: recipes.md (PL/Perl, `pg_config`, PostGIS), gaps.md (PostGIS's
  leftovers; the old "no SDK for extensions" line), published-apps.md,
  README.

## Results

| check | result | time |
|---|---|---|
| runner's pgvector/pg_cron DLLs vs this build's (first SDK fix) | byte-identical | |
| PostgreSQL SDK, p and p2 (final) | `c685eda6` in both | 15 min |
| PostgreSQL, p and p2 | `d048c65b` in both | |
| pgvector, p and p2 | `7d0c8e4d` in both | |
| pg_cron, p and p2 | `8bd7d7f1` in both | |
| PostGIS, p and p2 | `5ab19b5b` in both (layer 12 MB) | 9 min |
| PostgreSQL's plperl, plpython, plpgsql suites (kept SDK build) | 14, 23 and 13 tests pass | 5 min |
| tests/postgresql.sh (store p, final images) | 45 ok, 1 known gap | 100 s |
| published groups cover each recipe once | 0 problems | |
| scripts/check-pins.sh | only the new SDK pin (4 recipes) and PostGIS unpublished | 67 s |
| short names in `D:\zs\a`'s deployments | none in a path | |

`GROUP=postgresql tests/published.sh` wasn't run: until the images are
published, it can only report that they differ from ghcr.io's.

## Decisions made along the way

- **Meson installs the boot file** (my call, over the recipe copying it):
  the regression suites' installs need it too.
- **`plperl.on_init` in package `main` with the boot code's pragmas**
  (my call): what a second `-e` saw.
- **No PostGIS loaders, no upgrade scripts from older versions** (my call).
- **PostGIS in the `postgresql` group** (my call; 9 minutes here, under the
  plan's 15).

## Known gaps

- AppContainer on Server 2025 is unproven for PL/Perl and PostGIS until the
  next run; PL/Python's row there is new.
- Only `postgresql` (the launcher) loads extensions.
- A client outside an AppContainer still can't reach a server in one.
- PostGIS: no raster (GDAL), `ST_AsMVT`/`ST_AsGeobuf` (protobuf), address
  standardizer or loaders; PROJ has `proj.db`'s definitions and no grids.

## Next

- **Publish** (from `D:\zs\i47\p`, with `ZIGSAW=D:\zs\i47\bin\zigsaw.exe`) in
  order: `postgresql-sdk.json`, `postgresql.json`,
  `postgresql-pgvector.json`, `postgresql-pg-cron.json`,
  `postgresql-postgis.json` (make PostGIS public); then commit and push, and
  I read the run: the postgresql group, PL/Perl, PL/Python and PostGIS in
  an AppContainer on Server 2025.
- PostGIS raster with GDAL; PostGIS's loaders as an app of their own.
- Extensions for `postgres` and `pg_ctl start`; pg_cron's libpq mode on
  Windows.
- PostgreSQL 19 once it's out (RC1 on 2026-10-15); Temurin 25.0.5 on
  Windows still pending.
