# Iteration 75: zlib 1.4, a build that failed at random, and a crash on a reset download

Started 2026-11-05. Iteration 74's last steps were stuck: Reproduce was red only in `published (gtk)`,
so `sign-release.sh` wouldn't sign v0.74.0. That failure was BusyBox `make` picking up a random target
name in GTK SDK's enchant module, which 74 had called a one-off. zlib 1.4 came out the same day, fixing
the report's only network-exposed advisories in the GTK and PostgreSQL chains. 22 images move, and
zigsaw is **0.75.0**, for a crash the round's own download hit. Findings are in
[findings.md](findings.md#an-empty-macro-in-busyboxs-make), limits in [gaps.md](gaps.md).

## Outcome

- **v0.74.0 is signed and works.** Its gtk job passed on a rerun and you signed it. The signature
  checks with the publish key and is rejected by the backup key, and a local package has the same six
  programs. Real upgrades from v0.73.0 and from a build labelled 0.73.99 pass, and a tampered
  `SHA256SUMS` is refused.
- **`make`'s random failure has a cause.** `update_makeflags()` in BusyBox's make, as in pdpmake, sizes
  its buffer one byte short for an empty command line macro, so heap junk goes into `MAKEFLAGS`, and a
  recursive make takes it as the value. `gtk4-sdk.json` now empties `nodist_doc_DATA` in the Makefile
  instead. A BusyBox bump wouldn't help: upstream has the same code.
- **zlib 1.4** in `gtk4-sdk-base`, `gtk4-msvc`, `postgresql-sdk` and `sqlite`, with fribidi 1.0.18,
  libffi 3.8.0, DirectX-Headers 1.721.2 and expat 2.10.0. The 22 images reproduce in two stores.
- **A connection reset during a download is an error, not a crash.** `Registry.getTo` replaces
  `std.http.Client.fetch` for recipes' sources and `zigsaw upgrade`. A recipe's sources now reach the
  fallback to the files kept next to its image, which the panic used to skip.
- **Where older zlib remains is written down**: [findings.md](findings.md#zlib-inside-images). The
  report can't see bundled copies, so "zlib is fixed" holds only for images whose recipes build it.

## Decisions

Yours:

- zlib now, not after Monday's report.
- The three bumps that rebuild nothing extra, plus expat, which adds `gdal-sdk` and `gdal`.
- **Missing image signatures keep warning.** Iteration 74's "refuse in v0.75.0" is withdrawn, with no
  date set. `pull`'s warning still says "in a later release, this will be refused", which stays true
  as a direction. Say if you'd rather drop it.
- **The crash fixed now, as 0.75.0.** The plan said no code, no release, 0.74.0.

Mine, say if you disagree:

- **Emptying the macro in the Makefile**, checked by a `grep`, rather than retrying the step. It takes
  away the trigger, whereas a retry would hide it.
- **`getTo` does what `fetch` did**, with `bodyFailure`, rather than catching the panic's cause some
  other way. Same redirects and decompression.
- **Images stay built by the frozen v0.74.0 program**, so its build cache keeps counting and the
  round didn't have to run again for a version bump.
- **`php-sdk` stays on php.net's prebuilt zlib 1.3.2-1**: it can't move until they publish one.

## Results

Built with the frozen program, except where it says the fixed build.

| What | Result |
|---|---|
| The 22 images in `p` and `p2` (separate downloads and vendors) | same digests |
| `gtk4-msvc`, where 1.4 renames `z` to `libz` | builds, no recipe change, 9m 27s |
| `tests/gtk.sh`, including the MSVC demos | 100 ok |
| `tests/gtk3.sh` | 45 ok |
| `tests/gdal.sh` | 32 ok |
| `tests/postgresql.sh`, with a new gzip dump and restore | 50 ok |
| `tests/registry.sh`, fixed build | 113 ok |
| `tests/registry.sh`, 0.74.0 | 111 ok; only the two new reset rows fail, by panicking |
| `tests/shims.sh`, `store.sh`, `install.sh`, `updates.sh`, `signing.sh`, fixed build | 55, 16, 45, 42, 34 ok |
| Unit tests, fixed build | pass |
| `scripts/package.sh`, then `defender-scan.sh` | 0.75.0's six programs clean |
| `tests/self.sh` against that package | 19 ok: zigsaw builds itself to the same bytes |
| `scripts/check-upstream.sh` | no row for zlib, expat, fribidi, libffi or DirectX-Headers |
| `scripts/check-upstream.sh --coverage` | 154 rows, 85 recipes, 0 problems |

The first `shims.sh` run failed 7 rows and the first `registry.sh` run failed one, both from mistakes
of mine listed below. These are the reruns.

0.75.0's programs here, to compare with the release's:

| Program | SHA-256 |
|---|---|
| `zigsaw.exe` | `4d6b3d341bd0dab44f809912037ca3cac94f71e6cbfd779049ebb3f9dbdf7e79` |
| `zigsaw-shim.exe` | `3fca6fa18a71a447ccf7822159324569b608de90f157f69adffba6131f47293d` |
| `zigsaw-shimw.exe` | `ca8b6deb2e6c9a28573bed63c0f9735fff301077cec4ebcdc062c240e753df38` |
| `zigsaw-relay.exe` | `38ca695b095c1544d92211df02a220951649763aae9319fcad3951a74c66be65` |
| `zigsaw-host.exe` | `5d13cad421ece01c71175c1bd5e140414749a4013fbcef9772485b818769ecd3` |
| `zigsaw-notify.exe` | `df0876ce1bf0d8d852e18fbbe965a793e6e0e0212eee6404158d61a186e8b3bd` |

## What went wrong

- **I "fixed" pgvector's `OPTFLAGS=` the same way, and it was never affected**: it builds with GNU
  make. My check also tripped on the Makefile's comments, which stopped round `p`. Reverted. pg_cron and
  PostGIS use GNU make too, so enchant was the only recipe that needed the change.
- **The crash took down round `p2`**, 1018 s in. That was the bug, and it's why 0.75.0 exists.
- **My new `upgrade` row first ran from `zig-out`**, where `upgrade` refuses before any download, so it
  tested nothing and failed. It now copies zigsaw into its store's `bin`.
- **My kit's seed was empty**, so `shims.sh` couldn't build its renamed BusyBox: frippery.org has
  answered 403 to everyone since 2026-10-03, and a renamed id gets no files from next to the image. CI
  isn't affected, as its store is seeded first. I briefly told you this might reach CI before checking
  my own notes.
- **Smaller slips in the kit**: `zigsaw build` has no `--yes`; an unquoted `sed` ate a path's
  backslashes; `registry.sh` takes the registry as its first argument; a build run against a failed
  compile tested the old binary, so tests now wait for the build's result.

## Not checked

- **Whether the `make` fix holds on CI.** The toy reproduces the failure 49 times in 50 with the macro on
  the command line and 0 in 50 with it emptied in the Makefile. `nodist_doc_DATA=` itself never failed
  here, as that depends on the name's length and the heap. Two of the last three CI runs failed, so
  one green proves little: I'll rerun that job twice more. Three greens is good evidence, not proof.
- **Whether the older zlib copies reach the vulnerable code.** The table has version strings only, and
  no string proves nothing: Python shows none.
- **`z_off_t` past 2 GB in a real dump.** zlib 1.4 makes it 32 bits by default on Windows. PostgreSQL
  uses only `gzopen`, `gzread` and `gzwrite`, and osm2pgsql asks for 64 bits, so nothing should reach
  it, by reading their sources. The gzip dump row is small.
- **`tests/build.sh` and `tests/published.sh`'s new `mkdir`**, one line each: CI will run them.
- **0.75.0's real upgrade**, which waits for the signed release.
- **pinta** isn't published, so it stays on its old pins.

## Next

In this order; each is yours unless it says otherwise.

1. **Publish the 22 images, before pushing**, from Git Bash at the repository's root, with the frozen
   program, whose hash the store's build cache keys on. It asks for the passphrase:

   ```bash
   COSIGN='E:\zs\i74\oci\deploy\c8a2493280a2737a6feba18c684b1744950dfc928244e17555862f77651d7ca3\cosign.exe' COSIGN_KEY='<the signing key>\cosign.key' ZIGSAW_HOME='E:/zs/i75/p' ZIGSAW='E:\zs\i75\bin\zigsaw.exe' scripts/publish.sh sqlite.json gtk4-sdk-base.json gtk4-sdk.json gtk4.json gnome-text-editor.json rnote.json gtk3-sdk.json gtk3.json gtk3demo.json gnumeric.json pygobject-sdk.json pygobject.json meld.json gaphor.json gdal-sdk.json gdal.json postgresql-sdk.json postgresql.json postgresql-pgvector.json postgresql-pg-cron.json postgresql-postgis.json osm2pgsql.json
   ```

2. **Commit and push.** `docs/iteration-75.md` is the only new file.
3. **I read Reproduce**: every `published` group, and `check-pins` at 0 unsigned, then rerun
   `published (gtk)` twice more.
4. **Tag v0.75.0.** I read Release and its scan, and compare its programs with the table above.
5. **`COSIGN_KEY=... bash scripts/sign-release.sh v0.75.0`.** Nobody hears about the release until
   this has run. I then try a real upgrade in a scratch store.
6. **Run Upstream once.** I read the issue, and Monday's weekly run.
7. **File `draft/i75/pdpmake-empty-macro.md`** upstream, if you agree with it.

Left for later iterations: whether to act on the older zlib copies, and when, or whether, a missing
signature is refused.
