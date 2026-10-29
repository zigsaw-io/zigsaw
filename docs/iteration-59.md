# Iteration 59: zig 0.17's red rows, and the data folder follows the sandbox

Built 2026-10-30. zigsaw **0.59.0**. Five images to publish: ZLS 0.17.0
(rebuilt), and SQLite, ripgrep, bat and zstd on zig 0.17.0.

## Outcome

- **Iteration 58's run goes green again.** Its three red steps were all zig
  0.17's, now zig's `latest`: ZLS's image differed between this machine and
  CI's, and zig 0.17's Maker failed two suites' rows.
- **A soft run takes a low run's label off the app's data folder**, so the
  programs written there start at medium integrity. zig 0.17's Maker, which
  zig builds in its cache, was the first to show it; a command `cargo
  install` put in the data folder at low was the same.
- **SQLite, ripgrep, bat and zstd build on zig 0.17.0** (Clang 22), with no
  workaround changed. The SDKs, and the apps on them, keep zig 0.16.0.

## Starting decisions

From the planning session (plan file `plan-iteration-59-merry-bumblebee.md`):

- **CI's fixes, plus only the leaf C apps on zig 0.17** (your pick, over
  fixes only, or every recipe that pins zig 0.16, whose new digests would
  rebuild GTK's, Qt's, GDAL's and PostgreSQL's chains).
- **The data folder follows the sandbox** (your pick, over the iteration-56
  watcher also covering the data folder, which leaves a program a soft run
  writes and starts itself low, or a known gap only).
- v0.58.0 was never tagged, so the release is 0.59.0.

## What was built

### Slice 0: probes

Scratch `D:\zs\i59`, CI's logs in `D:\zs\i59\ci`.

- **ZLS** (from the CI artifact): the two `zls.exe` differ in two bytes of
  data, a `std.Target.Os.WindowsVersion` range of `0x0A000011` (Server
  2025, CI) against `0x0A000012` (Windows 11 26300, here), and the PE
  timestamp, a hash of the rest. With a native OS, zig 0.17 targets the
  build machine's Windows version; 0.16 knew neither build, and so wrote
  its newest for both. ZLS's build.zig takes `standardTargetOptions`; its
  host-target programs are build-time tools and tests.
- **matrix.sh's soft `zig init`** (`unable to write build.zig:
  AccessDenied`), reproduced in a fresh store: a low `zig version` labels
  zig's data folder low, inherited; the soft `zig init` then builds
  `cache\o\<hash>\maker.exe` there, which comes out `Low Mandatory
  Level:(I)`, so Windows starts it at low integrity, and it can't write the
  medium working directory. Without the low run first, it works.
- **certs.sh's untrusted zig row**: zig 0.17 says `error: server connection
  failed: TlsInitializationFailed`, then which command failed (Maker's
  command line); the row read only the last line. At low it's still
  `CertificateBundleLoadFailure`.
- **certs.sh's AppContainer zig row**: zig 0.17 builds Maker before `fetch`,
  `init` and `build`, which needs zig's own path; on Server 2025 an
  AppContainer can't find it (`self-path-dos`), as for `zig env`. Here,
  Maker runs in an AppContainer.

### Slice 1: CI's fixes

- [recipes/zls.json](../recipes/zls.json): `-Dtarget=x86_64-windows-gnu`, so
  the range is zig's (`0x0A000000` to `0x0A000013`), wherever it's built. A
  new image at the same version, 0.17.0; [recipes](recipes.md#zig) says why.
- [tests/certs.sh](../tests/certs.sh): zig's rows report its first `error:`
  line; the AppContainer row is a gap where `self-path-dos` fails.
- [gaps](gaps.md): zig 0.17's `init`, `fetch` and `build` in an AppContainer
  on Server 2025.

### Slice 2: the data folder follows the sandbox (0.59.0)

[src/run.zig](../src/run.zig)'s `unlabelData`: before a soft run joins the
app's runs, if the data folder has a low label of its own (a low run's), it
takes it off (`acl.unlabel`, which takes the inherited copies below too),
noting it when that takes a second or more. The app's next low run labels it
again, as it does a new folder. Not while another run of the app goes on (its
runs' lock, tried exclusively), nor when zigsaw itself runs low: the run then
warns that programs it writes there start at low integrity. AppContainer
runs, which never needed the label, leave it as it is.

[tests/sandbox.sh](../tests/sandbox.sh)'s programs section has four rows:
a program a low run wrote in the data folder starts at medium in a soft run;
one a soft run writes there and starts itself, after a low run, too; the
next low run labels the folder again; a soft run while a low run goes keeps
the label and says so. 0.58.0 fails three of them.

### Slice 3: leaf C apps on zig 0.17.0

[sqlite](../recipes/sqlite.json), [zstd](../recipes/zstd.json),
[bat](../recipes/bat.json) and [ripgrep](../recipes/ripgrep.json) pin zig
0.17.0's image as their SDK; nothing else changed. Their C compiles all
name `-target x86_64-windows-gnu` (zig's aliases, SQLite's commands), so the
build machine's Windows doesn't reach them.

## Results

| check | result | time |
|---|---|---|
| ZLS, SQLite, zstd, bat, ripgrep in store `p`, then `p2` | manifests `ce26807a`, `bfb3baa7`, `4629174e`, `927266c7`, `d387a995` in both | 212, 41, 105, 307, 84 s |
| `zig build test` (zig 0.17) | passed | |
| tests/sandbox.sh | 0 failed (4 new rows; 0.58.0 fails 3) | 31 s |
| tests/matrix.sh (store `p`: new ripgrep, bat, zstd; zig 0.17.0) | 0 differ, 3 known gaps; zig's soft `init, build and run` ok | 194 s |
| tests/zls.sh (new ZLS) | 0 failed, 0 known gaps | 47 s |
| tests/certs.sh, untrusted rows (the trusted ones run on CI) | zig's ok | |
| build.sh's base and zig groups (SQLite's recipe on 0.17.0) | 92 ok, 36 ok, 0 failed | 0.9 + 4 min |
| tests/self.sh with 0.59.0 | 0 failed: the same bytes as `zig build -Dstrip`, incremental and `--clean` too | 9.4 min |
| Defender scan of the 0.59.0 programs | no threats | |
| scripts/check-pins.sh on the five and zigsaw.json | only zigsaw's own image missing (never published) | |

## Known gaps

zig 0.17's `init`, `fetch` and `build` in an AppContainer on Server 2025
(above). A soft run while a low run of the same app goes on keeps the data
folder low, and says so.

## Next

- Publish **before pushing** (CI's suites pull ZLS, ripgrep, bat and zstd;
  the c and rust-go groups compare them), from store `D:\zs\i59\p` with
  `ZIGSAW=D:\zs\i59\bin\zigsaw.exe` (0.59.0):
  `scripts/publish.sh zls.json sqlite.json zstd.json bat.json ripgrep.json`.
- Then commit and push, and I read the run: whether ZLS and the four
  reproduce on Server 2025 is only seen there.
- Then tag **v0.59.0**, and I read the Release run.
- Later: the SDK chains onto zig 0.17.0.
