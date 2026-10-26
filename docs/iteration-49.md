# Iteration 49: osm2pgsql

Built 2026-10-26. To publish: osm2pgsql (new).

## Outcome

- **Iteration 48's run** (40254930723) was green, except for one job:
  `published (apps)` was cancelled at its 30-minute timeout. That job
  usually takes 8 to 14 minutes. It left no logs, because the upload step
  ran only `if: !cancelled()`. Rerun on its own, it passed in 8 minutes, so
  a runner was slow or stuck.
  - The published jobs now upload their logs `always()`.
  - The suites jobs, which upload on failure, now also upload when
    cancelled.
- **osm2pgsql 2.3.1**, built with zig, as an app of its own
  (`org.osm2pgsql.osm2pgsql`):
  - It exports `osm2pgsql` and `osm2pgsql-expire`, with the `network` and
    `cwd` permissions.
  - It's built on PostgreSQL's SDK (libpq, zlib) and GDAL's (PROJ, SQLite,
    expat), with Lua 5.4.9, bzip2, nlohmann/json and Boost's headers from
    its own recipe.
- It works under soft and low against a local server. In an AppContainer it
  can't reach one: that's the known loopback gap.
- No zigsaw change (0.44.0).

## Starting decisions

From the planning session (plan file `plan-to-build-osm2pgsql-cuddly-taco.md`):

- **An app of its own** (your pick, over a PostgreSQL extension). As an
  extension it would have worked in an AppContainer too, inside
  PostgreSQL's container, but extensions export nothing. As an app, it
  carries its own `libpq.dll`.
- Mine:
  - Lua 5.4, not 5.5: osm2pgsql's CMake looks for 5.1 to 5.4.
  - Static libraries everywhere but libpq.
  - Tiny hand-written fixtures, with no download in the suite.
  - osm2pgsql in the `postgresql` CI group.
  - Gates: a zigsaw change, a build over 20 minutes, or Boost or Lua needing
    more than a small patch.

## What was built

### The recipe

[`recipes/osm2pgsql.json`](../recipes/osm2pgsql.json), on PostgreSQL's SDK
(`c685eda6`), GDAL's SDK (`4e13cd0a`), CMake, zig and BusyBox. Its modules:

- **bzip2** 1.0.8: seven compiles into `libbz2.a`.
- **Lua** 5.4.9: its library's sources into `liblua.a`. zig's `cc -c` names
  its objects `.obj` on Windows, so both modules name them with `-o`.
- **nlohmann/json** 3.12.0: its headers (`include.zip`).
- **Boost** 1.92.0, headers only. osm2pgsql uses only Geometry, which is
  header-only.
  - Boost's CMake release has a link to a directory (in a library's docs),
    which zigsaw's tar reader refuses (`TarLinkNotToAFile`). A URL source
    can't `skip`.
  - Its CMake build of Geometry includes the 80 libraries Geometry depends
    on, thread, serialization and regex among them, which it compiles.
  - So the b2 release (52 MB) is fetched as a file, and BusyBox's `tar`
    unpacks only `boost/`, in 26 s.
  - [`BoostConfig.cmake`](../recipes/osm2pgsql/BoostConfig.cmake) and its
    version file satisfy `find_package(Boost CONFIG)`.
  - The full CMake tree would have been 683 MB, in 89 s.
- **osm2pgsql**, with its own libosmium, protozero, fmt and CLI11:
  - `-D_POSIX_THREAD_SAFE_FUNCTIONS=200112L`: `logging.cpp` calls
    `localtime_r` outside MSVC, which MinGW's `time.h` declares only then.
  - `-DXML_STATIC`, `-DNOMINMAX` and `-DWIN32_LEAN_AND_MEAN`. `bzlib.h`
    includes `windows.h`.
  - `CMAKE_CXX_STANDARD_LIBRARIES=-lsqlite3 -lshell32 -lole32`, which the
    static PROJ needs, and `-L` to GDAL's SDK.
  - [`default-style.patch`](../recipes/osm2pgsql/default-style.patch). On
    Windows, `DEFAULT_STYLE` is `default.style` in the working directory.
    The patch looks next to the program instead, in `..\share\osm2pgsql`,
    found through `GetModuleFileNameW`.
  - The image has:
    - `libpq.dll`, from PostgreSQL's SDK. It needs only system DLLs, and
      OpenSSL is linked into it.
    - PROJ's data, under `PROJ_DATA`.
    - Upstream's `flex-config` example styles.
    - Licences for everything linked in.
  - The build prints `--version` (osm2pgsql 2.3.1, Libosmium 2.23.1,
    Proj 9.9.0, nlohmann JSON 3.12.0, Lua 5.4.9). It fails if a program
    names an SDK's deployment.
  - The programs import only system DLLs and `libpq.dll`.
  - No `osm2pgsql-gen` (no potrace or OpenCV), and no
    `osm2pgsql-replication` (Python, pyosmium, psycopg).

### Tests

[`tests/osm2pgsql.sh`](../tests/osm2pgsql.sh) (new) runs PostgreSQL's
server with PostGIS under soft, on a port of its own. Each sandbox gets a
database with PostGIS and hstore, and osm2pgsql runs from a scratch working
directory, with `PGPASSWORD`. About 40 s.

Under soft and low:

- `--version`.
- `-W` reading the password from stdin.
- The pgsql output with the default style (the patch), `--slim
  --hstore-all`, from `.osm`: two points, a line and two polygons, UTF-8
  names.
- `--append` of a change file: the café renamed, the museum gone, a bench
  new, and the tile expired (`14/8529/5974`).
- The flex output from PBF, with `--flat-nodes`:
  - The style `require`s a module from the working directory.
  - It makes three tables.
  - The park, in UTM 32N, has the area PostGIS computes for the same
    polygon less its pond.
- gzip and bzip2 input.
- `osm2pgsql-expire`.

Under AppContainer:

- `osm2pgsql-expire` runs.
- Reaching the server is a known gap. The suite sets `PGCONNECT_TIMEOUT=5`:
  without it, libpq waits 42 s there.

Last: nothing written in the deployments, and nothing labelled in the
repository.

The fixtures, in `tests/osm2pgsql/`:

- `tiny.osm`, by hand: 17 nodes, 4 ways and a multipolygon with a hole, in
  Monaco.
- `change.osc`.
- `style.lua` and `naming.lua`.
- `tiny.osm.pbf` (492 bytes). It's made from `tiny.osm` by
  [`topbf.py`](../tests/osm2pgsql/topbf.py), a standard-library PBF writer.
  It's committed, so the suite doesn't need Python, and `.gitattributes`
  marks it binary.

One trap, fixed before the first full run: the suite's command wrapper
pipes through `tr`, so its exit status was `tr`'s. The AppContainer row
"passed". It now returns `PIPESTATUS[0]`.

### CI and docs

- osm2pgsql is in `published-recipes.txt`, and in the `postgresql` group,
  after PostGIS. That group took 29 of its 75 minutes in the last run.
- The suites job seeds osm2pgsql and runs `tests/osm2pgsql.sh` after
  `tests/postgresql.sh`. Until it's published, the seed builds it (about 2
  minutes).
- recipes.md: an osm2pgsql section.
- gaps.md: AppContainer to a local server, the password file, and the
  missing scripts and Lua C modules.
- published-apps.md and the README's list of suites.

## Results

| check | result | time |
|---|---|---|
| osm2pgsql, store p (rebuilt after the last recipe change) and fresh store p2 | `99b4e434` in both (layer `5a79ed22`, 15 MB) | 2 min (4 in the fresh store) |
| tests/osm2pgsql.sh (store p, published PostgreSQL and PostGIS) | 40 ok, 1 known gap | 41 s |
| `GROUP=postgresql tests/published.sh` (store p2, the other six skipped) | 0 failed, 1 not published yet | 14 s |
| scripts/check-pins.sh | only osm2pgsql missing | 72 s |
| iteration 48's `published (apps)`, rerun | passed | 8 min |

The compile is 65 steps in 74 s. The modules before it take about 45 s:
Boost's unpack 26 s, Lua 9 s and bzip2 7 s (each compiled one file at a
time).

## Decisions made along the way

- **Boost's headers from the b2 release, with a config of our own** (my
  call). The alternatives were a zigsaw change, to follow or drop a link to
  a directory, or building 80 Boost libraries for a header-only one.
- **`_POSIX_THREAD_SAFE_FUNCTIONS` instead of a patch** (my call): one
  define, and the code is upstream's.
- **The patch for the default style** (my call). Without it, `-O pgsql`
  with no `--style` fails unless the working directory holds
  `default.style`.

## Known gaps

- Under `--sandbox=appcontainer`, osm2pgsql can't reach a server on this
  machine.
- osm2pgsql can't read PostgreSQL's password file: use `-W` or
  `PGPASSWORD`.
- No `osm2pgsql-replication`, no `osm2pgsql-gen`, and no Lua C modules.
- On a runner, osm2pgsql is unproven until the next run, under low and soft
  on Server 2025 included.

## Next

- **Publish** `osm2pgsql.json` from `D:\zs\i49\p`, with
  `ZIGSAW=D:\zs\i48\bin\zigsaw.exe`, and make it public. Then commit and
  push.
- After that I read the run: the postgresql group's time, and the
  osm2pgsql suite on a runner.
- `osm2pgsql-replication`, on Python's image with pyosmium and psycopg, as
  a later app.
- PostGIS's loaders (`shp2pgsql`, `raster2pgsql`), as an app on GDAL.
