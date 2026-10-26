# Iteration 48: GDAL, and PostGIS raster

Built 2026-10-26. To publish: GDAL's SDK and GDAL (both new), and PostGIS
again.

## Outcome

- **Iteration 47's red run explained and fixed.** Its run (40143794192,
  40 minutes) failed in one job, `published (postgresql)`: PostGIS didn't
  build on the runner. The SDK, PostgreSQL, pgvector and pg_cron had the
  digests of fresh builds, and the suites passed every AppContainer row on
  Server 2025, PL/Perl and PostGIS included.
  - The cause was a race in PostGIS's own Makefiles. `utils`' make runs
    `make -C ../raster/rt_pg uninstall_rtpostgis.sql` and
    `… rtpostgis_upgrade.sql` side by side under `-j`, and both make
    `rtpostgis.sql` through one `rtpostgis.sql.tmp`: one make's `rm` met
    the other's file. Upstream builds raster before `utils` (its ticket
    5779), so the file is normally there already. Without raster it wasn't,
    and the build here won the race by luck.
  - `utils` makes its targets one at a time now (`.NOTPARALLEL`). A build
    command isn't in an image's config, and a fresh store built the
    published `5ab19b5b`.
- **GDAL 3.13.3**, built with zig:
  - `org.gdal.GDAL.Sdk` holds GDAL and the static libraries it's built on
    (GEOS, PROJ, SQLite, json-c, expat, libiconv), with headers and
    relocatable `gdal-config`, `geos-config` and pkg-config files.
  - `org.gdal.GDAL` is its tools, from the SDK: the `gdal` command,
    `gdalinfo`, `gdalwarp`, `ogr2ogr` and 25 more, exported, in every
    sandbox.
- **PostGIS with rasters** (`postgis_raster`), on GDAL's SDK. GDAL's DLL is
  in PostGIS's image, and PostgreSQL finds it through the extension's PATH
  entry in all three sandboxes, without a patch.
- No zigsaw change (0.44.0).

## Starting decisions

From the planning session (plan file `plan-iteration-48-dynamic-robin.md`):

- **GDAL + PostGIS raster** (your pick, over PostgreSQL's gaps, a PostGIS
  loaders app, and low as the default sandbox).
- Mine:
  - An SDK and an app from it, as PostgreSQL's images are. The SDK takes
    over PostGIS's library modules.
  - GDAL as a DLL, with GDAL's internal copies of its format libraries.
  - PostGIS carries GDAL's DLL and names it in its `path`.
  - A `gdal` CI group, run only when something it's built or tested from
    changes, and weekly.
  - Gates: a zigsaw change, or an SDK over 30 minutes here.

## What was built

### PostGIS's race

[`recipes/postgresql-postgis.json`](../recipes/postgresql-postgis.json)
puts `.NOTPARALLEL:` at the top of `utils/Makefile.in`. Each sub-make still
runs `-j` inside. Raster now builds before `utils` anyway, but the line
stays.

### GDAL's SDK

[`recipes/gdal-sdk.json`](../recipes/gdal-sdk.json), on zig, CMake, Meson's
image (for its pkg-config) and BusyBox:

- **The libraries**: PostGIS's modules, moved here unchanged (libiconv,
  SQLite, json-c, GEOS, PROJ), plus **expat 2.9.0**. SQLite is compiled
  with its R-tree (`SQLITE_ENABLE_RTREE`): GDAL's configure refuses an
  SQLite without it, which its GeoPackage driver needs.
- **GDAL** is one DLL, `libgdal-39.dll`, with all of them inside.
  `GDAL_USE_EXTERNAL_LIBS=OFF`, then SQLite3, GEOS, Iconv, Expat and JSONC
  turned on by name, so GDAL uses its own zlib, libtiff, libgeotiff,
  libjpeg, libpng, giflib, LERC, qhull and Shapelib, and nothing a build
  could find besides. There's no curl, no bindings and no tests. The
  build needed:
  - [`cpu-model.patch`](../recipes/gdal/cpu-model.patch). GDAL checks AVX2
    and FMA with `__builtin_cpu_supports()`, which reads compiler-rt's
    `__cpu_model`. zig's compiler-rt has none for Windows, so the DLL
    didn't link. The patch asks CPUID through `<cpuid.h>` instead, and the
    build fails if a `__builtin_cpu_supports("` is left.
  - The `crt-noexport` object, as GTK's and PostgreSQL's SDKs use. The DLL
    otherwise exported the C runtime's `atexit`, so tools that link it
    had it twice.
  - `-DXML_STATIC`, for the static expat.
- **What other builds use**:
  - The import library is renamed `libgdal.a`.
  - `gdal-config` and `geos-config` work out their prefix from where they
    are, and the pkg-config files use `${pcfiledir}`. The build checks what
    each config script prints, and fails if any of these files still names
    a drive.
- `GDAL_DATA` and `PROJ_DATA` are set in the image. Its exports are `{}`,
  so as not to clash with the app's.

### GDAL

[`recipes/gdal.json`](../recipes/gdal.json): the SDK as an image source,
without headers, libraries, the config scripts, `sqlite3.exe` or
`iconv.exe`.

- All 29 of GDAL's programs are exported.
- Permission: `cwd`.
- `GDAL_DATA` and `PROJ_DATA` point at its own `share`.

### PostGIS

[`recipes/postgresql-postgis.json`](../recipes/postgresql-postgis.json):

- The GDAL SDK is in its `sdk`, and its own library modules are gone.
  Configure gets `--with-raster` and the SDK's `gdal-config` and
  `geos-config`. The SDK's path is mapped away from `__FILE__`, as
  PostgreSQL's SDK's is.
- The raster loader (`raster2pgsql`) is left out, as `shp2pgsql` was:
  `raster/Makefile.in` made and installed it whatever configure said.
  Raster's functions are declared `PGDLLEXPORT` too.
- The image carries `libgdal-39.dll` in its `bin`, which its `path` names.
  It also carries GDAL's and PROJ's data, under `GDAL_DATA` and
  `PROJ_DATA`. The DLL guard now covers that `bin` and the GDAL SDK's paths.
- Its layer is 29 MB (12 before). Next to the published PostGIS:
  - `postgis_topology-3.dll` is byte for byte the same.
  - `postgis-3.dll` is 46 KB bigger: its SQLite (inside PROJ) now has the
    R-tree.

### Tests, CI and docs

- [`tests/gdal.sh`](../tests/gdal.sh) (new) checks in soft, low and
  AppContainer, all from a scratch working directory. About 10 s.
  - Both programs' versions.
  - `gdalsrsinfo` from `proj.db`, and `gdaltransform` of a point.
  - A GeoTIFF made and read with statistics, warped to 3857, and made a PNG.
  - GeoJSON into a GeoPackage (and its R-tree) and into KML.
  - `-clipsrc` (GEOS), and `gdal raster info`.
  - Last: nothing written in the store's deployments.
- [`tests/postgresql.sh`](../tests/postgresql.sh) gets raster rows in each
  sandbox:
  - `postgis_gdal_version()`.
  - A band's value and mean.
  - `ST_Transform` to 3857.
  - GeoTIFF out and back.
  - A PNG.
- CI:
  - A `gdal` group (gdal-sdk, gdal) with a 90-minute timeout.
    `scripts/ci-groups.sh` checks it only when something it's built or
    tested from changed, and weekly, as it does TeX Live's.
  - PostGIS stays in `postgresql` and pulls the SDK.
  - The suites job seeds `gdal` and runs `tests/gdal.sh`.
- Docs:
  - recipes.md: a GDAL section, and PostGIS rewritten.
  - gaps.md: PostGIS's leftovers and GDAL's missing drivers. The stale
    "pull and update don't ask" line is gone; they have asked since 0.44.0.
  - published-apps.md and README.

## Results

| check | result | time |
|---|---|---|
| PostGIS with `.NOTPARALLEL` (unchanged recipe otherwise), fresh store | `5ab19b5b`, the published digest | |
| GDAL SDK, fresh stores p and p2 | `4e13cd0a` in both (layer 39 MB) | 16 / 21 min |
| GDAL, p and p2 | `bc41ac56` in both (layer 25 MB) | |
| PostGIS, p and p2 | `1fbdd05e` in both (layer 29 MB) | 2.5 min |
| tests/gdal.sh (store p) | 32 ok | 11 s |
| tests/postgresql.sh (store p, published PostgreSQL, pgvector and pg_cron) | 48 ok, 1 known gap | 102 s |
| `GROUP=gdal tests/published.sh` (store p2) | 0 failed, 2 not published yet; groups cover each recipe once | 15 s |
| scripts/check-pins.sh | only the two new images and the SDK pin of GDAL and PostGIS missing | 67 s |

The SDK's first build here took 16 minutes: about 7 for GDAL's 1,500
compiles, 1.3 for its CMake configure, and 2 each for GEOS and libiconv.
The second, in a fresh store, took 21.

## Decisions made along the way

- **SQLite with its R-tree** (my call). It changes PostGIS's
  `postgis-3.dll`, which is republished anyway.
- **CPUID instead of `__builtin_cpu_supports`** (my call, over a
  `__cpu_model` of our own). It's two call sites, and GDAL keeps its AVX2
  paths.
- **The whole suite in each sandbox** (my call). I trimmed it for low and
  AppContainer after a first run took 3 minutes, then put it back: those
  minutes were the first runs granting the new deployments, and the suite
  takes 11 s after.

## Known gaps

- AppContainer on Server 2025 is unproven for GDAL and PostGIS raster
  until the next run.
- GDAL: no network drivers, none whose libraries it doesn't build (netCDF,
  HDF, PDF, WebP...), no Python scripts.
- PostGIS: no protobuf, address standardizer, SFCGAL or loaders. GDAL's
  DLL is on the server's PATH, so programs the server starts see it too.

## Next

- **Publish** from `D:\zs\i48\p`, with `ZIGSAW=D:\zs\i48\bin\zigsaw.exe`,
  in order: `gdal-sdk.json`, `gdal.json`, `postgresql-postgis.json`. Make
  GDAL's SDK and GDAL public. Then commit and push. After that I read the
  run: the gdal job's time on a runner, and GDAL and PostGIS raster in an
  AppContainer on Server 2025.
- PostGIS's loaders, `raster2pgsql` among them, as an app of their own on
  GDAL.
- Extensions for `postgres` and `pg_ctl start`.
