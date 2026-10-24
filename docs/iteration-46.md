# Iteration 46: PostgreSQL in AppContainer on Server 2025, and its extensions

Built 2026-10-24. To publish: GNU make, PostgreSQL's SDK, PostgreSQL again,
pgvector and pg_cron.

## Outcome

- **Iteration 45's red run explained and fixed.** Its only failures were
  `tests/postgresql.sh`'s AppContainer rows on the runner: initdb's last step
  runs a backend through cmd.exe with `>nul`, and an AppContainer on Server
  2025 can't open `nul` (the runner's probe says so; Windows 11 26300's can).
  initdb now sends that output to a file in the cluster's directory. Only the
  next run can show it on Server 2025; here, all three sandboxes pass as
  before. The suite now leaves each server's whole output in `LOG_DIR`, so
  CI shows initdb's own words next time, not one cut line.
- **PostgreSQL extensions as images.** PostgreSQL's image has an extension
  point; an installed extension joins every run of its server, as PHP's do.
  The first two: **pgvector 0.8.7** (an HNSW index answers a
  nearest-neighbour query) and **pg_cron 1.6.8** (preloaded, a job every
  second), both in soft, low and AppContainer.
- **They build as upstream says, with pgxs**, from a new
  **PostgreSQL SDK** (`org.postgresql.PostgreSQL.Sdk`: headers, libraries,
  pg_config, pgxs) and a new **GNU make** image (`org.gnu.make` 4.4.1, built
  with zig), since pgxs is GNU make's. PostgreSQL's image takes its files
  from the SDK, as GTK's runtime does from GTK's.
- No zigsaw change (0.44.0).

## Starting decisions

From the planning session (plan file
`let-s-plan-iteration-46-breezy-diffie.md`):

- **Patch initdb** (your pick over a known gap).
- **A PostgreSQL extension SDK** (your pick of feature), with **GNU make and
  real pgxs** (your pick over a script of our own that compiles an
  extension's files), proofs **pgvector and pg_cron** (your pick; pg_cron is
  one the server must preload).
- Mine: the SDK/runtime split, the point's version `18` (the major,
  `PG_MODULE_MAGIC`'s), the launcher turning the joined variables into
  settings, pgvector without `-march=native`.

## What was built

### initdb without nul

- [`initdb-nul.patch`](../recipes/postgresql/initdb-nul.patch): the
  post-bootstrap backend's stdout goes to `<pgdata>/initdb-post.out`,
  removed after the backend exits (with the directory if initdb fails and
  cleans up). Its errors went to stderr already. initdb's earlier
  `--check` probes also use `nul`, and fail in an AppContainer anyway
  (they can't start postgres through cmd.exe there), so the launcher's
  `-c max_connections/shared_buffers` stays the answer to those.
- [`tests/postgresql.sh`](../tests/postgresql.sh) copies every server's
  output (initdb's included) to `LOG_DIR`, which CI uploads.

### GNU make

- [`recipes/make.json`](../recipes/make.json): GNU make 4.4.1 from its
  tarball, the sources `build_w32.bat` compiles, with `cc`, no configure
  (15 s). Aliases `make` and `gmake`, so they win over BusyBox's pdpmake.
- [`sh.c`](../recipes/make/sh.c): GNU make on Windows runs recipes in the
  first `sh.exe` on PATH (cmd.exe without one), and BusyBox's image has
  only `busybox.exe`; this `sh.exe` runs `busybox.exe sh` with its own
  command line, in a job that ends with it.
- [`posix-shell.patch`](../recipes/make/posix-shell.patch): GNU make starts
  a line without shell syntax itself (`mkdir -p out` with no shell), where
  on Windows `mkdir` and `echo` are BusyBox's applets, not programs; with a
  POSIX shell, every line now goes through it. (My first try sent the
  shell's own command line, which make parses again with no shell, back to
  the shell too: it recursed until "virtual memory exhausted".)
- The builder looks for an `sh.exe` before `busybox.exe`, so builds with
  this image run their commands through the forwarder too.
- tests/build.sh `make` section (cmake-meson group): a Makefile only GNU
  make reads, `-j4`, a sub-make, BusyBox's applets on plain lines.

### PostgreSQL's SDK and runtime

- [`recipes/postgresql-sdk.json`](../recipes/postgresql-sdk.json): the
  modules that were PostgreSQL's (with the initdb patch), Perl and Python
  as SDKs rather than runtimes (the build needs them; extension builds
  don't), keeping include, static and import libraries, pkg-config files,
  pg_config and pgxs. Its last module:
  - names each import library `lib<name>.a`, in place of the static one: zig's
    linker looks for `-lpq` as `libpq.a` only, never `libpq.dll.a`, so
    pg_cron linked the static libpq with LDAP and SSPI unresolved;
  - rewrites pgxs's `Makefile.global` so it names tools rather than paths
    (`perl`, not the store's Perl, which made each store's layer differ in
    iteration 45; `ar`, `windres`...) and drops the build's `noexport.o`
    from `LDFLAGS` (extensions mark their exports, so the DLL's exports are
    the same without it);
  - makes the `.pc` files relocatable, as Qt's are;
  - compiles zlib, lz4, zstd, libxml2 and PostgreSQL with `CFLAGS=-s`, as
    OpenSSL already was: zig's cc writes CodeView debug info into objects
    unless told not to (clang's command line, with the store's path to
    zig, and a random temporary name), so the static libraries differed
    from store to store, while everything linked from them (with `-s`)
    didn't. The runtime had dropped every `.a`, so it never showed;
    the SDK's first build in a second store did;
  - fails the build if pgxs or a `.pc` still names `B:\src`, `B:\bin` or a
    deployment.
- [`recipes/postgresql.json`](../recipes/postgresql.json): the SDK as an
  image source with the old cleanup, the same env, exports and runtimes,
  and the point `org.postgresql.PostgreSQL` at `18`, joining
  `PG_EXTENSION_DIRS` and `PG_PRELOAD_LIBRARIES`.
- [`pg-server.c`](../recipes/postgresql/pg-server.c): with those set,
  postgres gets `extension_control_path=$system;<dir>\share…`,
  `dynamic_library_path=$libdir;<dir>\lib…` and `shared_preload_libraries`,
  before the given options (a later `-c` wins), and only for a server run
  (postgres reads `--version` only as its first argument). PostgreSQL 18
  needed no patch: a control file found on the path loads its
  `$libdir/vector` from `dynamic_library_path`.

### pgvector and pg_cron

- [`recipes/postgresql-pgvector.json`](../recipes/postgresql-pgvector.json):
  `make USE_PGXS=1 OPTFLAGS=` (pgvector's default `-march=native` would tie
  the image to the building CPU), installed with `pkglibdir`, `datadir` and
  `includedir_server` pointing into `$PREFIX`. zig's clang 21 refused
  pgvector's AVX-512 functions ("requires target feature 'evex512'"); a sed
  adds `evex512` to their `target` attribute, so run-time dispatch stays.
- [`recipes/postgresql-pg-cron.json`](../recipes/postgresql-pg-cron.json):
  `PG_PRELOAD_LIBRARIES=pg_cron`. With its default libpq connections, every
  job stayed "connecting" and timed out at startup (on 127.0.0.1 too):
  pg_cron polls libpq's socket with WSAPoll on Windows, and the connection
  never moved on. With `cron.use_background_workers` on, jobs run in
  background workers, without a connection or a password; the recipe makes
  that the default (a sed).
- Both build with `COPT=-fmacro-prefix-map=<the SDK's directory>=pgsdk`
  (pgxs adds `COPT` to `CFLAGS`), as GTK 3's SDK does with GTK's: some of
  PostgreSQL's headers expand `__FILE__`, which named the SDK's deployment
  in the store (pg_config's path for it), so vector.dll differed between
  stores in `.rdata`, and its `-Brepro` timestamp with it.
- Both carry an `about.bat`, as PHP's extensions do.

### Tests, CI and docs

- tests/postgresql.sh: the store needs both extensions; per sandbox, the
  HNSW query (with its plan using the index) and a one-second pg_cron job;
  in soft, `--noextension=…pg_cron` starts a server that preloads nothing
  while pgvector still joins.
- scripts/published-groups.txt: the `postgresql` group builds make, the SDK,
  PostgreSQL and both extensions; published-recipes.txt lists them in that
  order. The suites job seeds both extensions.
- docs: recipes.md (GNU make; PostgreSQL's SDK, the nul patch, extensions),
  published-apps.md, README.

## Results

| check | result | time |
|---|---|---|
| PostgreSQL with only the initdb patch, store p | built | |
| tests/postgresql.sh on it | 28 ok, 1 known gap | |
| GNU make, stores p and p2 | `045e39d4` in both (layer 223 KB) | 1m23s |
| `GROUP=cmake-meson tests/build.sh` (with the new make section) | 0 failed | 320 s |
| PostgreSQL SDK, first try, p and p2 | `7cdc0274` / `e19a418f`: only static libraries differed (debug info) | 10–14 min |
| PostgreSQL SDK with `CFLAGS=-s`, p and p2 | `04a5c98a` in both (layer 41.5 MB) | 9m58s |
| PostgreSQL from it, p and p2 | `d1bcc6ff` in both (layer 33 MB) | 5 s |
| pgvector, first try, p and p2 | DLLs differed: headers' `__FILE__` with the store's SDK path | 13 s |
| pgvector with the prefix map, p and p2 | `1eb1c842` in both | 13 s |
| pg_cron with the prefix map, p and p2 | `2a8ceb2f` in both | 5 s |
| tests/postgresql.sh with both (store p, final images) | 37 ok, 1 known gap | 98 s |
| published groups cover each recipe once | 0 problems | |
| scripts/check-pins.sh | only the four new images, and what pins them | |

## Decisions made along the way

- **pg_cron in background workers by default** (my call, the plan's
  fallback): the libpq path doesn't work on Windows here, and with workers
  pg_cron needs no password either.
- **No `noexport.o` for extensions** (my call): same exports without it.
- **`sh.exe` on the build's PATH** (my call): GNU make finds its shell only
  as `sh.exe` on PATH (MAKESHELL and SHELL from the environment are for DOS
  and OS/2), so the builder's own lookup now finds the forwarder too.

## Known gaps

- Only `postgresql` (the launcher) loads extensions; `postgres` and
  `pg_ctl start` run on their own don't.
- AppContainer on Server 2025 is unproven until the next run.
- A client outside an AppContainer still can't reach a server in one.

## Next

- **Publish** (from `D:\zs\i46\p`, with `ZIGSAW=D:\zs\i46\bin\zigsaw.exe`) in order: `make.json`, `postgresql-sdk.json`,
  `postgresql.json`, `postgresql-pgvector.json`, `postgresql-pg-cron.json`
  (make the four new packages public); then commit and push, and I read
  the run (the AppContainer rows on Server 2025, the postgresql group's
  time).
- PostGIS on the SDK (GEOS, PROJ, json-c with zig).
- pg_cron's libpq mode on Windows (upstream report: WSAPoll and libpq's
  non-blocking connect).
- PostgreSQL 19 once it's out; Temurin 25.0.5 on Windows still pending.
