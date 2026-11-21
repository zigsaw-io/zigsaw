# Iteration 106: GNU make for the rest

Started 2026-11-21, from "plan to use GNU make for the remaining recipes". Iteration 104
moved GTK's family to GNU make and left three published recipes on BusyBox's:
PostgreSQL's SDK, Ghostscript and GDAL's SDK. **Now every published recipe that runs
`make` builds with GNU make, and `scripts/check-make.sh` has no allow list.** PostgreSQL's
SDK brings GNU make to the extensions built with it, as GTK's SDK does. Ten images get new
digests; their own files don't change. zigsaw stays **0.105.0**: nothing in it changed.

Before that, a fix: v0.105.0's Release run (44768209994) failed in `tests/self.sh`, so
v0.105.0 was never published.

State at the start: 105 had landed (`2dfa9d0`, Reproduce 44756764810 green); its Release
run red, as above.

## Outcome

- **`tests/self.sh` follows the help it changes.** Its incremental-build check changes one
  line of zigsaw's help in a copy of the checkout and expects one file rewritten. Iteration
  105 reworded that line ("find apps in the default registry's catalog" became "find apps
  in the remotes' catalogs"), so the `sed` matched nothing, nothing was rewritten, and two
  checks failed. It changes the new line now, and first checks the line is there, so the
  next rewording fails with a message naming it rather than as a build with nothing to do.
- **PostgreSQL's SDK has GNU make among its runtimes.** Its own build gets it (OpenSSL is
  `make -j"$(nproc)" build_sw`, as in GTK's SDK, without the `make -n | xargs -P`
  workaround), and so does every recipe that lists the SDK: pgvector, pg_cron and PostGIS
  no longer pin make themselves. They pinned an older build of it (`045e39d4`), and a
  build can't have two versions of one app.
- **Ghostscript pins GNU make**, and builds with `make -j"$(nproc)"`: about 7 minutes,
  16 before. Its configure script recognises GNU make, so its makefile's order-only
  prerequisites stay (the recipe checks `MAKEDIRS=| directories`), and the BusyBox
  workarounds go: emptying `MAKEDIRS`, a separate `make directories`, and
  `ac_cv_prog_MAKE_EXISTS=yes` (make is a program on PATH now, not an applet).
- **GDAL's SDK pins GNU make** for libiconv, which already ran `make -j`.
- **`scripts/check-make.sh`** has no allow list: 9 published recipes run `make`, all with
  GNU make. `scripts/ci-groups.sh` checks the TeX Live and GDAL groups when make's recipe
  changes, as it does GTK's.

## Decisions

| Decision | Choice |
|---|---|
| How the extensions get GNU make | From PostgreSQL's SDK, among its runtimes (your pick), as GTK's SDK gives it. A PGXS extension needs GNU make, so whoever builds one with the SDK gets it. The extensions' own pins go |
| Ghostscript and GDAL's SDK | Their own pin in `"sdk"`, as gettext's: nothing built on them runs make |
| v0.105.0 | Re-tagged on the fix (your pick). Its Release run published nothing, so no one has v0.105.0 |
| zigsaw's version | Stays 0.105.0: only recipes, scripts, a test and docs change |

## Files

- `tests/self.sh`: the help line it changes, and the check that it's there.
- `recipes/postgresql-sdk.json`, `recipes/ghostscript.json`, `recipes/gdal-sdk.json`;
  `recipes/postgresql-pgvector.json`, `postgresql-pg-cron.json`, `postgresql-postgis.json`
  (make's pin dropped); re-pinned: `texlive.json`, `gdal.json`, `postgresql.json`,
  `osm2pgsql.json` and the extensions.
- `scripts/check-make.sh` (no allow list), `scripts/ci-groups.sh` (make's recipe in the
  TeX Live and GDAL paths), `scripts/published-groups.txt` (Ghostscript's time).
- `docs/recipes.md`, `docs/gaps.md`, `docs/findings.md`, `docs/published-apps.md`.

## Results

| what | result |
|---|---|
| `tests/self.sh` | 0 failed, here, with the fix; the incremental row that failed on CI passes |
| the round | 10 images in store `p` (37 min), then from the pinned recipes in `E:\zs\i106\p2` (32 min): the same 10 digests |
| layers | every image's own layers are the ones on ghcr.io; PostgreSQL's SDK adds GNU make's (`c399a41e`, 222 KB), as a runtime |
| `scripts/check-make.sh` | 9 recipes run make, 0 without GNU make, no allow list |
| `scripts/check-pins.sh` | 9 missing, all the round's new digests; 0 older runtimes |
| suites, store `p` | `tests/postgresql.sh` 61 ok, `tests/osm2pgsql.sh` 43 ok, `tests/gdal.sh` 32 ok, `tests/texlive.sh` 20 ok; 0 failed |
| unit tests, `tests/build.sh` | not run again: zigsaw's source didn't change |

## Images

Built in store `D:\zs\i106\p` with the frozen 0.105.0 (`E:\zs\i106\bin`), each also in
`E:\zs\i106\p2` from the pinned recipes:

| Image | Digest | Time here | Before |
|---|---|---|---|
| `com.artifex.Ghostscript` | `4849c111ecac` | 6.7 min | 16 min |
| `org.tug.texlive` | `1222d1fdb23c` | 7.2 min (archives cached) | |
| `org.gdal.GDAL.Sdk` | `e61ad31f422a` | 12 min | 12 min |
| `org.gdal.GDAL` | `7a1b33647212` | 3 s | |
| `org.postgresql.PostgreSQL.Sdk` | `0d0fc90288af` | 7.5 min | 7 min |
| `org.postgresql.PostgreSQL` | `27586b94e64e` | 5 s | |
| `org.postgresql.PostgreSQL.pgvector` | `6c96b6f1648a` | 9 s | |
| `org.postgresql.PostgreSQL.pg_cron` | `11067725e3fa` | 4 s | |
| `org.postgresql.PostgreSQL.PostGIS` | `837bfc541799` | 2.2 min | |
| `org.osm2pgsql.osm2pgsql` | `65ed41ca5524` | 1.7 min | |

TeX Live's 432 archives came from iteration 104's store: tlnet replaces an archive when
its package changes, so a build from a cold cache could fail on a hash that moved, and
the CI group downloads them afresh.

## Not checked

- **CI's side**: the `texlive`, `gdal` and `postgresql` groups build these on a runner
  after the push.

## Not this time

- Qt's SDK still exports BusyBox's make as `make`; no published recipe runs it.
- zig 0.17.1 and CMake 4.5.0, from the upstream report.

## Yours to do

1. **The Release fix first, alone:** commit `tests/self.sh` by itself, push it, and move
   the tag onto it, so the Release workflow runs again:

   ```
   git add tests/self.sh && git commit -m "tests/self.sh: change the help line 105 reworded"
   git push
   git tag -f v0.105.0 && git push -f origin v0.105.0
   ```

   I read that Release run.
2. **Publish the 10 images before pushing the rest**, in this order, with the frozen exe:

   ```
   ZIGSAW_HOME='D:\zs\i106\p' ZIGSAW='E:\zs\i106\bin\zigsaw.exe' scripts/publish.sh ghostscript.json texlive.json gdal-sdk.json gdal.json postgresql-sdk.json postgresql.json postgresql-pgvector.json postgresql-pg-cron.json postgresql-postgis.json osm2pgsql.json
   ```

   Only configs and manifests are new to ghcr.io (and GNU make's layer in PostgreSQL's
   SDK's repository).
3. Commit and push the rest (this file is new). I read the Reproduce run: `pins`
   (check-make) first, then the `texlive`, `gdal` and `postgresql` groups. The change to
   `scripts/ci-groups.sh` makes every group run, GTK's and Qt's included, so it's a long
   one.
