# Iteration 45: PostgreSQL, built with zig

Built 2026-10-24. No zigsaw change (still 0.44.0). One new image to
publish: PostgreSQL.

## Outcome

- **[`org.postgresql.PostgreSQL`](../recipes/postgresql.json) is PostgreSQL
  18.6, built from source with Meson and zig.**
  - OpenSSL 3.5, zlib, lz4, zstd and libxml2 are built into it.
  - ICU comes from Windows' own `icu.dll`.
  - PL/Perl and PL/Python run on Perl's and Python's images, which are its
    runtimes.
  - Its layer is 33 MB.
- **PostgreSQL's own regression suites pass on the build**: regress (231),
  isolation (122), plpgsql, plperl and plpython.
- **`postgresql` runs the server in the foreground**:
  - Its first run makes a cluster in the app's data: UTF-8, in the builtin
    `C.UTF-8` locale, with scram-sha-256 and a random password for
    `postgres`.
  - The app's own clients (`psql`, `pg_dump`, `pg_restore`, `pg_basebackup`,
    `pg_ctl`...) find that password in the app's password file.
  - `pg_ctl stop` from another run stops it, as does Ctrl+C or Ctrl+Break.
- **It works in every sandbox, AppContainer included**: shared memory, the
  signal pipes, child processes, both procedural languages, and connections
  between runs of the app. A client outside the container can't reach the
  server in it, as for any server in one (no loopback exemption).
- **It reproduces**: the same digest in three stores, once pgxs, which
  recorded the store's path of Perl, was left out.

## Starting decisions

Made with you at planning (plan:
`C:\Users\Test\.claude\plans\plan-to-build-postgresql-composed-fog.md`):

- **18.6, the stable release**, over 19 RC1 (out 2026-10-15) until 19 is
  released.
- **Core, the common libraries, and PL/Perl and PL/Python**, with Perl's and
  Python's images as runtimes.
- **Exports, with the cluster in the app's data**, made on first use by a
  launcher. There's no Windows service, as that takes an administrator.

Mine:

- **One image**, with its libraries as static modules of the recipe rather
  than from GTK's SDK.
- **ICU from Windows' `icu.dll`**, as libspelling has it. The default
  collation is the builtin provider's, which no Windows update changes.
- **scram-sha-256 and a random password** kept in the app's data, over
  `trust` on `127.0.0.1`, which would let any local user in as superuser.
- **LDAP (Windows' `wldap32`) and SSPI**, which cost nothing. NLS, readline,
  GSSAPI, Tcl, uuid-ossp and LLVM are left out.

## What was built

### The recipe

- **Modules**, in order:
  - `crt-noexport`, winflexbison, and GTK's SDK's `windres.c` and `nm.c`;
  - zlib, lz4 and zstd (CMake), libxml2 (Meson) and OpenSSL (GTK's SDK's
    recipe);
  - ICU 72.1's headers with
    [`icu-uc.pc`](../recipes/postgresql/icu-uc.pc) and
    [`icu-i18n.pc`](../recipes/postgresql/icu-i18n.pc);
  - NuGet's Python 3.14.7, for its headers and import library;
  - PostgreSQL;
  - [`pg-server.c`](../recipes/postgresql/pg-server.c).
- **[`zig-mingw.patch`](../recipes/postgresql/zig-mingw.patch)**:
  - a `.def` file for `postgres.exe`, written by
    [`mingw_gendef.pl`](../recipes/postgresql/mingw_gendef.pl) from `nm`'s
    output;
  - no `--allow-multiple-definition` or `--disable-auto-import`, with
    getopt's own variables kept on Windows;
  - MinGW's setjmp/longjmp under clang;
  - `rcgen`'s arguments, input before output.
- **[`signal-pipes.patch`](../recipes/postgresql/signal-pipes.patch)**:
  signal pipes under `\\.\pipe\LOCAL\`.
- **The `.pc` files are fixed for static linking**:
  - libxml2's gets `-DLIBXML_STATIC`;
  - OpenSSL's `Libs` get its system libraries;
  - zlib's `libzs.a` is renamed `libz.a`.
- **`cleanup`** removes headers, static libraries, pgxs, docs, man pages,
  libxml2's tools and a test program.

### The launcher

[`pg-server.c`](../recipes/postgresql/pg-server.c) is about 200 lines of C
against PostgreSQL's `libpgcommon`:

- `get_restricted_token()`, as initdb and pg_ctl call it, so the server
  also runs for an administrator (a runner's user);
- the cluster on first use: it makes `PGDATA` itself, runs initdb with
  `--pwfile` and the server's default `max_connections` and
  `shared_buffers`, and writes `pgpass.conf`;
- `postgres`, given the run's arguments, in the foreground. It ignores
  console events itself, and postgres stops fast on them.

### Tests, CI and docs

- **[`tests/postgresql.sh`](../tests/postgresql.sh)**, with a test
  certificate in [`tests/postgresql/`](../tests/postgresql/):
  - soft: 19 checks;
  - low and AppContainer: 4 each, the last row a known gap;
  - about 75 s.
- **CI**:
  - group `postgresql`, with a 75-minute timeout;
  - the suites job pulls `postgresql` and runs `tests/postgresql.sh`.
- **Docs**:
  - recipes.md: "PostgreSQL";
  - findings.md: "PostgreSQL (iteration 45)";
  - gaps.md: the server's lifetime, AppContainer, ICU's versions and no
    extension SDK;
  - published-apps.md and the README's suite list.

## Results

| check | result | time |
|---|---|---|
| PostgreSQL in stores p, p2 and published.sh's | `8d689585` in all three; layer `624144f2`, 33 MB | 10m45s–16m06s |
| the recipe before pgxs went, in p, p2 and p3 (p3 empty, downloading everything) | three layers, differing only in pgxs's `Makefile.global` | 10m14s–15m18s |
| `meson test` (setup, regress, isolation, plpgsql, plperl, plpython) | 8 of 8 suites; 231 + 122 + 13 + 14 + 23 tests | 4.5 min |
| `tests/postgresql.sh` (store p) | 28 ok, 1 known gap | 75 s |
| `tests/imports.zig` on the image's 132 executables and DLLs | all bound | |
| a killed backend: crash restart, then `pg_ctl stop` | recovered, stopped | |
| Ctrl+Break to a server run in its own console | fast shutdown, the run ended | |
| `GROUP=postgresql tests/published.sh` | 0 failed, 1 not published yet | 16m21s |
| `scripts/check-pins.sh` | only the new image missing | |

Not run here: the unit tests, `tests/self.sh`, the matrix and the other
suites. Nothing they cover changed.

## Decisions made along the way

All mine:

- **A `.def` file over a zig change.** zig's linker silently ignores
  `--export-all-symbols`. PostgreSQL's MSVC build already exports through a
  `.def` file, which zig's cc links when given one, so the MinGW build does
  the same.
- **MinGW's setjmp under clang only.** GCC builds keep PostgreSQL's choice.
- **The launcher works around initdb in an AppContainer**: it makes the
  directory and sets the two settings. PostgreSQL is left unpatched, so a
  plain `initdb` in an AppContainer still gets initdb's least settings
  (gaps.md).
- **No pgxs.** It recorded the store's path, and the image has no headers
  to build an extension with anyway.
- **The postgresql group runs on every push**, unlike TeX Live's: nothing in
  its build moves. It takes about 10 minutes here.

## Known gaps

See [gaps.md](gaps.md):

- The server lasts as long as its run.
- AppContainer: a client outside the container can't connect, and programs
  run through cmd.exe can't start the store's programs.
- ICU's collation versions follow Windows updates.
- There's no extension SDK.

## Next

- **Publish** `org.postgresql.PostgreSQL` (`scripts/publish.sh`), then make
  its ghcr.io package public.
- PostgreSQL 19 once it's released: a re-pin, plus whatever 19 changes.
- An SDK for extensions: the server headers, `libpostgres.a` and pgxs with
  a relative Perl, for pgvector and PostGIS.
